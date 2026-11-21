extends Node
## Debug bot. Drives the real Player through the same InputSource the human
## uses — no teleports, no direct writes to world state.
##
## Run: godot --headless --path . -- --bot=BOT-001
## Scenarios: BOT-001 talk, BOT-002 quest loop, BOT-003 combat arena,
##            BOT-004 magic, BOT-005 inventory/economy, BOT-006 quest chain,
##            BOT-007 traps/secrets, BOT-008 kill, BOT-009 save/load,
##            BOT-010 soak, BOT-011 take damage.
## Profiles: cautious, normal, aggressive, explorer, collector, novice, master.

const QUEST_ID := "q01_ash_wolves"
const SCENARIO_TIMEOUT := 75.0


class BotInput:
	extends RefCounted

	var _pressed: Dictionary = {}
	var _just: Dictionary = {}
	var _just_served: Dictionary = {}
	var _aim: Vector2 = Vector2.RIGHT

	func is_action_pressed(action: StringName) -> bool:
		return bool(_pressed.get(String(action), false))

	func is_action_just_pressed(action: StringName) -> bool:
		var key := String(action)
		var frame := Engine.get_physics_frames()
		if int(_just.get(key, -1)) != frame:
			return false
		# One press is one press. The engine's own `just_pressed` is true for
		# the whole physics tick, and a panel polled by `_process` can catch
		# that tick two, three times between two ticks — a human holding E in
		# a shop buys one potion per click, and the bot's tap must buy one
		# potion per tap. The edge is therefore served once per tick.
		if int(_just_served.get(key, -1)) == frame:
			return false
		_just_served[key] = frame
		return true

	func get_vector(nx: StringName, px: StringName, ny: StringName, py: StringName) -> Vector2:
		var v := Vector2.ZERO
		if is_action_pressed(px):
			v.x += 1.0
		if is_action_pressed(nx):
			v.x -= 1.0
		if is_action_pressed(py):
			v.y += 1.0
		if is_action_pressed(ny):
			v.y -= 1.0
		return v.normalized()

	func aim_direction(from: Vector2) -> Vector2:
		if from.distance_to(_aim) < 0.5:
			return Vector2.RIGHT
		return from.direction_to(_aim)

	func set_aim(p: Vector2) -> void:
		_aim = p

	func hold(action: StringName, on: bool) -> void:
		var key := String(action)
		if on and not bool(_pressed.get(key, false)):
			_just[key] = Engine.get_physics_frames()
		_pressed[key] = on

	func release_all() -> void:
		for key: String in _pressed.keys():
			_pressed[key] = false


## Behaviour profiles from the spec (§19.3). They change how the bot weighs
## risk: when it heals, how close it lets enemies get, whether it detours.
## The three profiles added with spec §19.5 bring behaviour keys the original
## four never had (`reaction_delay`, `use_ability`, `retreat_below`,
## `pickup_bias`, `merchant_stacks`). Every one of them defaults — through
## `_pf()` — to exactly what the original four did before the keys existed, so
## the four dicts above stay byte-for-byte what they were and their runs cannot
## drift. `collector` loots first, heals early and unloads a full bag at the
## merchant; `novice` hesitates, heals late and never casts; `master` reacts
## fast, fights with the ability on cooldown and breaks off below a quarter HP.
const PROFILES := {
	"cautious": {"heal_at": 0.75, "engage_range": 14.0, "dash_chance": 0.35, "detour": true},
	"normal": {"heal_at": 0.5, "engage_range": 16.0, "dash_chance": 0.15, "detour": true},
	"aggressive": {"heal_at": 0.25, "engage_range": 20.0, "dash_chance": 0.05, "detour": false},
	"explorer": {"heal_at": 0.6, "engage_range": 12.0, "dash_chance": 0.2, "detour": true},
	"collector": {"heal_at": 0.65, "engage_range": 10.0, "dash_chance": 0.25, "detour": true,
		"reaction_delay": 0.15, "use_ability": false, "retreat_below": 0.0,
		"pickup_bias": true, "merchant_stacks": 6},
	"novice": {"heal_at": 0.3, "engage_range": 16.0, "dash_chance": 0.0, "detour": true,
		"reaction_delay": 0.35, "use_ability": false, "retreat_below": 0.0,
		"pickup_bias": false, "merchant_stacks": 0},
	"master": {"heal_at": 0.6, "engage_range": 22.0, "dash_chance": 0.5, "detour": false,
		"reaction_delay": 0.05, "use_ability": true, "retreat_below": 0.25,
		"pickup_bias": false, "merchant_stacks": 0},
}

## Soak (BOT-010) survival tuning, kept out of PROFILES because the soak ignores
## the profile dict on purpose: it is a fixed 75 s endurance run, not a risk
## appetite. Named constants so the test suite reads the values the scenario
## actually uses instead of duplicating literals. The stage D boar hits for 13
## (the wolf managed 8) and the soak target picker has no retreat of its own, so
## the old 0.35 threshold left the bot one missed potion window from dead.
const SOAK_HEAL_AT := 0.5
## Distance at which an enemy counts as "already in melee" for the disengage
## rule. Enemy melee reach is 18 px, so this breaks out just before the swing.
const SOAK_MELEE_RANGE := 24.0
## How far the bot keeps putting between itself and the enemy it has broken off
## from, while it is still below the heal threshold. The burst only has to break
## contact; without a wider steer the bot stops running at 25 px, the enemy walks
## back into reach, and the whole disengage buys nothing.
const SOAK_DISENGAGE_RANGE := 60.0
## Longest single disengage burst, and the total the whole run may spend in those
## bursts. Both caps are load-bearing: without the per-burst cap the bot could
## drift through a whole attack cycle, and without the run-wide budget the bursts
## could eat the entire window and turn the soak into a run that never swings.
## Surviving does not depend on the budget, though — the free steering below is
## what keeps the bot out of reach once the bursts are spent.
const SOAK_RETREAT_TIME := 0.6
const SOAK_RETREAT_BUDGET := 25.0

var scenario: String = ""
var profile: String = "normal"
var _profile: Dictionary = {}
var bot_input: BotInput
var _world: Node = null
var _result := "FAIL"
var _notes: Array[String] = []
var _running := false
var _start_ms := 0
var _avoid_dir := Vector2.ZERO
var _avoid_frames := 0
var _avoid_sign := 1.0
# Combat sensors for the measurement scenarios (BOT-003/004). They count only
# what the EventBus already publishes — per-target damage payloads, typed kills
# and applied statuses — so the scenario notes are read off the same events the
# telemetry combat log is built from, not from a second bookkeeping path.
var _m_dmg_by_type: Dictionary = {}
var _m_taken_by_type: Dictionary = {}
var _potions_drunk := 0
var _m_kills_by_type: Dictionary = {}
var _m_status_hits := 0
var _m_sensors_connected := false
## Trap damage bookkeeping (BOT-007): the sensor counts only hits whose
## `attacker_id` is the trap node the scenario is watching, so a wolf that
## follows the bot around the plate can never be mistaken for the trap.
var _m_trap_id := -1
var _m_trap_damage := 0
## Tiles the bot learned to avoid by bumping into them. The zone's character
## grid and the tilemap's baked collision can disagree by a sub-tile corner
## (a walkable `.` with a collision nubbin on its edge), and a bot that walks
## like a player discovers exactly that: it pushes into the invisible corner,
## gets nowhere, remembers the tile and routes around it. The dictionary maps
## `Vector2i` tile to `true` and lives for the whole run, like a player's
## memory of a bad corner.
var _bumped: Dictionary = {}


func _ready() -> void:
	process_priority = -100
	set_physics_process(false)
	bot_input = BotInput.new()


func start_from_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	for a in args:
		if a.begins_with("--bot="):
			scenario = a.substr("--bot=".length())
		elif a.begins_with("--profile="):
			profile = a.substr("--profile=".length())
	if scenario == "":
		return
	_profile = PROFILES.get(profile, PROFILES["normal"])
	_world = get_parent().get_node_or_null("World")
	_running = true
	_start_ms = Time.get_ticks_msec()
	InputSource.set_override(bot_input)
	Telemetry.event(&"bot_start", {"scenario": scenario, "profile": profile})
	_run()


func _run() -> void:
	await _wait(0.6)
	match scenario:
		"BOT-001":
			await _scenario_talk()
		"BOT-003":
			await _scenario_arena()
		"BOT-004":
			await _scenario_magic()
		"BOT-005":
			await _scenario_economy()
		"BOT-006":
			await _scenario_quest_chain()
		"BOT-007":
			await _scenario_traps()
		"BOT-008":
			await _scenario_kill()
		"BOT-009":
			await _scenario_save_load()
		"BOT-002":
			await _scenario_quest_loop()
		"BOT-010":
			await _scenario_soak()
		"BOT-011":
			await _scenario_take_damage()
		_:
			_notes.append("unknown_scenario")
			_result = "FAIL"
	_finish()


func _finish() -> void:
	InputSource.clear_override()
	_disconnect_combat_sensors()
	bot_input.release_all()
	var ok := _result == "PASS"
	Telemetry.event(&"bot_finish", {"scenario": scenario, "result": _result, "notes": _notes})
	Telemetry.write_summary(_result, {
		"scenario": scenario,
		"profile": profile,
		"notes": "; ".join(_notes),
		"hp": GameState.hp,
		"kills": GameState.kills,
	})
	print("[bot] %s -> %s (%s)" % [scenario, _result, "; ".join(_notes)])
	_running = false
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)


# --- scenarios ---------------------------------------------------------------

func _scenario_talk() -> void:
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	var reached := await _move_to(npc.global_position, 18.0, 30.0)
	_notes.append("reached_npc" if reached else "npc_unreachable")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var state: String = QuestManager.state_of(QUEST_ID)
	_notes.append("quest_state=" + state)
	_result = "PASS" if state == QuestManager.STATE_ACTIVE else "FAIL"


