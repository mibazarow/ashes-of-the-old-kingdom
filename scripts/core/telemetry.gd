extends Node
## Writes structured diagnostic logs under user://debug_runs/<run_id>/.
##
## Godot exits with code 0 even after runtime errors, so engine-level errors are
## captured here through a custom Logger and mirrored into errors.log.

## Bumped from 1 when the run directory grew the logs the spec's §20.1 asks for
## (`inputs.jsonl`, `performance.csv`, `observations.jsonl`, `quest_economy.jsonl`
## and the `replay/` pair) and `summary.md` grew the §20.5 verdict fields. A reader
## that knows schema 1 can still read every file it knew before; a reader that
## needs the verdict fields has to know it is reading schema 2.
const SCHEMA_VERSION := 2

## Wall interval between `performance.csv` samples. One line a second is what the
## spec's «по одному разу в секунду» asks for: enough to see a leak slope and a
## frame-time spike, small enough that a ten minute soak writes 600 lines and not
## 36 000.
const PERF_INTERVAL_MS := 1000

## The keys `summary.md` always carries, in the order the spec §20.5 lists them.
## Named once, here, so the builder, the guide and the test suite cannot drift
## apart over a copy of the list: the suite asserts against this constant, which
## is the same list the writer iterates its defaults from.
const SUMMARY_KEYS: Array[String] = ["RUN", "BUILD", "GODOT", "SCENARIO", "PROFILE", "SEED",
	"RESULT", "DURATION", "ZONES", "GOALS", "DEATHS", "STUCK", "WARNINGS", "ERRORS", "FATAL",
	"FIRST ANOMALY", "REPRO", "EVIDENCE", "NEXT ACTION"]

## The `extra` keys the block above already prints under their own name. Without this
## the caller's dictionary would also be dumped verbatim underneath, and a summary
## that says `SEED:` twice with two spellings is a summary that gets read wrong.
const SUMMARY_CONSUMED: Array[String] = ["RUN_ID", "BUILD_ID", "ENGINE", "SCENARIO", "PROFILE",
	"SEED", "SEED_SOURCE", "WORLD_SEED", "RESULT", "DURATION_MS", "ZONES", "GOALS", "DEATHS",
	"STUCK", "WARNINGS", "ERRORS", "FATAL", "FIRST_ANOMALY", "RERUN", "EVIDENCE", "NEXT_ACTION"]

## The seed a bot run gets when nobody asks for one. Fixed rather than derived: the
## whole reason a seed is recorded is that a PASS can be re-run and either fails
## again or does not, and a bot that picks a fresh seed every launch answers a
## question twice and settles it never.
const BOT_DEFAULT_SEED := 20261122

var run_id: String = ""
var run_dir: String = ""
var build_id: String = "dev"

## The seed the global RNG is running on, and how it was chosen. Recorded on every
## run, bot or not: a run whose seed was never written down cannot be re-created,
## which makes every claim about it unfalsifiable after the fact.
var seed_value: int = 0
var seed_source: String = "engine_default"

var _world_seed: int = -1
var _world_seed_resolved := false

var _events: FileAccess
var _combat: FileAccess
var _errors: FileAccess
var _decisions: FileAccess
var _inputs: FileAccess
var _observations: FileAccess
var _quest_economy: FileAccess
var _performance: FileAccess
var _replay: FileAccess
var _started_ms: int = 0
var _logger: Logger
var _perf_next_ms := 0
var _event_index := 0
## Set once the world signals have been wired. `Telemetry` is the first autoload in
## the list, so `EventBus` does not exist yet while `_ready` runs; the hooks are
## taken on the first process frame, when every autoload is a sibling.
var _world_hooks_taken := false

## Counters the §20.5 verdict line is built from. They live here rather than in the
## bot because a run that never reaches a verdict still has to report them: an
## engine error after the bot's own PASS is exactly the case a verdict written by
## the bot alone would hide.
var warning_count := 0
var error_count := 0
var fatal_count := 0
var stuck_count := 0
var death_count := 0
## The first thing that went wrong, with the clock reading it happened at. The spec
## asks for «FIRST ANOMALY» precisely because the last error in a log is rarely the
## one that started the cascade.
var first_anomaly: String = ""


