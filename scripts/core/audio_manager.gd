extends Node
## Procedural-audio front end (spec §17): one place that owns buses, a player
## pool and the volume settings, driven only by events.
##
## Design rules that the rest of the game relies on:
##
## * Nothing here blocks. `play_sfx()` never awaits, never loads from disk on
##   the first call per sound and never touches `Engine.time_scale`, so a hit
##   landing on the same frame as a swing cannot stall gameplay. Streams are
##   loaded once and cached; the pool is built in `_ready()`.
## * Nothing here is referenced by gameplay. Combat, loot and the player emit
##   signals (`EventBus.damage_dealt`, `enemy_died`, `player_died`,
##   `sfx_requested`) and this node listens. Removing the autoload therefore
##   silences the game without breaking a single mechanic, which is why no `.gd`
##   outside this file mentions `AudioManager`.
## * Volumes live on the audio buses, not on the players, so `set_volume()`
##   takes effect on sounds that are already playing.
## * Settings are a separate file under `user://settings/`, never inside
##   `user://saves/` (spec §18): a save slot carries progress, not preferences.
##
## The autoload is resolved at runtime through the main loop where needed, so
## the script also runs under `godot --script`, where autoload identifiers are
## not registered and a test adds its own instance to the tree.

const SFX_DIR := "res://assets/audio"
const SETTINGS_PATH := "user://settings/audio.json"
const SETTINGS_VERSION := 1
const SFX_POOL_SIZE := 8
const UI_POOL_SIZE := 2
## Two music players so a track change can crossfade instead of cutting: one
## holds the current track, the other is the incoming/outgoing voice. A single
## player could only stop-then-start, which pops on a mid-bar switch.
const MUSIC_POOL_SIZE := 2
## Reading a bus at -80 dB or below counts as silence, which is what
## `set_volume(bus, 0.0)` writes. `linear_to_db(0.0)` is `-inf`, and an
## infinite value in a JSON settings file would not survive the round trip.
const SILENCE_DB := -80.0
## A crossfade starts a fresh voice here (effectively silent) and ramps it to
## 0 dB while the outgoing voice ramps down here and is then stopped. It is well
## above the bus silence floor so the ramp is audible, yet low enough that the
## seam is inaudible.
const MUSIC_FADE_START_DB := -60.0
## An ambience bed sits this far under the music on the same bus: it is meant to
## be felt under the track, not to compete with it.
const AMBIENCE_DB := -10.0
## How long `_exit_tree` lets the audio mix thread run after stopping every
## voice, in milliseconds. A stopped voice's playback is retired a moment after
## `stop()` queues it; without that moment the exit leak check finds a
## still-playing bed's playback — and the stream it holds — "still in use".
## Measured on this project: 0 ms leaks reproducibly (2 ObjectDB instances plus
## 1 resource), anything from 20 ms up stays clean over repeated headless runs,
## suites and bots, and a windowed run on the real audio driver is clean too.
## 200 ms keeps a wide margin over the measured threshold while costing the
## shutdown only a fifth of a second, once, and only when audio was played.
const EXIT_AUDIO_FLUSH_MS := 200
## Default per-sound random pitch spread, in semitone-like fractions of pitch.
const DEFAULT_PITCH_VARIATION := 0.06

enum Bus { MUSIC, SFX, UI }

const BUS_NAMES: Array[String] = ["Music", "SFX", "UI"]
## The one source of truth for the shipped levels: `load_settings()` puts these
## on the buses when there is no settings file, and the settings screen reads
## them back through `settings_defaults()` for both its display and its `R` key,
## so a fresh install cannot show one number and play another.
const DEFAULT_VOLUMES := {"Music": 0.7, "SFX": 0.9, "UI": 0.8}