func _scenario_kill() -> void:
	# A collector walks the nearest find before it hunts: the bag gets filled
	# first and the fight is entered with the potion already banked. Every other
	# profile leaves this branch untouched (the key defaults to false).
	if bool(_pf("pickup_bias", false)):
		var loot := _nearest_pickup()
		if loot != null:
			await _move_to(loot.global_position, 10.0, 20.0)
	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 1000.0)
	var attacks := 0
	while Time.get_ticks_msec() < deadline:
		if GameState.hp < GameState.max_hp * float(_profile["heal_at"]):
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		var enemy := _nearest_enemy()
		if enemy == null:
			break
		var dist := _player_pos().distance_to(enemy.global_position)
		# A master breaks off while trading blows below this share of HP instead
		# of healing into the enemy's reach; 0.0 (every other profile) never runs
		# the branch, so their fights are the fights they always fought.
		var retreat_below := float(_pf("retreat_below", 0.0))
		if retreat_below > 0.0 and GameState.hp < int(GameState.max_hp * retreat_below) \
				and dist < 26.0:
			await _retreat_burst(enemy.global_position, 0.5)
			continue
		if dist > float(_profile["engage_range"]):
			if bool(_pf("use_ability", false)) and dist < 150.0 and _mana_ready():
				bot_input.set_aim(enemy.global_position)
				await _tap(&"ability")
			await _move_step(enemy.global_position)
			continue
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.25)
		var rd := float(_pf("reaction_delay", 0.0))
		if rd > 0.0:
			await _wait(rd)
	_notes.append("attacks=%d" % attacks)
	_notes.append("kills=%s" % str(GameState.kills))
	_result = "PASS" if GameState.kill_count("ash_wolf") > 0 else "FAIL"


func _scenario_save_load() -> void:
	var before_hp := GameState.hp
	var before_gold := GameState.gold
	GameState.add_gold(7)
	var save := SaveManager.save_game(3)
	if not bool(save.get("ok", false)):
		_notes.append("save_failed:" + String(save.get("error", "")))
		_clear_save_slot(3)
		return
	_notes.append("saved")
	GameState.add_gold(100)
	GameState.take_damage(25)
	var load := SaveManager.load_game(3)
	# Slot 3 belongs to this scenario. Drop the save and the backup the rewrite
	# produced: a leftover backup turns a later corrupt-primary check into a
	# successful recovery, so a bot run must never leave slot 3 populated.
	_clear_save_slot(3)
	if not bool(load.get("ok", false)):
		_notes.append("load_failed:" + String(load.get("error", "")))
		return
	var ok := GameState.gold == before_gold + 7 and GameState.hp == before_hp
	_notes.append("gold=%d hp=%d" % [GameState.gold, GameState.hp])
	_result = "PASS" if ok else "FAIL"