func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	_apply_seed_from_cmdline()
	run_id = _make_run_id()
	run_dir = "user://debug_runs/%s" % run_id
	DirAccess.make_dir_recursive_absolute(run_dir)
	_events = _open("events.jsonl")
	_combat = _open("combat.jsonl")
	_errors = _open("errors.log")
	_decisions = _open("decisions.jsonl")
	_inputs = _open("inputs.jsonl")
	_observations = _open("observations.jsonl")
	_quest_economy = _open("quest_economy.jsonl")
	_performance = _open("performance.csv")
	_write_replay_seed()
	_replay = _open("replay/commands.jsonl")
	_write_performance_header()
	_install_engine_logger()
	write_run_meta()
	event("run_start", {
		"run_id": run_id,
		"engine": Engine.get_version_info().get("string", ""),
		"seed": seed_value,
		"seed_source": seed_source,
		"world_seed": world_seed(),
	})


## The `replay/` pair the spec §20.1 asks for. `seed.txt` is plain text rather than
## JSON on purpose: it is the one file in the directory a human is expected to read
## in order to re-create the run, and the first thing they need is the number.
func _write_replay_seed() -> void:
	DirAccess.make_dir_recursive_absolute(run_dir.path_join("replay"))
	var f := FileAccess.open(run_dir.path_join("replay/seed.txt"), FileAccess.WRITE)
	if f == null:
		return
	f.store_line("seed=%d" % seed_value)
	f.store_line("seed_source=%s" % seed_source)
	f.store_line("world_seed=%d" % world_seed())
	f.store_line("build_id=%s" % build_id)
	f.store_line("engine=%s" % Engine.get_version_info().get("string", ""))
	f.close()


func _write_performance_header() -> void:
	if _performance == null:
		return
	_performance.store_line(
		"elapsed_ms,physics_frames,fps,process_ms,node_count,orphan_nodes,object_count")
	_performance.flush()


## Wires the world signals the quest/economy stream and the death counter read.
## Deferred out of `_ready` because `Telemetry` is the first autoload: `EventBus`
## is not a sibling yet at that point. Called from `_process` until it succeeds,
## and it never fails the run — a telemetry hook that cannot be taken costs a
## stream, not a game.
func _take_world_hooks() -> void:
	if _world_hooks_taken:
		return
	var bus := get_tree().root.get_node_or_null("EventBus")
	if bus == null:
		return
	_world_hooks_taken = true
	# Connected by name rather than through the typed signal property: `Telemetry`
	# cannot name `EventBus` at compile time, because it is the autoload that runs
	# first and the bus is not a declared dependency of this script.
	bus.connect(&"quest_started", _on_t_quest_started)
	bus.connect(&"quest_progress", _on_t_quest_progress)
	bus.connect(&"quest_completed", _on_t_quest_completed)
	bus.connect(&"player_gold_changed", _on_t_gold_changed)
	bus.connect(&"item_picked", _on_t_item_picked)
	bus.connect(&"equipment_changed", _on_t_equipment_changed)
	bus.connect(&"player_died", _on_t_player_died)


func _process(_delta: float) -> void:
	_take_world_hooks()
	var now := Time.get_ticks_msec()
	if now < _perf_next_ms:
		return
	_perf_next_ms = now + PERF_INTERVAL_MS
	_sample_performance(now)


## One row of `performance.csv`. Read off the engine's own monitors rather than
## from a private accumulator, so the numbers are the ones the editor's profiler
## would show. `orphan_nodes` is the column a leak shows up in first: a soak whose
## orphan count climbs every second is freeing nothing.
func _sample_performance(now: int) -> void:
	if _performance == null:
		return
	_performance.store_line(",".join([
		str(now - _started_ms),
		str(Engine.get_physics_frames()),
		"%.2f" % Performance.get_monitor(Performance.TIME_FPS),
		"%.3f" % Performance.get_monitor(Performance.TIME_PROCESS),
		str(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))),
		str(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))),
		str(int(Performance.get_monitor(Performance.OBJECT_COUNT))),
	]))
	_performance.flush()


func _on_t_quest_started(quest_id: StringName) -> void:
	quest_economy({"event": "quest_started", "quest": String(quest_id)})


func _on_t_quest_progress(quest_id: StringName, current: int, target: int) -> void:
	quest_economy({"event": "quest_progress", "quest": String(quest_id),
		"current": current, "target": target})


func _on_t_quest_completed(quest_id: StringName) -> void:
	quest_economy({"event": "quest_completed", "quest": String(quest_id)})


func _on_t_gold_changed(amount: int) -> void:
	var state := get_tree().root.get_node_or_null("GameState")
	quest_economy({"event": "gold_changed", "delta": amount,
		"gold": int(state.get("gold")) if state != null else 0})