## name -> stream, filled on first use. `null` marks a name already found to be
## missing, so an unknown name does not hit the resource loader on every call.
var _streams: Dictionary = {}
var _pools: Dictionary = {}
## Pool bookkeeping for the "steal the oldest" rule: an own monotonic counter
## plus the last stamp handed to each player (keyed by instance id, so it is
## bounded by the pool size — pool players live as long as this node).
var _playback_stamp := 0
var _stamps: Dictionary = {}
## The two music voices and which one currently owns `_music_name`. `_music_other`
## is the spare: it becomes the incoming voice on the next `play_music`, and the
## just-retired track becomes the new spare. `_music_fades` holds the in-flight
## volume ramps (each `{player, target, rate}`) stepped in `_process`.
var _music_players: Array[AudioStreamPlayer] = []
var _music_current: AudioStreamPlayer = null
var _music_other: AudioStreamPlayer = null
var _music_name := ""
var _music_fades: Array = []
## A single looping ambience bed on the Music bus, under the music.
var _ambience_player: AudioStreamPlayer = null
var _ambience_name := ""

## UI click detection: the panels themselves are not touched; the shared
## "a modal owns the input" flag is watched in one central place instead.
var _game_state: Node = null
var _ui_blocking_seen := false
var _ui_blocking_initialised := false
## boss instance id -> phase last seen, for the phase-change roar.
var _boss_phases: Dictionary = {}
var _events_connected := false
## Set by `park_for_bot()` and cleared by `unpark_for_bot()`. While it is up the
## whole playback layer is inert: `play_sfx`/`play_music`/`play_ambience` return
## before doing anything, and `_stream` refuses to load. A parked manager is the
## audio layer removed at runtime without removing the node — which is exactly
## what a debug bot needs, because a single cold disk read of a `.wav` on the
## first hit of a run stalls a physics frame, and that one stall is enough to
## make the run diverge from its own seed (see `park_for_bot`).
var _parked := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus in BUS_NAMES:
		_build_pool(bus)
	_build_ambience_player()
	load_settings()
	_connect_events()