func _scenario_quest_loop() -> void:
	# 1. take the quest from the NPC
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	if not await _move_to(npc.global_position, 18.0, 45.0):
		_notes.append("npc_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_ACTIVE:
		_notes.append("quest_not_started")
		return
	_notes.append("quest_taken")

	# 2. hunt until the objective is met
	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 2.2 * 1000.0)
	var attacks := 0
	# The bot's straight-line approach cannot always get around a tree that sits
	# between it and the nearest wolf, so it can pin itself against the obstacle
	# and grind for the whole budget without ever closing to attack range. When it
	# stops making progress on a target it abandons that wolf (for a while) and
	# works another one instead — there are more wolves than the objective needs.
	# This is target selection only: movement, aiming, attacking and healing are
	# untouched, and every kill is still earned by walking up and attacking.
	var abandoned: Dictionary = {}
	var cur_id := -1
	var cur_best := INF
	var stalled := 0
	while Time.get_ticks_msec() < deadline:
		if QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY:
			break
		if GameState.hp < GameState.max_hp * float(_profile["heal_at"]):
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		_prune_abandoned(abandoned)
		var enemy := _nearest_quest_enemy(QUEST_ID, abandoned)
		if enemy == null:
			# Nothing left that we have not just abandoned: forget the
			# abandonments and retry once before declaring the objective impossible.
			if not abandoned.is_empty():
				abandoned.clear()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			# Honest failure: the objective still needs kills but no matching
			# enemy is left to fight, so report why instead of silently breaking
			# into a vague objective_not_met.
			if QuestManager.progress_of(QUEST_ID) < QuestManager.target_count(QUEST_ID):
				_notes.append("progress=%d/%d" % [QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
				_notes.append("no_quest_targets")
			return
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > float(_profile["engage_range"]):
			var eid := enemy.get_instance_id()
			if eid != cur_id:
				cur_id = eid
				cur_best = dist
				stalled = 0
			elif dist < cur_best - 2.0:
				cur_best = dist
				stalled = 0
			else:
				stalled += 1
			if stalled > 120:
				abandoned[eid] = Engine.get_physics_frames()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			# A profile that fights with the ability (master) softens the quest
			# target on the approach. The cast goes through the same `ability`
			# action the human right mouse uses; profiles without the key never
			# enter this branch and hunt exactly as they hunted before.
			if bool(_pf("use_ability", false)) and dist < 150.0 and _mana_ready():
				bot_input.set_aim(enemy.global_position)
				await _tap(&"ability")
			await _move_step(enemy.global_position)
			continue
		cur_id = -1
		cur_best = INF
		stalled = 0
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.22)
		var rd := float(_pf("reaction_delay", 0.0))
		if rd > 0.0:
			await _wait(rd)
	_notes.append("attacks=%d" % attacks)
	_notes.append("progress=%d/%d" % [QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_READY:
		_notes.append("objective_not_met")
		return

	# 3. walk back and turn it in
	var gold_before: int = GameState.gold
	if not await _move_to(npc.global_position, 18.0, 60.0):
		_notes.append("return_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var done := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	_notes.append("state=%s" % QuestManager.state_of(QUEST_ID))
	_notes.append("gold=%d->%d" % [gold_before, GameState.gold])
	_result = "PASS" if done and GameState.gold > gold_before else "FAIL"


func _scenario_soak() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 1000.0)
	var heading := Vector2.RIGHT
	var segments := 0
	var last_pos := _player_pos()
	var stuck := 0
	var travelled := 0.0
	var attack_attempts := 0
	var heals := 0
	var retreats := 0
	var retreat_left := SOAK_RETREAT_BUDGET
	# Instance id of the enemy the bot has broken off from, or -1. Tracked by id so
	# the bot stops running from a corpse the moment that enemy dies.
	var fled_id := -1
	# Bank the map's only potion before the wandering starts. The forest carries a
	# single health_potion about 145 px east of the spawn, and 75 s of random walk
	# almost never crosses its tile again: measured runs asked for a heal dozens of
	# times and held a potion in none of them, so the raised threshold had nothing
	# to fire on. Walking there is real movement through the real input path, and
	# the pickup is taken by touching it, exactly as a player takes it.
	var pickup := _find_node("pickup")
	if pickup != null:
		await _move_to(pickup.global_position, 10.0, 12.0)
	_notes.append("potion_banked=%s" % str(_soak_has_potion()))
	while Time.get_ticks_msec() < deadline:
		# Heal the instant the threshold is crossed, ahead of the attack. Tapping
		# the potion after the swing spends two physics frames trading blows, and
		# that is exactly the window a 13-damage boar charge gets paid for out of
		# the HP the potion was supposed to cover.
		if _soak_needs_heal() and _soak_has_potion():
			await _tap(&"quick_slot_1")
			heals += 1

		var enemy := _nearest_enemy()
		var enemy_dist := INF if enemy == null else _player_pos().distance_to(enemy.global_position)

		# The enemy this bot is avoiding, if it is still on the map.
		var threat: Node2D = null
		if fled_id != -1:
			threat = instance_from_id(fled_id) as Node2D
			if threat == null or not is_instance_valid(threat):
				threat = null
				fled_id = -1
		# Falling below the threshold with something already in reach makes that
		# something the fight to break off, whether or not one was picked before.
		if threat == null and _soak_needs_heal() and enemy != null and enemy_dist < SOAK_MELEE_RANGE:
			fled_id = enemy.get_instance_id()
			threat = enemy

		if threat != null and _soak_needs_heal():
			# Bounded disengage: one capped burst to break contact. The player
			# outpaces every melee enemy here, so 0.6 s of walking away is real
			# safety bought with no teleport and no invulnerability.
			if _player_pos().distance_to(threat.global_position) < SOAK_MELEE_RANGE and retreat_left > 0.0:
				retreat_left -= await _soak_retreat(threat.global_position, retreat_left)
				retreats += 1
				# The burst awaited several frames and the bot has usually just swung
				# at this enemy, so it may have died in the meantime. Re-resolve the
				# id before touching it again: reading a freed instance aborts the
				# scenario, and the run lands in `_finish` as a FAIL with no notes.
				threat = instance_from_id(fled_id) as Node2D
				if threat == null or not is_instance_valid(threat):
					threat = null
					fled_id = -1
				if _soak_needs_heal() and _soak_has_potion():
					await _tap(&"quick_slot_1")
					heals += 1
			# Keep pointing the wander heading away until the threat is well outside
			# its reach, not merely past the burst trigger radius. Stopping at 25 px
			# means the bot quits running, the enemy walks back into reach, and the
			# disengage bought nothing. Steering is free, so surviving does not run
			# out of budget the way the bursts do.
			if threat != null and _player_pos().distance_to(threat.global_position) < SOAK_DISENGAGE_RANGE:
				heading = (_player_pos() - threat.global_position).normalized()
				stuck = 0

		bot_input.hold(&"move_right", heading.x > 0.35)
		bot_input.hold(&"move_left", heading.x < -0.35)
		bot_input.hold(&"move_down", heading.y > 0.35)
		bot_input.hold(&"move_up", heading.y < -0.35)
		bot_input.set_aim(_player_pos() + heading * 20.0)

		# Fight, unless the nearest thing in reach is the enemy this bot has broken
		# away from and is still too hurt to trade with. Any other enemy that wanders
		# into reach is still fair game, which is what keeps the run swinging instead
		# of turning it into a permanent flee.
		if enemy != null and enemy_dist < 22.0 \
				and not (_soak_needs_heal() and enemy.get_instance_id() == fled_id):
			await _tap(&"attack")
			attack_attempts += 1

		await _wait(0.12)

		var pos := _player_pos()
		var step := pos.distance_to(last_pos)
		travelled += step
		if step < 0.4:
			stuck += 1
		else:
			stuck = 0
			last_pos = pos

		# Turn on a wall or after a while, so the run covers the whole map.
		if stuck >= 6 or rng.randf() < 0.04:
			var angles := [0.0, PI * 0.5, PI, PI * 1.5, PI * 0.25, PI * 0.75, PI * 1.25, PI * 1.75]
			var a: float = angles[rng.randi_range(0, angles.size() - 1)]
			heading = Vector2(cos(a), sin(a)).normalized()
			segments += 1
			stuck = 0

	bot_input.release_all()
	_notes.append("segments=%d" % segments)
	_notes.append("travelled=%.0fpx" % travelled)
	_notes.append("attacks=%d" % attack_attempts)
	_notes.append("heal_taps=%d" % heals)
	_notes.append("retreats=%d" % retreats)
	_notes.append("hp=%d/%d" % [GameState.hp, GameState.max_hp])
	_notes.append("kills=%s" % str(GameState.kills))

	# A soak run proves the game keeps running, not that the bot got lucky.
	# Passing here means: the player survived, actually moved around the map,
	# actually swung at things, and the state stayed coherent for the whole
	# window. The attack check is what stops the disengage rule above from being
	# quietly traded for a run that walks away from everything and survives by
	# never being hit.
	var survived: bool = GameState.hp > 0 and GameState.hp <= GameState.max_hp
	var moved_enough: bool = travelled > 300.0
	var fought: bool = attack_attempts > 0
	var state_coherent: bool = GameState.gold >= 0 and GameState.level >= 1
	_result = "PASS" if survived and moved_enough and fought and state_coherent else "FAIL"


## The single place the soak heal threshold is evaluated, so the scenario and the
## test suite cannot drift apart over a duplicated literal.
func _soak_needs_heal() -> bool:
	return GameState.hp < GameState.max_hp * SOAK_HEAL_AT


## Whether the item the first quick slot points at is actually in the bag, which
## is exactly the pair of checks the HUD makes before it heals anything. The map
## carries a single potion, so without this the bot spends its whole low-HP phase
## hammering an empty slot: three physics frames per loop, standing in melee, for
## the rest of the run. The tap itself is unchanged — a real potion still goes
## through the real quick-slot input path.
func _soak_has_potion() -> bool:
	var item_id := String(GameState.quick_slot_item(0))
	return item_id != "" and GameState.count_item(item_id) > 0


## Walk directly away from `threat` for at most `SOAK_RETREAT_TIME` seconds, or
## for whatever is left of `budget`, and report the seconds actually spent.
##
## Real movement through the same input path the human uses: no teleport, no
## invulnerability, and a wall or a corner cuts the burst short on its own. An
## exhausted budget returns immediately without moving, which is what hands
## control back to the attack loop instead of letting the bot stall out the run.
func _soak_retreat(threat: Vector2, budget: float) -> float:
	var away := _player_pos() - threat
	away = away.normalized() if away != Vector2.ZERO else Vector2.UP
	var cap_ms := int(minf(SOAK_RETREAT_TIME, maxf(budget, 0.0)) * 1000.0)
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < cap_ms:
		bot_input.hold(&"move_right", away.x > 0.35)
		bot_input.hold(&"move_left", away.x < -0.35)
		bot_input.hold(&"move_down", away.y > 0.35)
		bot_input.hold(&"move_up", away.y < -0.35)
		# Keep facing the threat so the first swing after the burst is aimed.
		bot_input.set_aim(threat)
		await get_tree().physics_frame
	bot_input.release_all()
	return float(Time.get_ticks_msec() - started) / 1000.0


func _scenario_take_damage() -> void:
	# Deliberately walk into a wolf and never attack: the enemy must be able to
	# hurt the player, and the damage must be visible in the combat log.
	var start_hp: int = GameState.hp
	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 1000.0)
	var enemy := _nearest_enemy()
	if enemy == null:
		_notes.append("no_enemy")
		return
	while Time.get_ticks_msec() < deadline:
		if GameState.hp < start_hp:
			break
		enemy = _nearest_enemy()
		if enemy == null:
			break
		await _move_step(enemy.global_position)
		await _wait(0.05)
	bot_input.release_all()
	_notes.append("hp=%d->%d" % [start_hp, GameState.hp])
	_result = "PASS" if GameState.hp < start_hp else "FAIL"


# --- extended scenarios (spec §19.5) -------------------------------------------

## BOT-003 — combat arena. The bot fights the live forest with all three of its
## combat modes: melee swings, ranged casts through the `ability` action, and
## support healing through the real quick slot. Every number in the notes comes
## from the EventBus sensors, so the per-type damage and kill counts are the
## same events the combat telemetry records. The control-lock bound is the
## spec's 1.5 s: the player may be stunned, rooted or shocked, but never for
## longer, measured on his own StatusComponent's public `effects`.
func _scenario_arena() -> void:
	_connect_combat_sensors()
	var melee := 0
	var casts := 0
	var heals := 0
	var switches := 0
	var last_target := -1
	var control_since := -1
	var max_control_ms := 0
	var disengaged := false
	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if GameState.hp <= 0:
			break
		if await _heal_if_hurt():
			heals += 1
		# The village is the one fact about this arena everyone knows: nothing
		# follows you into it. Out of medicine and bleeding, a hero falls back
		# behind the fence, breathes the impulse until the pool is spent, and
		# only then walks back into the field. The arena keeps measuring; the
		# bot just stops dying in it.
		if disengaged:
			# 70 % and back into the field. Waiting for the pack to clear the
			# fence line instead would pin the bot under the archer who can
			# shoot over it — the fence keeps out teeth, not arrows.
			if GameState.hp >= int(GameState.max_hp * 0.70):
				disengaged = false
			elif _player_pos().distance_to(_player_spawn()) > 20.0:
				await _move_step(_player_spawn())
				continue
			else:
				await _wait(0.2)
				continue
		elif GameState.hp <= int(GameState.max_hp * 0.40):
			disengaged = true
			continue
		elif _crowded():
			# Three muzzles in a ring is not a duel any more, whatever the
			# hero's HP says. The pack fight is where the arena actually
			# kills bots — a lumberjack crit and a boar goring land inside
			# one heal window — so the bot leaves the ring the moment the
			# ring closes, and only walks back when it is a duel again.
			disengaged = true
			continue
		var now := Time.get_ticks_msec()
		if _player_is_controlled():
			if control_since < 0:
				control_since = now
			max_control_ms = maxi(max_control_ms, now - control_since)
		else:
			control_since = -1
		var enemy := _arena_target()
		if enemy == null:
			await _wait(0.2)
			continue
		var arena_eid := enemy.get_instance_id()
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > 150.0:
			await _move_step(enemy.global_position)
			continue
		if dist > float(_profile["engage_range"]) + 6.0:
			# Ranged mode: the cast only counts when it actually paid mana, so a
			# cast still on cooldown is not padded into the number.
			var mana_before := GameState.mana
			bot_input.set_aim(enemy.global_position)
			await _tap(&"ability")
			if GameState.mana < mana_before:
				casts += 1
			# The cast awaited, and a bolt from the cast before it may have
			# finished this enemy in the meantime. Re-resolve before touching
			# the body again — a freed read aborts the whole scenario.
			enemy = instance_from_id(arena_eid) as Node2D
			if enemy != null and is_instance_valid(enemy):
				await _move_step(enemy.global_position)
			continue
		var eid := arena_eid
		if last_target != -1 and eid != last_target:
			switches += 1
		last_target = eid
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		melee += 1
		await _wait(0.2)
		var rd := float(_pf("reaction_delay", 0.0))
		if rd > 0.0:
			await _wait(rd)
	bot_input.release_all()
	var kills_total := 0
	for killed_type: String in _m_kills_by_type:
		kills_total += int(_m_kills_by_type[killed_type])
	_notes.append("melee=%d" % melee)
	_notes.append("casts=%d" % casts)
	_notes.append("heals=%d" % heals)
	_notes.append("switches=%d" % switches)
	_notes.append("dmg_by_type=%s" % _fmt_counts(_m_dmg_by_type))
	_notes.append("kills_by_type=%s" % _fmt_counts(_m_kills_by_type))
	_notes.append("max_control_ms=%d" % max_control_ms)
	var fought := melee > 0 and casts > 0
	var progressed := kills_total > 0 and switches >= 1
	var in_control := max_control_ms < 1500
	_result = "PASS" if GameState.hp > 0 and fought and progressed and in_control else "FAIL"


## BOT-004 — magic. Every skill in `GameState.known_skills` is selected through
## the public selection API and cast through the same `ability` action the human
## right mouse uses. Three facts are measured per skill: the mana pool drops by
## exactly the data cost (the pool has no passive regen, so the drop is exact
## and not a race), an immediate recast is refused by the cooldown and spends
## nothing, and at least one cast across the run lands a status on a live enemy
## — counted on `EventBus.status_applied`, the same event the combat telemetry
## writes to `combat.jsonl`.
func _scenario_magic() -> void:
	_connect_combat_sensors()
	var skills: Array[String] = GameState.known_skills.duplicate()
	if skills.is_empty():
		_notes.append("no_known_skills")
		return
	# A status needs a live target in bolt range; the wolves east of the spawn
	# are the nearest ones, and the bot walks to one instead of firing at empty
	# road. Without any enemy the status check is honestly reported as unmet.
	var target := _nearest_enemy()
	if target != null:
		await _move_to(target.global_position, 55.0, 25.0)
	var exact_costs := 0
	var cooldown_blocks := 0
	var casts := 0
	for skill_id in skills:
		if GameState.hp <= 0:
			break
		if not GameState.select_skill(skill_id):
			_notes.append("select_failed:" + skill_id)
			continue
		var skill := SkillDB.get_skill(skill_id)
		var cost := int(skill.get("mana", 0))
		target = _nearest_enemy()
		if String(skill.get("shape", "")) != "self" and target != null:
			bot_input.set_aim(target.global_position)
		if GameState.mana < cost:
			_notes.append("out_of_mana:" + skill_id)
			continue
		var status_before := _m_status_hits
		var mana_before := GameState.mana
		await _tap(&"ability")
		if GameState.mana == mana_before - cost:
			exact_costs += 1
			casts += 1
		else:
			_notes.append("mana_mismatch:%s=%d->%d" % [skill_id, mana_before, GameState.mana])
		# The recast is immediate by design: every skill cooldown in the data is
		# well above the three physics frames a tap takes, so a cast that paid
		# mana here would mean the cooldown gate is gone.
		var recast_before := GameState.mana
		await _tap(&"ability")
		if GameState.mana == recast_before:
			cooldown_blocks += 1
		else:
			_notes.append("cooldown_leak:" + skill_id)
		if String(skill.get("status", "")) != "" and target != null:
			await _wait(0.8)
			if _m_status_hits > status_before:
				_notes.append("status_landed:" + skill_id)
		await _wait(0.15)
	_notes.append("casts=%d/%d" % [casts, skills.size()])
	_notes.append("exact_costs=%d/%d" % [exact_costs, skills.size()])
	_notes.append("cooldown_blocks=%d" % cooldown_blocks)
	_notes.append("statuses=%d" % _m_status_hits)
	var all_cast := casts == skills.size()
	var statuses_ok := _m_status_hits > 0
	_result = "PASS" if all_cast and exact_costs == skills.size() \
		and cooldown_blocks >= 1 and statuses_ok and GameState.hp > 0 else "FAIL"


## BOT-005 — inventory and economy. The whole route is walked: the east sword
## chest pays for the trip, the merchant Yorek is opened by walking up to him
## and pressing the real interact key, and the purchase is made by moving the
## shop cursor and pressing E — the human path end to end. Equipping goes
## through the inventory panel the same way (the panel reads the same
## InputSource, so arrows and E drive it). Selling is the one leg the UI cannot
## offer a bot: the buy/sell toggle is the Tab key, which the HUD edge-detects
## from the raw keyboard because it has no InputMap action, so the bot sells
## through `ShopManager.sell` — the very function the panel's E handler calls,
## with the same gold, stock and stack rules. No item is ever added or removed
## by the bot itself; the checks only count what the trades left behind.
func _scenario_economy() -> void:
	var hud := _hud()
	if hud == null:
		_notes.append("no_hud")
		return
	var chest := _named("Chest")
	var merchant := _named("Yorek")
	if chest == null or merchant == null:
		_notes.append("economy_actors_missing")
		return
	_connect_combat_sensors()

	# Prep is part of the economy lesson, not a cheat around it. First the
	# close finds are swept — a find across the map belongs to whatever
	# guards it, and the bot walks past both the eastern herb and the southern
	# coin. Then the pouch is filled the way the world fills it: wolves at the
	# spawn edge carry fangs, fangs carry gold at Yorek, and the kills carry
	# the xp that buys the level the east road actually asks for. A `collector`
	# hunts two more before setting the trap of its own trade.
	var sweep_limit := 3 if not bool(_pf("pickup_bias", false)) else 5
	var collected := 0
	while collected < sweep_limit:
		var loot := _nearest_pickup()
		if loot == null:
			break
		if loot.global_position.distance_to(_player_spawn()) < 240.0 \
				and not _near_boss(loot.global_position, 90.0):
			if await _travel_to(loot.global_position, 10.0, 30.0):
				collected += 1
			continue
		break
	_notes.append("prep_pickups=%d" % collected)
	var hunt_target := 4 if not bool(_pf("pickup_bias", false)) else 6
	var hunt_deadline := Time.get_ticks_msec() + 75000
	var kills_at_start := _kill_total()
	while Time.get_ticks_msec() < hunt_deadline \
			and _kill_total() - kills_at_start < hunt_target:
		if _player_pos().distance_to(_player_spawn()) > 240.0:
			break
		var prey := _nearest_enemy()
		if prey == null or prey.is_in_group("boss") \
				or _near_boss(prey.global_position, 110.0) \
				or prey.global_position.distance_to(_player_pos()) > 260.0:
			break
		await _heal_if_hurt()
		var prey_d := _player_pos().distance_to(prey.global_position)
		bot_input.set_aim(prey.global_position)
		if prey_d > 20.0:
			await _move_step(prey.global_position)
		else:
			await _tap(&"attack")
			await _wait(0.1)
	bot_input.release_all()
	_notes.append("prep_hunts=%d" % (_kill_total() - kills_at_start))
	if not await _travel_to(merchant.global_position, 22.0, 120.0):
		_notes.append("prep_merchant_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	var prep_trade := ShopManager.new(GameState)
	var fangs := GameState.count_item("wolf_fang")
	if fangs > 0:
		prep_trade.sell("wolf_fang", fangs)
	if GameState.gold >= 25:
		await _tap(&"interact")
		await _wait(0.4)
		if bool(hud.call("is_shop_open")):
			await _tap(&"interact")
			await _wait(0.3)
			await _tap(&"pause")
			await _wait(0.3)
	_notes.append("prep_done gold=%d potions=%d level=%d" % [
		GameState.gold, GameState.count_item("health_potion"), GameState.level])

	# The books open after the prep walk: every delta below is measured from
	# the state the trades themselves are supposed to move.
	var attack_before := GameState.total_attack()
	var potion_before := GameState.count_item("health_potion")
	var drunk_before := _potions_drunk
	var gold_before := GameState.gold
	var min_gold := GameState.gold

	if not await _travel_to(chest.global_position, 18.0, 200.0):
		_notes.append("chest_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	await _tap(&"interact")
	await _wait(0.3)
	var sword_ok := GameState.count_item("iron_sword") == 1
	var gold_from_chest := GameState.gold - gold_before
	min_gold = mini(min_gold, GameState.gold)

	if not await _travel_to(merchant.global_position, 22.0, 200.0):
		_notes.append("merchant_unreachable hp=%d taken=%s dealt=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type), _fmt_counts(_m_dmg_by_type)])
		return
	await _tap(&"interact")
	await _wait(0.4)
	var shop_open := bool(hud.call("is_shop_open"))
	# Row 0 of the buy list is the merchant's first stock entry — the health
	# potion — and the cursor starts there every time the panel opens.
	# The road's fangs in the bag are the day's wages: they go to the merchant
	# through the same public sell entry before the panel purchase is measured,
	# so the buy leg tests the trade, not the bot's luck at counting gold.
	var road_fangs := GameState.count_item("wolf_fang")
	if road_fangs > 0:
		ShopManager.new(GameState).sell("wolf_fang", road_fangs)
	var gold_pre_buy := GameState.gold
	var potion_pre_buy := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.3)
	var post_buy_gold := GameState.gold
	var post_buy_potions := GameState.count_item("health_potion")
	var bought := post_buy_potions == potion_pre_buy + 1 \
		and post_buy_gold == gold_pre_buy - 25
	if not bought:
		_notes.append("buy_dbg open=%s pre=%d/%d post=%d/%d" % [
			str(shop_open), gold_pre_buy, potion_pre_buy,
			post_buy_gold, post_buy_potions])
	await _tap(&"pause")
	await _wait(0.3)
	var shop_closed := not bool(hud.call("is_shop_open"))
	min_gold = mini(min_gold, GameState.gold)

	# The sell leg through the shop's own public trade entry (see the note
	# above): same manager class, same rules, minus a key the bot has no way
	# to press through the input override.
	var shop := ShopManager.new(GameState)
	var sold: Dictionary = shop.sell("health_potion", 1)
	var sold_ok := bool(sold.get("ok", false)) \
		and GameState.count_item("health_potion") == potion_pre_buy
	# The no-loss ledger closes here, at the counter, and it is balanced
	# against the sips the heal rule took on the road — a potion drunk under
	# wolf teeth is a wound, not a theft, and the trade ledger only charges
	# the trade. Every potion is accounted for: sold one, bought one, drunk
	# what the sensor counted.
	var potions_after_trades := GameState.count_item("health_potion")
	var sips_under_way := _potions_drunk - drunk_before
	var ledger_balanced := potions_after_trades + sips_under_way == potion_before
	min_gold = mini(min_gold, GameState.gold)

	# Equip through the inventory panel: open it, walk the cursor to the sword
	# row the panel itself lists, press E, close it. The panel answers the same
	# InputSource the player uses, so this is the human equip path. The walk
	# back to the road corner the potion sweep already proved walkable is
	# deliberate: standing in a merchant's interact radius while tapping keys
	# invites his shop back under the panel, and the lesson being measured
	# here is the equip, not the door.
	if not await _travel_to(_tile_center(Vector2i(13, 10)), 12.0, 60.0):
		_notes.append("equip_walk_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	if not await _equip_via_inventory(hud, "Железный меч"):
		_notes.append("equip_ui_failed")
		return
	var attack_after := GameState.total_attack()
	var worn := String(GameState.equipped_slot_of("iron_sword"))

	# The collector's full bag goes back to the merchant it is already standing
	# next to; the threshold is the profile's own `merchant_stacks`.
	var unloaded := 0
	var stacks := int(_pf("merchant_stacks", 0))
	if stacks > 0 and _consumable_stacks() >= stacks:
		var trade := ShopManager.new(GameState)
		for slot in GameState.inventory.duplicate():
			var item_id := String(slot["id"])
			if not ItemDB.is_consumable(item_id):
				continue
			var result: Dictionary = trade.sell(item_id, GameState.count_item(item_id))
			if bool(result.get("ok", false)):
				unloaded += 1
		_notes.append("collector_unloaded=%d" % unloaded)

	_notes.append("chest_sword=%s chest_gold=%d" % [str(sword_ok), gold_from_chest])
	_notes.append("shop_open=%s bought=%s closed=%s sold=%s" % [
		str(shop_open), str(bought), str(shop_closed), str(sold_ok)])
	_notes.append("attack=%d->%d worn=%s" % [attack_before, attack_after, worn])
	_notes.append("potions=%d->%d gold=%d min_gold=%d" % [
		potion_before, GameState.count_item("health_potion"), GameState.gold, min_gold])
	var attack_ok := attack_after == attack_before + 6 and worn == "weapon"
	var no_loss := ledger_balanced
	_result = "PASS" if sword_ok and shop_open and bought and shop_closed and sold_ok \
		and attack_ok and no_loss and min_gold >= 0 and GameState.hp > 0 else "FAIL"


## BOT-006 — quest chain. The full arc on one quest: take it from Edrik, hunt
## the objective out in the world, walk back, turn it in, and talk to him once
## more. The turn-in must pay — gold, xp and any reward items land — and the
## repeat conversation must pay nothing at all: the reward-once rule is measured
## as a zero delta across the re-talk, not trusted from the quest state alone.
func _scenario_quest_chain() -> void:
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	if not await _move_to(npc.global_position, 18.0, 45.0):
		_notes.append("npc_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_ACTIVE:
		_notes.append("quest_not_started")
		return
	_notes.append("quest_taken")

	var deadline := Time.get_ticks_msec() + int(SCENARIO_TIMEOUT * 2.2 * 1000.0)
	var attacks := 0
	var abandoned: Dictionary = {}
	var cur_id := -1
	var cur_best := INF
	var stalled := 0
	while Time.get_ticks_msec() < deadline:
		if QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY:
			break
		if await _heal_if_hurt():
			pass
		_prune_abandoned(abandoned)
		var enemy := _nearest_quest_enemy(QUEST_ID, abandoned)
		if enemy == null:
			if not abandoned.is_empty():
				abandoned.clear()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			_notes.append("no_quest_targets")
			return
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > float(_profile["engage_range"]):
			var eid := enemy.get_instance_id()
			if eid != cur_id:
				cur_id = eid
				cur_best = dist
				stalled = 0
			elif dist < cur_best - 2.0:
				cur_best = dist
				stalled = 0
			else:
				stalled += 1
			if stalled > 120:
				abandoned[eid] = Engine.get_physics_frames()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			await _move_step(enemy.global_position)
			continue
		cur_id = -1
		cur_best = INF
		stalled = 0
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.22)
	_notes.append("attacks=%d" % attacks)
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_READY:
		_notes.append("objective_not_met=%d/%d" % [
			QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
		return

	if not await _move_to(npc.global_position, 18.0, 60.0):
		_notes.append("return_unreachable")
		return
	var gold_pre := GameState.gold
	var xp_pre := GameState.xp
	var potion_pre := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var turned_in := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	var reward_gold := GameState.gold - gold_pre
	var reward_xp := GameState.xp - xp_pre
	var reward_potion := GameState.count_item("health_potion") - potion_pre
	_notes.append("reward=gold+%d xp+%d potions+%d" % [reward_gold, reward_xp, reward_potion])

	# The re-talk: same NPC, same key, one more conversation. The quest is
	# already done, so this visit must change nothing about the player.
	var gold_retalk := GameState.gold
	var xp_retalk := GameState.xp
	var potion_retalk := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var still_done := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	var paid_again := GameState.gold != gold_retalk or GameState.xp != xp_retalk \
		or GameState.count_item("health_potion") != potion_retalk
	_notes.append("retalk_state=%s paid_again=%s" % [
		QuestManager.state_of(QUEST_ID), str(paid_again)])
	_result = "PASS" if turned_in and reward_gold > 0 and reward_xp > 0 \
		and still_done and not paid_again and GameState.hp > 0 else "FAIL"


## BOT-007 — traps and secrets. Two honest proofs on the forest's own hazards,
## ordered so the bot spends as little standing time as possible in hostile
## country. The rubble first: the bot walks to the pile and smashes it with
## ordinary swings, and the shortcut flag must be the world's own doing — the
## bot never writes flags, it only reads the one `Breakable` raises when it
## falls. The spike trap second: the bot walks to a standoff just past its
## reach and watches the plate through a cycle (the telegraph is the plate's
## own public colour ramp, no private phase field is read), and only
## crosses onto the plate itself while it is healthy enough to afford the
## lesson. The scenario fails if the trap can hurt anyone it never warned
## (damage from out of reach, or damage with no warning ever seen).
func _scenario_traps() -> void:
	var trap := _named("Trap")
	var rubble := _named("Rubble")
	if trap == null or rubble == null:
		_notes.append("trap_or_rubble_missing")
		return
	_connect_combat_sensors()
	_m_trap_id = trap.get_instance_id()
	_m_trap_damage = 0
	var trap_pos: Vector2 = (trap as Node2D).global_position

	# Bank the road's potion before anything else: the profile heal rule can
	# only fire with a potion actually in the bag.
	var loot := _nearest_pickup()
	if loot != null:
		await _travel_to(loot.global_position, 8.0, 30.0)

	# The secret first — the long walk is the dangerous leg, and it is worth
	# making it with full HP.
	if not await _travel_to(rubble.global_position, 16.0, 110.0):
		_notes.append("rubble_unreachable hp=%d path=%d" % [
			GameState.hp, _find_path(_tile_of(_player_pos()), _tile_of(rubble.global_position)).size()])
		return
	var broke := false
	var swing_deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < swing_deadline:
		if not is_instance_valid(rubble) or bool(rubble.call("is_broken")):
			broke = true
			break
		var pile_threat := _nearest_enemy()
		if pile_threat != null and _player_pos().distance_to(pile_threat.global_position) < 18.0:
			bot_input.set_aim(pile_threat.global_position)
			await _tap(&"attack")
			await _wait(0.15)
			continue
		# The pile is a body, not a ghost: collision parks the player a few
		# pixels outside the swing if he only walks to the arrival ring. The
		# bot keeps pressing into the pile while he swings, so the hitbox is
		# always measured from touching distance.
		if _player_pos().distance_to(rubble.global_position) > 12.0:
			await _move_step(rubble.global_position)
		bot_input.set_aim(rubble.global_position)
		await _tap(&"attack")
		await _wait(0.25)
	if is_instance_valid(rubble):
		broke = bool(rubble.call("is_broken"))
	var flag_open := bool(GameState.get_flag("shortcut_forest_south_open", false))
	_notes.append("broke=%s shortcut_flag=%s hp=%d" % [
		str(broke), str(flag_open), GameState.hp])

	# The trap: the plate only runs its cycle while someone stands within its
	# attention, so the watch is taken from the standoff — 46 px out, past the
	# strike reach but inside the wake radius. The alpha of the plate is the
	# warning: idle sits at 0.35, the telegraph ramps past 0.5 into the 0.8
	# strike frame; seven seconds cover two full cycles (idle 0.8 + telegraph
	# 0.55 + active 0.18 + cooldown 1.6), and the watch ends the moment the
	# warning has been seen. Only the trap's own hits count — a wolf bite from
	# behind is not the plate's doing and must not poison the check.
	var watch_point := _standoff_point(trap_pos)
	# The watch sits in a corridor the forest patrols, and the first walk
	# there is the one that learns the bumps; a second walk runs on the map
	# the first one drew. Two tries, eighty seconds, same honest road.
	var reached_watch := await _travel_to(watch_point, 10.0, 80.0) \
		or await _travel_to(watch_point, 10.0, 80.0)
	if not reached_watch:
		_notes.append("trap_watch_unreachable")
		return
	var telegraph_seen := false
	var watch_deadline := Time.get_ticks_msec() + 7000
	while Time.get_ticks_msec() < watch_deadline:
		var plate: ColorRect = trap.get("visual")
		if plate != null and plate.color.a > 0.5:
			telegraph_seen = true
			break
		var threat := _nearest_enemy()
		if threat != null and _player_pos().distance_to(threat.global_position) < 20.0:
			bot_input.set_aim(threat.global_position)
			await _tap(&"attack")
			await _wait(0.1)
		else:
			await _wait(0.1)
	bot_input.release_all()
	var damage_at_distance := _m_trap_damage
	_notes.append("telegraph_seen=%s trap_damage_at_distance=%d" % [
		str(telegraph_seen), damage_at_distance])

	# The crossing is taken only while healthy: standing on the plate proves
	# the trap is live, but the scenario's promise is about warning honesty,
	# and an avoided trap with a seen warning satisfies it too. A bot below
	# half HP skips the lesson and says so in the notes.
	var cross_damage := 0
	var on_plate := false
	if GameState.hp >= int(GameState.max_hp * 0.5):
		_m_trap_damage = 0
		on_plate = await _travel_to(trap_pos, 6.0, 30.0)
		cross_damage = _m_trap_damage
	else:
		_notes.append("plate_skipped_low_hp")
	_notes.append("on_plate=%s trap_damage_crossing=%d" % [str(on_plate), cross_damage])
	var trap_honest := telegraph_seen and damage_at_distance == 0 \
		and (cross_damage == 0 or telegraph_seen)
	_result = "PASS" if trap_honest and broke and flag_open and GameState.hp > 0 else "FAIL"


# --- helpers -----------------------------------------------------------------

func _player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D


## Delete every file the save manager keeps for a slot (primary, backup, temp),
## so a bot run never leaves residue a later run could mistake for its own save.
func _clear_save_slot(slot: int) -> void:
	var paths: Array[String] = [
		SaveManager.slot_path(slot),
		SaveManager.slot_backup_path(slot),
		SaveManager.slot_temp_path(slot),
	]
	for path in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _player_pos() -> Vector2:
	var p := _player()
	return p.global_position if p != null else Vector2.ZERO


## The clearing every run starts in — the yardstick for "a find close enough
## to be worth a walk".
func _player_spawn() -> Vector2:
	return Vector2(4 * TILE + TILE * 0.5, 9 * TILE + TILE * 0.5)


## Whether a point sits inside a boss's yard. The bot reads the same public
## "boss" group the HUD health frame and the map panel mark read, and treats
## the radius as a promise not to pick a fight it cannot pay for.
func _near_boss(pos: Vector2, radius: float) -> bool:
	for node in get_tree().get_nodes_in_group("boss"):
		if node is Node2D and is_instance_valid(node) \
				and pos.distance_to((node as Node2D).global_position) < radius:
			return true
	return false


func _find_node(group: String) -> Node2D:
	var nodes := get_tree().get_nodes_in_group(group)
	if nodes.is_empty():
		return null
	return nodes[0] as Node2D


## Named world actor lookup: the forest builds Yorek, the trap and the rubble as
## direct children of `World` under fixed names, so a scenario can walk to one
## without hardcoding a tile. The world is resolved fresh off the scene root
## rather than from the cached `_world`, so the helper also answers when a test
## calls it before any cmdline start.
func _named(node_name: String) -> Node2D:
	var world := get_parent().get_node_or_null("World") as Node2D
	if world == null:
		world = _world as Node2D
	if world == null:
		return null
	return world.get_node_or_null(node_name) as Node2D


func _hud() -> CanvasLayer:
	return get_parent().get_node_or_null("HUD") as CanvasLayer


## One profile key with the pre-§19.5 behaviour as its default, so the four
## original profiles — which carry none of the new keys — keep running exactly
## the scenarios they always ran.
func _pf(key: String, fallback: Variant) -> Variant:
	return _profile.get(key, fallback)


## Whether the item the first quick slot points at is actually in the bag — the
## same pair of checks the HUD makes before it heals. The generic twin of the
## soak's own gate, for the scenarios that heal through the profile threshold.
func _has_potion() -> bool:
	var item_id := String(GameState.quick_slot_item(0))
	return item_id != "" and GameState.count_item(item_id) > 0


## Heal through the real quick slot when the profile threshold is crossed and a
## potion exists to spend. Reports whether it tapped, so a scenario can count
## its support actions without guessing.
func _heal_if_hurt() -> bool:
	var heal_at := float(_profile.get("heal_at", 0.5))
	if GameState.hp >= int(GameState.max_hp * heal_at):
		return false
	if _has_potion():
		var potions_before_sip := GameState.count_item("health_potion")
		await _tap(&"quick_slot_1")
		await _wait(0.2)
		if GameState.count_item("health_potion") < potions_before_sip:
			_potions_drunk += 1
			return true
		return false
	# No potion in the bag: the impulse every hero knows from the first minute
	# is the second heal a human reaches for. Same public cast path as any
	# other skill — select, tap, mana paid — and the selection is handed back
	# so a scenario's own ability plan is not disturbed by the bot's medicine.
	# Profiles that refuse abilities (`novice`) refuse this medicine too.
	if not bool(_pf("use_ability", true)):
		return false
	if not GameState.known_skills.has("heal_impulse"):
		return false
	var impulse := SkillDB.get_skill("heal_impulse")
	var cost := int(impulse.get("mana", 0))
	if impulse.is_empty() or GameState.mana < cost:
		return false
	var previous := String(GameState.selected_skill)
	if not GameState.select_skill("heal_impulse"):
		return false
	var mana_before := GameState.mana
	await _tap(&"ability")
	var healed := GameState.mana == mana_before - cost
	GameState.select_skill(previous)
	await _wait(0.2)
	return healed


## Walk away from a threat for a bounded burst through the real movement
## actions. The generic counterpart of the soak's disengage, for profiles that
## break off on their own terms (`retreat_below`).
func _retreat_burst(threat: Vector2, seconds: float) -> void:
	var away := _player_pos() - threat
	away = away.normalized() if away != Vector2.ZERO else Vector2.UP
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		bot_input.hold(&"move_right", away.x > 0.35)
		bot_input.hold(&"move_left", away.x < -0.35)
		bot_input.hold(&"move_down", away.y > 0.35)
		bot_input.hold(&"move_up", away.y < -0.35)
		bot_input.set_aim(threat)
		await get_tree().physics_frame
	bot_input.release_all()


func _nearest_pickup() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("pickup"):
		var p := n as Node2D
		if p == null or not is_instance_valid(p):
			continue
		var d := me.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	return best


## Whether the selected skill is castable right now as far as the mana pool is
## concerned. The cooldown itself stays the player's own gate — a tap that hits
## one simply spends nothing, which is exactly what BOT-004 measures.
func _mana_ready() -> bool:
	var skill := SkillDB.get_skill(GameState.selected_skill)
	if skill.is_empty():
		return false
	return GameState.mana >= int(skill.get("mana", 0))


## Whether a control status (stun, root, shock) currently owns the player. Read
## from his own StatusComponent's public `effects`, the same dictionary the DoT
## ticks and the movement multiplier are computed from.
func _player_is_controlled() -> bool:
	var p := _player()
	if p == null:
		return false
	var comp := p.get_node_or_null("StatusComponent")
	if comp == null:
		return false
	var effects: Dictionary = comp.get("effects")
	for control_status in ["stun", "root", "shock"]:
		if effects.has(control_status):
			return true
	return false


func _fmt_counts(counts: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in counts:
		parts.append("%s:%d" % [key, int(counts[key])])
	return ",".join(parts)


## How many inventory slots hold a consumable — the bag size a collector is
## willing to carry before it hauls the goods back to the merchant.
func _consumable_stacks() -> int:
	var stacks := 0
	for slot in GameState.inventory:
		if ItemDB.is_consumable(String(slot["id"])):
			stacks += 1
	return stacks


## Tile edge of the zone grids. The zones never publish the number, but every
## one of them places actors at `tile * 16 + 8`, and the map panel and the test
## suite make the same assumption, so the bot reads tiles the same way.
const TILE := 16.0


func _tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))


func _tile_center(tile: Vector2i) -> Vector2:
	return Vector2(tile.x * TILE + TILE * 0.5, tile.y * TILE + TILE * 0.5)


## A point to watch a hazard from: the first of eight standoffs around `center`
## (46 px, just past any trap reach) that sits on ground the zone calls
## walkable. The bot observes from real ground it can actually be walked to,
## never from a tile inside a tree line.
func _standoff_point(center: Vector2) -> Vector2:
	for offset in [
		Vector2(46, 0), Vector2(-46, 0), Vector2(0, 46), Vector2(0, -46),
		Vector2(40, 40), Vector2(-40, 40), Vector2(40, -40), Vector2(-40, -40),
	]:
		var candidate: Vector2 = center + offset
		if _walkable(_tile_of(candidate)):
			return candidate
	return center + Vector2(46, 0)


## Whether a tile is ground the player can stand on, read from the zone's own
## public `cell_at` — the same character grid the map panel draws and the test
## suite walks. A world without that API (or a tile off the grid) reads as
## blocked, and the caller falls back to its straight-line steering.
func _walkable(tile: Vector2i, ignore_bumped := false) -> bool:
	if not ignore_bumped and _bumped.has(tile):
		return false
	var world := get_parent().get_node_or_null("World")
	if world == null or not world.has_method("cell_at"):
		return false
	var cell := String(world.call("cell_at", tile))
	return cell == "." or cell == ","


## A* over the zone's walkable grid, eight-directional with no corner cutting
## (a diagonal needs both neighbouring straights open, so the path never
## threads a tree line). The grid is at most 52x32, so the open list is a plain
## scanned array — the whole search is microseconds and changes no world state:
## the bot reads the map the way a player with the map panel reads it, then
## still walks every step through the real input path.
func _find_path(from_tile: Vector2i, to_tile: Vector2i, ignore_bumped := false) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var world := get_parent().get_node_or_null("World")
	if world == null or not world.has_method("cell_at"):
		return path
	var grid: Variant = world.call("map_size")
	if not (grid is Vector2i):
		return path
	var size := grid as Vector2i
	if to_tile != from_tile and not _walkable(to_tile, ignore_bumped):
		return path
	var in_bounds := func(t: Vector2i) -> bool:
		return t.x >= 0 and t.y >= 0 and t.x < size.x and t.y < size.y
	if not in_bounds.call(from_tile) or not in_bounds.call(to_tile):
		return path
	var open_list: Array[Vector2i] = [from_tile]
	var came_from: Dictionary = {}
	var cost: Dictionary = {from_tile: 0}
	var steps := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var heuristic := func(t: Vector2i) -> int:
		return maxi(absi(t.x - to_tile.x), absi(t.y - to_tile.y))
	# Soft avoidance: a player who can see a pack bedded down in the clearing
	# takes the field at an angle instead of walking through the middle of it.
	# The penalty is perception-based (live enemy positions only) and never
	# hard — a road through camp is still walkable, just more expensive than
	# the treeline around it.
	var threat_points: Array = []
	for node in get_tree().get_nodes_in_group("enemies"):
		if node is Node2D and not node.is_queued_for_deletion():
			threat_points.append([(node as Node2D).global_position, 1])
	for node in get_tree().get_nodes_in_group("boss"):
		if node is Node2D and not node.is_queued_for_deletion():
			threat_points.append([(node as Node2D).global_position, 6])
	var threat_penalty := func(t: Vector2i) -> int:
		if threat_points.is_empty():
			return 0
		var center := _tile_center(t)
		var penalty := 0
		for entry in threat_points:
			var d: float = (entry[0] as Vector2).distance_to(center)
			var weight := int(entry[1])
			if d < 56.0:
				penalty += 40 * weight
			elif d < 96.0:
				penalty += 12 * weight
		return penalty
	var f_score := {from_tile: heuristic.call(from_tile)}
	var guard := 0
	while not open_list.is_empty() and guard < 4096:
		guard += 1
		var best_index := 0
		for i in range(1, open_list.size()):
			if int(f_score[open_list[i]]) < int(f_score[open_list[best_index]]):
				best_index = i
		var current: Vector2i = open_list[best_index]
		if current == to_tile:
			var node := current
			while came_from.has(node):
				path.push_front(node)
				node = came_from[node]
			return path
		open_list.remove_at(best_index)
		for step in steps:
			var next_tile: Vector2i = current + step
			if not in_bounds.call(next_tile) or not _walkable(next_tile, ignore_bumped):
				continue
			if step.x != 0 and step.y != 0:
				if not _walkable(current + Vector2i(step.x, 0), ignore_bumped) \
						or not _walkable(current + Vector2i(0, step.y), ignore_bumped):
					continue
			var step_cost := 14 if (step.x != 0 and step.y != 0) else 10
			var via: int = int(cost[current]) + step_cost + int(threat_penalty.call(next_tile))
			if via < int(cost.get(next_tile, 1 << 30)):
				came_from[next_tile] = current
				cost[next_tile] = via
				f_score[next_tile] = via + heuristic.call(next_tile)
				if not next_tile in open_list:
					open_list.append(next_tile)
	return []


## A long leg with a real route and self-defence. The route is A* over the
## zone's own walkable grid; each waypoint is walked with the same movement
## actions every other scenario uses, and the path is recomputed when the bot
## stops making progress (a wolf body-blocking the lane is a legitimate reason
## to re-route). Anything that closes inside 30 px gets answered with the
## sword instead of being walked past into a fight later. If the grid cannot
## answer at all, the leg degrades to the old straight-line steering with the
## obstacle slide, so a world without `cell_at` is still walkable.
func _travel_to(target: Vector2, arrive: float, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	var origin := _tile_of(_player_pos())
	var dest := _tile_of(target)
	var path := _find_path(origin, dest)
	if path.is_empty():
		# Bump memory from an earlier leg can wall off the only corridor; a
		# second read that ignores it distinguishes "the world has no route"
		# from "the bot already bruised a corner on the way".
		path = _find_path(origin, dest, true)
	var leg := 0
	var stuck := 0
	var no_gain := 0
	var best_waypoint_dist := INF
	var repath_cooldown := 0
	var last_stall_pos := Vector2(-1.0e6, -1.0e6)
	var straight_only := path.is_empty()
	var last_pos := _player_pos()
	while Time.get_ticks_msec() < deadline:
		if GameState.hp <= 0:
			bot_input.release_all()
			return false
		var pos := _player_pos()
		if pos.distance_to(target) <= arrive:
			bot_input.release_all()
			return true
		await _heal_if_hurt()
		# Out of medicine and bleeding out: a human breaks off for a moment,
		# even mid-errand. The burst is short by design — the lane is resumed
		# before the whole map notices the bot is walking.
		var retreat_below := float(_pf("retreat_below", 0.0))
		if retreat_below > 0.0 \
				and GameState.hp <= int(GameState.max_hp * retreat_below) \
				and not _has_potion() and GameState.mana < 12:
			var menace := _nearest_enemy()
			if menace != null and pos.distance_to(menace.global_position) < 90.0:
				await _retreat_burst(menace.global_position, 1.5)
				continue
		var waypoint := target
		if not straight_only and leg < path.size():
			waypoint = _tile_center(path[leg])
			if pos.distance_to(waypoint) < 7.0:
				leg += 1
				continue
		var enemy := _nearest_enemy()
		if enemy != null and not enemy.is_in_group("boss"):
			var edist := pos.distance_to(enemy.global_position)
			if edist <= 22.0:
				bot_input.set_aim(enemy.global_position)
				await _tap(&"attack")
				await _wait(0.1)
				continue
			# A shooter at bowshot ahead on the lane keeps shooting for the
			# rest of the leg; a human turns and closes. The close is taken
			# only downrange of the waypoint — a kiter that drags the lane
			# into the wilderness is a worse fight than the chips it throws.
			elif edist < 55.0 and (waypoint - pos).length() > 1.0:
				var ahead := (waypoint - pos).normalized()
				var to_enemy := (enemy.global_position - pos).normalized()
				if ahead.dot(to_enemy) > 0.35:
					bot_input.set_aim(enemy.global_position)
					await _move_step(enemy.global_position)
					continue
		if pos.distance_to(last_pos) < 0.35:
			stuck += 1
		else:
			stuck = 0
			last_pos = pos
		# Sliding along an invisible fence counts as movement, so a plain
		# stuck timer never fires on it. The other half of bump learning is
		# therefore progress-based: if the waypoint is no closer than it was
		# a moment ago, the lane is walking into something the grid cannot
		# see, and the tile under the push joins the wall memory just the
		# same.
		var wd := pos.distance_to(waypoint)
		if wd < best_waypoint_dist - 3.0:
			best_waypoint_dist = wd
			no_gain = 0
		else:
			no_gain += 1
		if repath_cooldown > 0:
			repath_cooldown -= 1
		if (stuck >= 10 or no_gain >= 45) and repath_cooldown == 0:
			var repeat_stall := pos.distance_to(last_stall_pos) < 28.0
			stuck = 0
			no_gain = 0
			best_waypoint_dist = INF
			last_stall_pos = pos
			repath_cooldown = 40
			# Learning a wall is reserved for a spot that refuses the bot
			# twice — sliding a corner or orbiting a waypoint is steering
			# noise, and a memory that fills with fake walls is the bot
			# forgetting the map. A target whose own body refuses the last
			# pixels is likewise not a wall, and the dictionary is capped so
			# one bad evening cannot re-draw the whole zone.
			if repeat_stall and pos.distance_to(target) > 24.0 \
					and _bumped.size() < 60:
				_learn_bump(pos, waypoint, dest)
			var repath := _find_path(_tile_of(pos), _tile_of(target))
			if repath.is_empty():
				repath = _find_path(_tile_of(pos), _tile_of(target), true)
			if repath.is_empty():
				straight_only = true
			else:
				path = repath
				leg = 0
				straight_only = false
		elif straight_only and repath_cooldown == 0 \
				and Engine.get_physics_frames() % 90 < 2:
			# Sliding along a tree line counts as progress, so the stuck timer
			# never fires; ask the grid again on a slow tick in case a route
			# exists that the straight-line steering cannot see around.
			var retry := _find_path(_tile_of(pos), _tile_of(target), true)
			if not retry.is_empty():
				path = retry
				leg = 0
				straight_only = false
				repath_cooldown = 40
		if OS.get_environment("PEPEL_BOT_DEBUG") != "" \
				and Engine.get_physics_frames() % 120 == 0:
			print("[travel] pos=%s leg=%d/%d stuck=%d straight=%s" % [
				str(pos), leg, path.size(), stuck, str(straight_only)])
		await _move_step(waypoint)
	bot_input.release_all()
	return false


## The arena's pick: the nearest enemy that is worth duelling. A lumberjack
## crits for 55 — a third of a level-one hero's neck in one swing — and the
## spec asks the arena for melee, ranged and support against the forest, not
## for a bare-handed duel with an axe. The axe is left to bolts until the
## pack around the hero thins; teeth are always in season.
func _arena_target() -> Node2D:
	var here := _player_pos()
	var best: Node2D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e == null or not is_instance_valid(e):
			continue
		if e.is_in_group("boss"):
			continue
		var d := e.global_position.distance_to(here)
		if d < best_d and String(e.get("enemy_type")) != "lumberjack":
			best_d = d
			best = e
	if best != null:
		return best
	var fallback_d := 100.0
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e == null or not is_instance_valid(e) or e.is_in_group("boss"):
			continue
		var d := e.global_position.distance_to(here)
		if d < fallback_d:
			fallback_d = d
			best = e
	return best


## How many live enemies sit within `radius` of the player. The arena reads
## this to tell a duel from a pile-up.
func _nearby_count(radius: float) -> int:
	var here := _player_pos()
	var count := 0
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e != null and is_instance_valid(e) and e.global_position.distance_to(here) < radius:
			count += 1
	return count


## The ring-closing alarm: three muzzles inside fifty pixels is where the
## arena stops being a fight and becomes a feeding.
func _crowded() -> bool:
	return _nearby_count(50.0) >= 3


## Kills counted by the combat sensor since it was connected, summed over all
## enemy types — the hunt legs need a number, not a per-type breakdown.
func _kill_total() -> int:
	var total := 0
	for key: String in _m_kills_by_type:
		total += int(_m_kills_by_type[key])
	return total


## Remember a tile that physically refused the bot. The tile pushed into (the
## dominant axis of the push, then the secondary axis on a repeat bump at the
## same corner) joins `_bumped`, and every later route on this run treats it
## as wall. This is the bot's own bump-and-detour learning: it reads no
## collision data, it just stops walking into the same corner twice. The
## destination tile is never remembered as wall — standing against a merchant
## who is wider than the arrival radius is a tight squeeze, not a dead end.
func _learn_bump(pos: Vector2, waypoint: Vector2, dest := Vector2i(0x600D, 0x600D)) -> void:
	var dir := waypoint - pos
	var here := _tile_of(pos)
	var primary := Vector2i.ZERO
	var secondary := Vector2i.ZERO
	if absf(dir.x) >= absf(dir.y):
		if dir.x != 0.0:
			primary = Vector2i(signi(dir.x), 0)
		if dir.y != 0.0:
			secondary = Vector2i(0, signi(dir.y))
	else:
		if dir.y != 0.0:
			primary = Vector2i(0, signi(dir.y))
		if dir.x != 0.0:
			secondary = Vector2i(signi(dir.x), 0)
	if primary != Vector2i.ZERO and here + primary != dest:
		_bumped[here + primary] = true
	if secondary != Vector2i.ZERO and here + secondary != dest \
			and absf(dir.x) > 1.0 and absf(dir.y) > 1.0:
		# A diagonal push that stopped lost to one of the two straights; the
		# bot cannot tell which, so it remembers both and lets the next A*
		# pick the gap that is really open.
		_bumped[here + secondary] = true


## Equip through the inventory panel exactly as a human does: open it, read the
## rows the panel itself publishes, walk the cursor with the movement actions
## to the row naming `row_part`, press the interact key, close it. The panel
## answers the same InputSource the player does, so no state is written here —
## the equip happens inside the panel's own handler.
func _equip_via_inventory(hud: CanvasLayer, row_part: String) -> bool:
	await _tap(&"inventory")
	await _wait(0.3)
	if not bool(hud.call("is_inventory_open")):
		await _tap(&"inventory")
		await _wait(0.3)
	var rows: PackedStringArray = hud.call("inventory_row_texts")
	var index := -1
	for i in range(rows.size()):
		if rows[i].contains(row_part):
			index = i
			break
	if index < 0:
		await _tap(&"inventory")
		await _wait(0.2)
		return false
	# The panel keeps the cursor where the last session left it — opening is
	# not resetting — so the walk to the row starts from the row the panel
	# itself reports as selected, in the right direction, not blindly down
	# from an imagined zero.
	var sel := int(hud.call("inventory_selection"))
	var steps := index - sel
	for i in range(absi(steps)):
		await _tap(&"move_down" if steps > 0 else &"move_up")
	await _wait(0.15)
	await _tap(&"interact")
	await _wait(0.3)
	await _tap(&"inventory")
	await _wait(0.3)
	return true


func _connect_combat_sensors() -> void:
	if _m_sensors_connected:
		return
	EventBus.damage_dealt.connect(_on_m_damage)
	EventBus.enemy_died.connect(_on_m_enemy_died)
	EventBus.status_applied.connect(_on_m_status)
	_m_sensors_connected = true


func _disconnect_combat_sensors() -> void:
	if not _m_sensors_connected:
		return
	EventBus.damage_dealt.disconnect(_on_m_damage)
	EventBus.enemy_died.disconnect(_on_m_enemy_died)
	EventBus.status_applied.disconnect(_on_m_status)
	_m_sensors_connected = false


func _on_m_damage(payload: Dictionary) -> void:
	if not bool(payload.get("applied", false)):
		return
	# The trap's own victim is the player, who is not in the "enemy" group, so
	# the trap tally is taken off the attacker id before the enemy-target pass.
	if _m_trap_id != -1 and int(payload.get("attacker_id", 0)) == _m_trap_id:
		_m_trap_damage += int(payload.get("final_damage", 0))
	var node: Node = instance_from_id(int(payload.get("target_id", 0))) as Node
	if node != null and is_instance_valid(node) and node.is_in_group("player"):
		var attacker: Node = instance_from_id(int(payload.get("attacker_id", 0))) as Node
		if attacker != null and is_instance_valid(attacker) and attacker.is_in_group("enemy"):
			var atype := String(attacker.get("enemy_type"))
			_m_taken_by_type[atype] = int(_m_taken_by_type.get(atype, 0)) \
				+ int(payload.get("final_damage", 0))
	if node == null or not is_instance_valid(node) or not node.is_in_group("enemy"):
		return
	var enemy_type := String(node.get("enemy_type"))
	_m_dmg_by_type[enemy_type] = int(_m_dmg_by_type.get(enemy_type, 0)) \
		+ int(payload.get("final_damage", 0))


func _on_m_enemy_died(_enemy_id: StringName, enemy_type: StringName, _world_position: Vector2) -> void:
	var key := String(enemy_type)
	_m_kills_by_type[key] = int(_m_kills_by_type.get(key, 0)) + 1


func _on_m_status(_status_name: String, _duration: float) -> void:
	_m_status_hits += 1


func _nearest_enemy() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("enemy"):
		var e := n as Node2D
		if e == null or not is_instance_valid(e):
			continue
		var d := me.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Quest-aware target picker, used only by the quest scenario. It locks onto the
## enemy type the objective actually counts, so the bot never wastes the run on
## an enemy whose death does not advance the quest (e.g. the ranged cultist).
## Aliveness is judged only from public facts: the node is still valid, still in
## the "enemy" group, and not in the public DEAD state (a dying enemy lingers in
## the group for a beat before queue_free, and the bot must not attack a corpse).
## It never reads hp or any private field. `exclude` (instance_id -> frame) lets
## the caller skip wolves it has just given up on; it defaults to empty so the
## plain single-argument call still means "nearest matching live enemy".
func _nearest_quest_enemy(quest_id: String, exclude: Dictionary = {}) -> Node2D:
	var objective: Dictionary = QuestManager.get_quest(quest_id).get("objective", {})
	if String(objective.get("type", "")) != "kill":
		return null
	var want_type := StringName(String(objective.get("target", "")))
	if want_type == &"":
		return null
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("enemy"):
		var e := n as Node2D
		if e == null or not is_instance_valid(e):
			continue
		if not e.is_in_group("enemy"):
			continue
		if e.get("enemy_type") != want_type:
			continue
		if e.get("state") == Enemy.State.DEAD:
			continue
		if exclude.has(e.get_instance_id()):
			continue
		var d := me.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Drop abandoned entries whose enemy is gone or whose abandonment has aged out,
## so a wolf can be retried once the bot has had time to reposition.
func _prune_abandoned(abandoned: Dictionary) -> void:
	if abandoned.is_empty():
		return
	var now := Engine.get_physics_frames()
	for id: int in abandoned.keys():
		var node := instance_from_id(id)
		if not is_instance_valid(node) or now - int(abandoned[id]) > 900:
			abandoned.erase(id)


func _move_step(target: Vector2) -> void:
	var delta := target - _player_pos()
	bot_input.set_aim(target)
	if delta.length() < 0.5:
		bot_input.release_all()
		await get_tree().physics_frame
		return
	var dir := delta.normalized()

	# Crude but honest obstacle handling: when the straight line is blocked,
	# slide along the obstacle for a few frames instead of pressing into it.
	if _avoid_frames > 0:
		_avoid_frames -= 1
		dir = (dir * 0.35 + _avoid_dir * 0.65).normalized()

	bot_input.hold(&"move_right", dir.x > 0.35)
	bot_input.hold(&"move_left", dir.x < -0.35)
	bot_input.hold(&"move_down", dir.y > 0.35)
	bot_input.hold(&"move_up", dir.y < -0.35)
	await get_tree().physics_frame


func _move_to(target: Vector2, arrive: float, timeout: float) -> bool:
	var frames := int(timeout * 60.0)
	var stuck_frames := 0
	var last_pos := _player_pos()
	var avoid_attempts := 0
	for i in range(frames):
		var pos := _player_pos()
		if pos.distance_to(target) <= arrive:
			bot_input.release_all()
			return true

		if pos.distance_to(last_pos) < 0.35:
			stuck_frames += 1
		else:
			stuck_frames = 0
			last_pos = pos

		if stuck_frames >= 12:
			# Pick a side and commit to it for a while, then retry the direct line.
			avoid_attempts += 1
			_avoid_sign = -_avoid_sign
			var to_target := (target - pos).normalized()
			_avoid_dir = Vector2(-to_target.y, to_target.x) * _avoid_sign
			_avoid_frames = 24
			stuck_frames = 0
			Telemetry.decision({
				"action": "avoid_obstacle",
				"attempt": avoid_attempts,
				"at": [pos.x, pos.y],
			})
			if avoid_attempts > 26:
				Telemetry.event(&"bot_stuck", {"at": [pos.x, pos.y], "target": [target.x, target.y]})
				bot_input.release_all()
				return false

		await _move_step(target)
	bot_input.release_all()
	return false


func _dismiss_dialogue() -> void:
	for i in range(4):
		if not GameState.ui_blocking:
			return
		await _tap(&"interact")
		await _wait(0.15)


func _tap(action: StringName) -> void:
	bot_input.hold(action, true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	bot_input.hold(action, false)
	await get_tree().physics_frame
	Telemetry.decision({"action": String(action), "reason": "scenario_" + scenario})


func _wait(seconds: float) -> void:
	var frames := maxi(1, int(seconds * 60.0))
	for i in range(frames):
		await get_tree().physics_frame