func _on_t_item_picked(item_id: StringName, amount: int) -> void:
	quest_economy({"event": "item_picked", "item": String(item_id), "amount": amount})


func _on_t_equipment_changed() -> void:
	quest_economy({"event": "equipment_changed"})


func _on_t_player_died() -> void:
	# Counted, not treated as an anomaly: a hero who falls to a boar and gets back up
	# has had a Tuesday, and the soak's whole point is to have a lot of Tuesdays. The
	# STUCK field is for a hero who cannot move, and DEATHS is the field for this one.
	death_count += 1


## Chooses the seed for this process and puts it on the global RNG before anything
## can roll. Three sources, in this order of priority:
##
## * `--seed=N` on the command line — the operator names the run;
## * a bot run with no `--seed=` — the fixed bot seed, so two launches of the same
##   scenario are the same run and a PASS means something next week;
## * everything else — a seed drawn from the wall clock, so a human does not live
##   the same critical hits twice, while the number is still written down and the
##   session is still reproducible from the log.
##
## Godot seeds the global RNG itself, unpredictably, and offers no way to read that
## choice back. Taking the seed here is the only way the recorded number is the
## number that was actually in force.
func _apply_seed_from_cmdline() -> void:
	var requested := 0
	var has_requested := false
	var is_bot := false
	for argument: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if argument.begins_with("--seed="):
			requested = int(argument.trim_prefix("--seed="))
			has_requested = true
		elif argument.begins_with("--bot="):
			is_bot = true
	if has_requested:
		seed_value = requested
		seed_source = "cmdline"
	elif is_bot:
		seed_value = BOT_DEFAULT_SEED
		seed_source = "bot_default"
	else:
		seed_value = int(Time.get_unix_time_from_system() * 1000.0) % 2147483647
		seed_source = "generated"
	seed(seed_value)


## The seed the forest's procedural pass builds its trees and road from. Read off
## the zone script rather than copied into a constant here: a number written into
## two files is a number that drifts, and a recorded seed that is not the seed the
## world was generated from is worse than no seed at all, because it invites
## re-runs that cannot match. Zones authored entirely by hand have no procedural
## seed to report and read as 0.
func world_seed() -> int:
	if _world_seed_resolved:
		return _world_seed
	_world_seed_resolved = true
	_world_seed = 0
	var path := "res://scripts/world/forest.gd"
	if not ResourceLoader.exists(path):
		return _world_seed
	var script := load(path) as GDScript
	if script == null:
		return _world_seed
	_world_seed = int(script.get_script_constant_map().get("MAP_SEED", 0))
	return _world_seed


## Re-records the seed after the process learned a better one, so a run that was
## re-seeded late still reports the seed it actually finished on.
func set_run_seed(value: int, source: String) -> void:
	seed_value = value
	seed_source = source
	seed(value)
	write_run_meta()
	event("run_seed", {"seed": value, "source": source, "world_seed": world_seed()})


func _make_run_id() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true)
	# "2026-11-18 18:17:11" -> "20261118-181711"; spaces are not safe in paths.
	stamp = stamp.replace("-", "").replace(":", "").replace(" ", "-").replace("T", "-")
	return "%s-%03d" % [stamp, Time.get_ticks_msec() % 1000]


func _open(file_name: String) -> FileAccess:
	var f := FileAccess.open(run_dir.path_join(file_name), FileAccess.WRITE)
	if f == null:
		push_error("Telemetry: cannot open %s" % file_name)
	return f


func _install_engine_logger() -> void:
	if not OS.has_method("add_logger"):
		return
	_logger = _make_logger()
	if _logger != null:
		OS.add_logger(_logger)


func _make_logger() -> Logger:
	var logger := preload("res://scripts/core/telemetry_logger.gd").new()
	logger.sink = self
	return logger


func elapsed_ms() -> int:
	return Time.get_ticks_msec() - _started_ms


func _base(event_type: StringName) -> Dictionary:
	return {
		"ts": elapsed_ms(),
		"run_id": run_id,
		"build_id": build_id,
		"type": String(event_type),
	}


func event(event_type: StringName, data: Dictionary = {}) -> void:
	var payload := _base(event_type)
	for k in data:
		payload[String(k)] = data[k]
	_write(_events, payload)