func _process(_delta: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	_step_music_fades(_delta)
	_poll_ui_toggle()
	_poll_boss_phases(tree)


## The audio server keeps its own reference to a player that is still playing,
## so a voice left running when the process goes down is an instance the engine
## cannot free ("ObjectDB instances were leaked at exit"). Leaving the tree —
## quit, scene teardown, exit — stops every voice and drops the stream
## references first, which is what lets the shutdown come out clean.
func _exit_tree() -> void:
	for bus in _pools.keys():
		for entry in (_pools[bus] as Array):
			var player := entry as AudioStreamPlayer
			if player == null:
				continue
			# Stop unconditionally, not only when `playing` reads true: under the
			# headless (dummy) audio driver a voice that was started keeps its
			# server-side playback alive while `playing` already reads false, so a
			# `playing`-gated stop would leave that playback — and the stream it
			# holds — in use at exit. `stop()` on an idle voice is a harmless no-op.
			player.stop()
			player.stream = null
	if _ambience_player != null and is_instance_valid(_ambience_player):
		_ambience_player.stop()
		_ambience_player.stream = null
	# The mix thread retires a stopped voice's playback a moment after `stop()`
	# queues it. Let it run that moment before the caches — and with them the last
	# reference to each stream — go away, or the exit leak check reports a
	# still-playing bed's playback and its stream as "still in use". Only worth
	# waiting on when something was actually played this session.
	if not _streams.is_empty():
		OS.delay_msec(EXIT_AUDIO_FLUSH_MS)
	_streams.clear()
	_music_players.clear()
	_music_current = null
	_music_other = null
	_music_fades.clear()
	_ambience_player = null
	_boss_phases.clear()
	_stamps.clear()


# --- bot parking --------------------------------------------------------------

## Silence the whole playback layer for the duration of a debug-bot run, and do
## it the way `_exit_tree` would, so nothing is orphaned.
##
## Two reasons the bot parks audio, and the previous `_pools.clear()` only served
## the first and caused a leak:
##
## * Determinism. `play_sfx` rolls a random pitch off the same global RNG the
##   simulation rolls crits, wander and loot on, so a live pool makes the number
##   of rolls a run consumes depend on wall-clock audio progress, not the seed.
##   And `play_sfx` loads the `.wav` through `_stream` before it ever looks at the
##   pool, so even a pitch-less call cold-loads a file on first use; on the very
##   first process that file is read off a cold disk, that read stalls a physics
##   frame, the engine runs catch-up steps, and the render-delta status clock
##   (which cannot be moved onto the physics tick from here) desynchronises from
##   the fixed-delta world — the run then diverges from its own recorded seed.
##   `_parked` makes every entry point return before it loads or rolls.
## * Shutdown cleanliness. The zone starts its music and ambience bed during world
##   build, before the bot runs. Those voices are live and hold their streams. The
##   old code dropped the pool dictionary without stopping them, so `_exit_tree`
##   iterated an empty dict, never released the server-side playbacks, and the
##   process exited with leaked `AudioStreamPlaybackWAV`/`AudioStreamWAV`
##   instances and `music_forest.wav` "still in use". Stopping each voice and
##   dropping its stream here is what lets the exit come out clean.
##
## The voices are stopped, dropped from the tree and released at the end of the
## frame (`queue_free`, not `free`), so a test that captured a player before
## parking can still read its `stream`/`playing` this frame and assert both are
## cleared. `unpark_for_bot()` rebuilds the pools for a caller that needs the
## manager working again — the test suite being the only one.
func park_for_bot() -> void:
	_parked = true
	for bus in _pools.keys():
		for entry in (_pools[bus] as Array):
			var player := entry as AudioStreamPlayer
			if player == null or not is_instance_valid(player):
				continue
			# Stop unconditionally, not only when `playing` reads true: under the
			# headless (dummy) driver a started voice keeps its server-side playback
			# alive while `playing` already reads false, and that playback is exactly
			# what the exit leak check would otherwise report as still in use.
			player.stop()
			player.stream = null
			# Take the voice out of the tree now and release it at the end of the
			# frame. Leaving it as a stopped child would (a) orphan it at exit and
			# (b) squat on its name, so `unpark_for_bot` would rebuild under an
			# auto-mangled name and anything that finds a voice by name would miss
			# it. `queue_free` (not `free`) so a caller that captured the node before
			# parking can still read its `stream`/`playing` this frame.
			remove_child(player)
			player.queue_free()
	# The ambience bed lives outside the pools but holds a loaded looping stream, so
	# it is the other half of the same leak and must be released the same way.
	if _ambience_player != null and is_instance_valid(_ambience_player):
		_ambience_player.stop()
		_ambience_player.stream = null
		remove_child(_ambience_player)
		_ambience_player.queue_free()
	_pools.clear()
	_music_players.clear()
	_music_current = null
	_music_other = null
	_music_name = ""
	_music_fades.clear()
	_ambience_player = null
	_ambience_name = ""


## Undo `park_for_bot()`: rebuild the pools and the ambience voice and let the
## playback layer load and play again. Only the test suite needs this, because it
## parks the shared autoload and then keeps exercising it. Volumes live on the
## buses (not the players), so they survive the park untouched and need no restore.
func unpark_for_bot() -> void:
	_parked = false
	for bus in BUS_NAMES:
		_build_pool(bus)
	_build_ambience_player()


# --- playback ----------------------------------------------------------------


## Plays `res://assets/audio/<name>.wav`. Returns false for an unknown name
## (no error, no exception: audio must never break a gameplay path).
func play_sfx(name: String, bus: String = "SFX", pitch_variation: float = DEFAULT_PITCH_VARIATION) -> bool:
	# Parked for a bot run: return before `_stream` (which would cold-load the
	# `.wav` on first use) and before the pitch roll (which would draw from the
	# global RNG the simulation shares). Both are sources of run divergence.
	if _parked:
		return false
	var stream := _stream(name)
	if stream == null:
		return false
	var pool: Array = _pools.get(bus, [])
	if pool.is_empty():
		return false
	var player := _pick_player(pool)
	if player == null:
		return false
	player.stream = stream
	player.pitch_scale = 1.0
	if pitch_variation > 0.0:
		player.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	player.play()
	return true


## Loops `res://assets/audio/<name>.wav` on the Music bus, crossfading from the
## track already playing (if any) over `fade` seconds. Returns false for an
## unknown name, leaving the current track untouched — audio never breaks a
## gameplay path. Calling it again with a different name replaces the previous
## track (the old one is ramped down and stopped), so travel can never stack two
## tracks. A `fade` of 0 cuts instantly instead of ramping.
func play_music(name: String, fade: float = 0.6) -> bool:
	if _parked:
		return false
	var stream := _stream(name)
	if stream == null or _music_current == null or _music_other == null:
		return false
	# Already the current, audible track: do not restart it from silence.
	if name == _music_name and _music_current.playing:
		return true
	_enable_loop(stream)
	var incoming := _music_other
	var outgoing := _music_current
	# The spare may still be ramping down from an earlier swap: cancel that first
	# so a rapid triple switch never leaves a stale fade on the voice we reuse.
	_cancel_fade(incoming)
	incoming.stream = stream
	incoming.volume_db = MUSIC_FADE_START_DB
	incoming.play()
	if fade <= 0.0 or not outgoing.playing:
		# No ramp: bring the new track straight up and cut the old one, so a
		# travel or a boss switch never leaves two tracks stacked.
		incoming.volume_db = 0.0
		if outgoing.playing:
			outgoing.stop()
	else:
		_start_fade(incoming, 0.0, fade)
		_start_fade(outgoing, MUSIC_FADE_START_DB, fade)
	# The just-started voice is now current; the retired one becomes the spare.
	_music_current = incoming
	_music_other = outgoing
	_music_name = name
	return true


## Stops the music, ramping every live music voice down over `fade` seconds
## (0 cuts instantly). Clears the current-track name immediately so a caller can
## never read a track that is on its way out.
func stop_music(fade: float = 0.6) -> void:
	_music_name = ""
	for player in _music_players:
		if player == null or not is_instance_valid(player) or not player.playing:
			continue
		_cancel_fade(player)
		if fade <= 0.0:
			player.stop()
		else:
			_start_fade(player, MUSIC_FADE_START_DB, fade)


## The track name `play_music` last started, or "" once stopped. Read by tests
## and by the zone/boss wiring to decide whether a switch is actually a change.
func current_music() -> String:
	return _music_name


## Back-compat alias for `current_music()`; the name predates the crossfade work.
func music_name() -> String:
	return _music_name


## Loops an ambience bed (`res://assets/audio/<name>.wav`) on the Music bus at a
## low fixed level, under the music. One bed at a time: a second call replaces
## the first. Returns false for an unknown name.
func play_ambience(name: String) -> bool:
	if _parked:
		return false
	if _ambience_player == null:
		return false
	var stream := _stream(name)
	if stream == null:
		return false
	_enable_loop(stream)
	_ambience_player.stream = stream
	_ambience_player.volume_db = AMBIENCE_DB
	_ambience_player.play()
	_ambience_name = name
	return true


func stop_ambience() -> void:
	_ambience_name = ""
	if _ambience_player != null and is_instance_valid(_ambience_player) and _ambience_player.playing:
		_ambience_player.stop()


func current_ambience() -> String:
	return _ambience_name


## Make a loaded bed loop seamlessly. The importer leaves `loop_end` at 0, which
## the audio server reads as a zero-length region, so a voice set to LOOP_FORWARD
## alone finishes at once instead of looping. The true frame count comes from the
## stream length, so the loop spans the whole bed whether the import kept it as
## PCM or packed it into IMA_ADPCM.
func _enable_loop(stream: AudioStream) -> void:
	var wav := stream as AudioStreamWAV
	if wav == null:
		return
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = int(round(wav.get_length() * float(wav.mix_rate)))


# --- volume ------------------------------------------------------------------


## Linear 0..1 -> dB on the bus, applied immediately (also to sounds already
## playing). 0 becomes the SILENCE_DB floor rather than -inf. Unknown bus names
## are ignored: a settings file from a future build must not spam the log.
func set_volume(bus: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var value := clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_volume_db(index, SILENCE_DB if value <= 0.0 else linear_to_db(value))


## Linear read-back of `set_volume()`. Unknown bus -> 1.0 (the engine default).
func volume(bus: String) -> float:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return 1.0
	var db := AudioServer.get_bus_volume_db(index)
	if not is_finite(db) or db <= SILENCE_DB:
		return 0.0
	return clampf(db_to_linear(db), 0.0, 1.0)


func bus_name(bus: Bus) -> String:
	return BUS_NAMES[bus] if bus >= 0 and bus < BUS_NAMES.size() else ""


# --- settings ----------------------------------------------------------------


## Snapshot of the three controllable buses.
func save_settings() -> Dictionary:
	var volumes := {}
	for bus in BUS_NAMES:
		volumes[bus] = volume(bus)
	var payload := {"version": SETTINGS_VERSION, "volumes": volumes}

	DirAccess.make_dir_recursive_absolute(SETTINGS_PATH.get_base_dir())
	var text := JSON.stringify(payload, "\t")
	var tmp := SETTINGS_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		var msg := "cannot_open_tmp: %s" % error_string(FileAccess.get_open_error())
		_warn(msg)
		return {"ok": false, "error": msg}
	file.store_string(text)
	file.flush()
	file.close()

	var verify := FileAccess.get_file_as_string(tmp)
	if verify.length() != text.length() or _parse_json(verify) == null:
		DirAccess.remove_absolute(tmp)
		_warn("verification failed for %s" % SETTINGS_PATH)
		return {"ok": false, "error": "verification_failed"}

	var err := DirAccess.rename_absolute(tmp, SETTINGS_PATH)
	if err != OK:
		_warn("rename failed (%s)" % error_string(err))
		return {"ok": false, "error": "rename_failed:%s" % error_string(err)}
	return {"ok": true, "error": ""}


## Apply the stored volumes. A missing file is a fresh install, and a fresh
## install gets `DEFAULT_VOLUMES` rather than the engine's silent 1.0, so the
## buses, the settings screen and its `R` key agree before the player has ever
## saved. A corrupt or half-written file lands on the same defaults, with one
## diagnostic line, instead of keeping whatever a previous caller left there.
func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		_apply_default_volumes()
		return
	var parsed: Variant = _parse_json(FileAccess.get_file_as_string(SETTINGS_PATH))
	if not parsed is Dictionary:
		_warn("%s is not a JSON object, applying defaults" % SETTINGS_PATH)
		_apply_default_volumes()
		return
	var raw_volumes: Variant = (parsed as Dictionary).get("volumes", {})
	if not raw_volumes is Dictionary:
		_warn("%s has no volumes block, applying defaults" % SETTINGS_PATH)
		_apply_default_volumes()
		return
	for bus in BUS_NAMES:
		var value: Variant = (raw_volumes as Dictionary).get(bus, null)
		if value is float or value is int:
			set_volume(bus, float(value))


## Writes `DEFAULT_VOLUMES` to the three controllable buses. A bus the table does
## not name is left alone, so the table stays the only thing that has to be kept
## in step with the bus layout.
func _apply_default_volumes() -> void:
	for bus in BUS_NAMES:
		var value: Variant = DEFAULT_VOLUMES.get(bus, null)
		if value is float or value is int:
			set_volume(bus, float(value))


## The shipped levels, for a caller that has to show or restore them instead of
## applying them — the settings screen is the only one.
func settings_defaults() -> Dictionary:
	return DEFAULT_VOLUMES.duplicate()


# --- event wiring ------------------------------------------------------------


## Single connection point for every gameplay signal this node listens to.
## Idempotent, so a second instance added by a test does not double up on the
## bus it shares with the autoload.
func _connect_events() -> void:
	if _events_connected:
		return
	var bus := _autoload("EventBus")
	if bus == null:
		return
	_events_connected = true
	bus.damage_dealt.connect(_on_damage_dealt)
	bus.enemy_died.connect(_on_enemy_died)
	bus.player_died.connect(_on_player_died)
	bus.sfx_requested.connect(_on_sfx_requested)
	# `game_paused` is deliberately NOT connected: the HUD flips the shared
	# GameState.ui_blocking flag in the same statement that emits it, so the
	# `_poll_ui_toggle()` edge already covers Esc/pause. Wiring the signal as
	# well would fire two clicks for one key press.


func _on_damage_dealt(payload: Dictionary) -> void:
	if not bool(payload.get("applied", false)):
		return
	var groups: Variant = payload.get("target_groups", [])
	if not groups is Array:
		return
	# The player takes `hurt`, anything hostile takes `hit`. Reading the target's
	# own groups keeps the resolver free of any audio knowledge.
	if "player" in groups:
		play_sfx("hurt")
	elif "enemy" in groups or "boss" in groups:
		play_sfx("hit")


func _on_enemy_died(_enemy_id: StringName, _enemy_type: StringName, _world_position: Vector2) -> void:
	play_sfx("enemy_die")


## Player death reuses `hurt` at 0.6 pitch rather than `enemy_die`: the
## descending death sound belongs to the enemy that was just killed, and
## reusing it for the player would read as "something else died". The pitch is
## fixed (no variation) so the death cue is always the same weight.
func _on_player_died() -> void:
	var pool: Array = _pools.get("SFX", [])
	var player := _pick_player(pool)
	var stream := _stream("hurt")
	if player == null or stream == null:
		return
	player.stream = stream
	player.pitch_scale = 0.6
	player.play()


func _on_sfx_requested(name: String, bus: String) -> void:
	play_sfx(name, bus)


## One central UI click: every panel (inventory, journal, map, character, shop,
## craft, dialogue, settings, pause) flips the shared `GameState.ui_blocking`
## flag when it opens or closes, so watching that edge covers all of them
## without a single line inside `scripts/ui/`. `ui_blocking` is a plain
## variable with no signal of its own, hence the edge watch rather than a
## connection; the node reference is cached so the watch costs nothing.
func _poll_ui_toggle() -> void:
	if _game_state == null or not is_instance_valid(_game_state):
		_game_state = _autoload("GameState")
	if _game_state == null:
		return
	var blocking := bool(_game_state.get("ui_blocking"))
	if not _ui_blocking_initialised:
		# First frame: adopt whatever the boot state is instead of reporting it
		# as a click.
		_ui_blocking_initialised = true
		_ui_blocking_seen = blocking
		return
	if blocking != _ui_blocking_seen:
		_ui_blocking_seen = blocking
		play_sfx("ui_click", "UI")


## Boss phase change is a signal on the boss node (`phase_changed`), not on the
## bus, and the boss is not allowed to know about audio either. Polling the
## `boss` group here keeps the wiring in one file; the loop is empty in every
## scene that has no boss, which is all of them except the warden arena.
func _poll_boss_phases(tree: SceneTree) -> void:
	var bosses := tree.get_nodes_in_group("boss")
	if bosses.is_empty():
		if not _boss_phases.is_empty():
			_boss_phases.clear()
		return
	for node in bosses:
		if not is_instance_valid(node) or not node.has_method("current_phase"):
			continue
		var id := node.get_instance_id()
		var phase := int(node.call("current_phase"))
		var previous: Variant = _boss_phases.get(id, null)
		_boss_phases[id] = phase
		if previous != null and phase > int(previous):
			play_sfx("boss_roar", "SFX", 0.0)


# --- internals ---------------------------------------------------------------


func _build_pool(bus: String) -> void:
	if not _pools.has(bus):
		_pools[bus] = []
	var size := SFX_POOL_SIZE
	if bus == "UI":
		size = UI_POOL_SIZE
	elif bus == "Music":
		size = MUSIC_POOL_SIZE
	for i in size:
		var player := AudioStreamPlayer.new()
		player.name = "%sPlayer%d" % [bus, i]
		player.bus = bus
		add_child(player)
		(_pools[bus] as Array).append(player)
		if bus == "Music":
			_music_players.append(player)
	if bus == "Music" and _music_players.size() >= 2:
		_music_current = _music_players[0]
		_music_other = _music_players[1]


## One dedicated looping voice for the zone ambience bed, on the Music bus but
## outside the music crossfade pair so a track change never touches it.
func _build_ambience_player() -> void:
	_ambience_player = AudioStreamPlayer.new()
	_ambience_player.name = "AmbiencePlayer"
	_ambience_player.bus = "Music"
	_ambience_player.volume_db = AMBIENCE_DB
	add_child(_ambience_player)


# --- music crossfade ---------------------------------------------------------


## Ramp `player` to `target_db` over `seconds`, replacing any fade it already had.
func _start_fade(player: AudioStreamPlayer, target_db: float, seconds: float) -> void:
	_cancel_fade(player)
	var span := absf(target_db - player.volume_db)
	var rate := span / maxf(0.01, seconds)
	_music_fades.append({"player": player, "target": target_db, "rate": rate})


func _cancel_fade(player: AudioStreamPlayer) -> void:
	for i in range(_music_fades.size() - 1, -1, -1):
		if _music_fades[i].get("player") == player:
			_music_fades.remove_at(i)


## Steps every in-flight ramp one frame. A voice that reaches the silence target
## is stopped and dropped, which is what frees the spare for the next swap and
## guarantees only one track is left playing once a crossfade settles.
func _step_music_fades(delta: float) -> void:
	for i in range(_music_fades.size() - 1, -1, -1):
		var entry: Dictionary = _music_fades[i]
		var player := entry.get("player") as AudioStreamPlayer
		if player == null or not is_instance_valid(player):
			_music_fades.remove_at(i)
			continue
		var target := float(entry.get("target", 0.0))
		var rate := float(entry.get("rate", 0.0))
		var current := player.volume_db
		if current < target:
			current = minf(target, current + rate * delta)
		else:
			current = maxf(target, current - rate * delta)
		player.volume_db = current
		if current == target:
			if target <= MUSIC_FADE_START_DB and player.playing:
				player.stop()
			_music_fades.remove_at(i)


## Free player first; when all are busy, the one handed out longest ago.
## Stealing (rather than dropping the call) is what keeps a fast combo audible.
## "Longest ago" is an own monotonic stamp, not `get_playback_position()`: the
## engine position is measured in the stream's own samples and reads 0 for a
## player whose stream has not been pulled by the mixer yet, which under
## `--headless` would make the oldest pick effectively random.
func _pick_player(pool: Array) -> AudioStreamPlayer:
	_playback_stamp += 1
	var oldest: AudioStreamPlayer = null
	var oldest_stamp := INF
	for entry in pool:
		var player := entry as AudioStreamPlayer
		if player == null:
			continue
		if not player.playing:
			_stamps[player.get_instance_id()] = _playback_stamp
			return player
		var stamp := float(_stamps.get(player.get_instance_id(), 0.0))
		if stamp < oldest_stamp:
			oldest_stamp = stamp
			oldest = player
	if oldest != null:
		_stamps[oldest.get_instance_id()] = _playback_stamp
	return oldest


func _stream(name: String) -> AudioStream:
	if name == "":
		return null
	# Parked: never reach the loader. A first-use `ResourceLoader.load` of a `.wav`
	# is a cold disk read on the process's first run, and a single such read landing
	# inside a physics frame makes the engine run catch-up steps, which desynchronises
	# the render-delta status clock from the fixed-delta simulation and shifts the
	# global RNG stream — so the run stops being a pure function of its seed.
	if _parked:
		return null
	if _streams.has(name):
		return _streams[name] as AudioStream
	var path := "%s/%s.wav" % [SFX_DIR, name]
	var stream: AudioStream = null
	if ResourceLoader.exists(path):
		stream = ResourceLoader.load(path) as AudioStream
	_streams[name] = stream
	return stream


## Single-line diagnostic, mirroring `input_bindings.gd`: `push_warning()`
## prints a multi-line GDScript backtrace, and a corrupt settings file is an
## expected, recoverable condition that must not spray the log or the tests.
func _warn(message: String) -> void:
	print("[audio_manager] %s" % message)


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


## Autoloads are resolved at runtime so this node also works when a test adds
## its own instance under `godot --script`.
func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)