## One input edge: an action that changed state, with the physics frame it changed
## on and who pressed it. Edges only, never the held-every-frame restatement of the
## same press — the spec §20.3 forbids writing a value every frame, and a 600 s soak
## at four movement keys per step would be 144 000 lines saying nothing new.
##
## The same edge is mirrored into `replay/commands.jsonl` as the ordered command
## stream: press, frame, action. That file is the score the run was played from, and
## a reviewer who cannot replay the run cannot check any claim about it.
func input(data: Dictionary) -> void:
	var payload := _base(&"input")
	for k in data:
		payload[String(k)] = data[k]
	_write(_inputs, payload)
	if bool(payload.get("pressed", false)):
		var command := _base(&"command")
		command["action"] = payload.get("action", "")
		command["frame"] = payload.get("frame", 0)
		_write(_replay, command)


## One sampled reading of the world: where the hero stood, what he was made of, what
## was nearest, which goal the bot thought it was pursuing. Written on the bot's
## one-second watch, so a verdict can be read against the state that produced it
## instead of against a note the bot wrote from memory afterwards.
func observation(data: Dictionary) -> void:
	var payload := _base(&"observation")
	for k in data:
		payload[String(k)] = data[k]
	_write(_observations, payload)


## One quest or economy transaction. Written off the EventBus, so the stream records
## what the world actually paid and not what the scenario meant to spend.
func quest_economy(data: Dictionary) -> void:
	var payload := _base(&"quest_economy")
	for k in data:
		payload[String(k)] = data[k]
	payload["gold"] = _gold_reading()
	_write(_quest_economy, payload)


## A soft anomaly the run survived: a leg that gave up, a chest that was not there, a
## gate that had to be knocked twice. Counted into WARNINGS and written to the same
## errors.log the engine writes to, because a run that reports no problems while
## quietly working around them is the run nobody trusts.
func warning(line: String) -> void:
	warning_count += 1
	_note_first_anomaly(line)
	if _errors == null:
		return
	_errors.store_line("[%d] WARNING %s" % [elapsed_ms(), line])
	_errors.flush()


## A hard anomaly: the run could not have gone on. A vanished player, a world node
## that stopped answering, a scenario aborted from outside its own budget.
func fatal(line: String) -> void:
	fatal_count += 1
	_note_first_anomaly(line)
	error(line)


## One watchdog detection. Counted into STUCK — the spec's verdict field for a hero
## who kept pressing keys against a wall — and named in FIRST ANOMALY the first time
## it happens.
func note_anomaly(kind: String, detail: String = "") -> void:
	stuck_count += 1
	_note_first_anomaly(kind if detail == "" else "%s at %s" % [kind, detail])


func _note_first_anomaly(line: String) -> void:
	if first_anomaly != "":
		return
	first_anomaly = "%s - %s" % [_fmt_clock(elapsed_ms()), line]


func _gold_reading() -> int:
	var state := get_tree().root.get_node_or_null("GameState")
	return int(state.get("gold")) if state != null else 0


func error(line: String) -> void:
	# The engine logger hands every stderr line through here, and Godot prints
	# warnings down the same channel. A warning is not an error and must not
	# inflate the error column of a verdict, so the severity is read off the line
	# the logger wrote rather than assumed from the channel.
	if line.contains("WARNING"):
		warning_count += 1
	else:
		error_count += 1
		_note_first_anomaly(line)
	if _errors == null:
		return
	_errors.store_line("[%d] %s" % [elapsed_ms(), line])
	_errors.flush()


func combat(data: Dictionary) -> void:
	var payload := _base(&"combat")
	for k in data:
		payload[String(k)] = data[k]
	_write(_combat, payload)
	_write(_events, payload)


func decision(data: Dictionary) -> void:
	var payload := _base(&"decision")
	for k in data:
		payload[String(k)] = data[k]
	_write(_decisions, payload)
	_write(_events, payload)


func _write(f: FileAccess, payload: Dictionary) -> void:
	if f == null:
		return
	if f == _events:
		# The line number inside `events.jsonl`, stamped onto the line itself. The
		# spec's EVIDENCE field is meant to point at a moment — «combat.jsonl event
		# 1842» — and a pointer that names a file with 40 000 lines in it and no
		# ordinal is not a pointer. Counted here rather than in `event()` because
		# `combat()` and `decision()` mirror their records into the same stream, and
		# every line of it has to be findable by the number the verdict quotes.
		_event_index += 1
		payload["index"] = _event_index
	f.store_line(JSON.stringify(payload))
	f.flush()


func write_run_meta(extra: Dictionary = {}) -> void:
	var meta := {
		"schema": SCHEMA_VERSION,
		"run_id": run_id,
		"build_id": build_id,
		"engine": Engine.get_version_info(),
		"started_at": Time.get_datetime_string_from_system(true),
		"platform": OS.get_name(),
		"seed": seed_value,
		"seed_source": seed_source,
		"world_seed": world_seed(),
	}
	for k in extra:
		meta[String(k)] = extra[k]
	var f := FileAccess.open(run_dir.path_join("run_meta.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()


## `HH:MM:SS` for the verdict line, which the spec writes as a clock and not as a
## millisecond count: a human reading a failure at 03:12:47 knows which third of a
## soak to go and look at.
func _fmt_clock(ms: int) -> String:
	var total := maxi(int(ms / 1000.0), 0)
	return "%02d:%02d:%02d" % [total / 3600, int(total / 60.0) % 60, total % 60]


## The §20.5 verdict block, built as a pure function of (result, extra) so it can be
## held up against the spec without sitting through a run. Every key in
## `SUMMARY_KEYS` is emitted on its own line whether or not the caller supplied it —
## a missing field is written as `-`, never left out, because a summary that quietly
## drops DEATHS is indistinguishable from a run that had none, and that is the exact
## way a bad release reads as a good one.
##
## `extra` keys the block does not already own are appended after it, which is how
## the scenarios keep reporting their own notes without editing this file.
func build_summary(result: String, extra: Dictionary = {}) -> PackedStringArray:
	var duration_ms := int(extra.get("duration_ms", elapsed_ms()))
	var lines := PackedStringArray()
	lines.append("RUN: %s" % String(extra.get("run_id", run_id)))
	lines.append("BUILD: %s" % String(extra.get("build_id", build_id)))
	lines.append("GODOT: %s" % String(
		extra.get("engine", Engine.get_version_info().get("string", ""))))
	lines.append("SCENARIO: %s" % String(extra.get("scenario", "-")))
	lines.append("PROFILE: %s" % String(extra.get("profile", "-")))
	lines.append("SEED: %d (%s)" % [int(extra.get("seed", seed_value)),
		String(extra.get("seed_source", seed_source))])
	lines.append("WORLD_SEED: %d" % int(extra.get("world_seed", world_seed())))
	lines.append("RESULT: %s" % String(extra.get("result", result)))
	lines.append("DURATION: %s" % _fmt_clock(duration_ms))
	lines.append("DURATION_MS: %d" % duration_ms)
	lines.append("ZONES: %s" % String(extra.get("zones", "-")))
	lines.append("GOALS: %s" % String(extra.get("goals", "-")))
	lines.append("DEATHS: %d" % int(extra.get("deaths", death_count)))
	lines.append("STUCK: %d" % int(extra.get("stuck", stuck_count)))
	lines.append("WARNINGS: %d" % int(extra.get("warnings", warning_count)))
	lines.append("ERRORS: %d" % int(extra.get("errors", error_count)))
	lines.append("FATAL: %d" % int(extra.get("fatal", fatal_count)))
	lines.append("FIRST ANOMALY: %s" % String(extra.get("first_anomaly",
		first_anomaly if first_anomaly != "" else "-")))
	lines.append("REPRO: %s" % String(extra.get("rerun", "-")))
	lines.append("EVIDENCE: %s" % String(extra.get("evidence",
		"events.jsonl event %d" % _event_index)))
	# NEXT ACTION is the field that turns a verdict into work. A PASS has nothing to
	# chase, so it says so with `-`; a FAIL that names no action still gets the one
	# step that is always correct, which is to re-run the recorded seed and read the
	# first anomaly — the two things a reader would otherwise have to be told twice.
	var next_action := String(extra.get("next_action", ""))
	if next_action == "":
		next_action = "-" if String(extra.get("result", result)).to_upper() != "FAIL" \
				else "re-run with --seed=%d and read FIRST ANOMALY" % int(extra.get("seed", seed_value))
	lines.append("NEXT ACTION: %s" % next_action)
	for k in extra:
		var key := String(k).to_upper()
		if key in SUMMARY_KEYS or key in SUMMARY_CONSUMED:
			continue
		lines.append("%s: %s" % [key, str(extra[k])])
	return lines


func write_summary(result: String, extra: Dictionary = {}) -> void:
	var lines := build_summary(result, extra)
	var f := FileAccess.open(run_dir.path_join("summary.md"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("[telemetry] run=%s result=%s" % [run_id, result])


func _exit_tree() -> void:
	for f in [_events, _combat, _errors, _decisions, _inputs, _observations,
			_quest_economy, _performance, _replay]:
		if f != null:
			f.flush()
			f.close()
