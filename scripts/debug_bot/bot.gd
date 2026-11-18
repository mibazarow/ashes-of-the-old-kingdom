extends Node
## Debug bot. Drives the real Player through the same InputSource the human
## uses — no teleports, no direct writes to world state.
##
## Run: godot --headless --path . -- --bot=BOT-001
## Scenarios: BOT-001 (talk to NPC, take quest), BOT-008 (kill an enemy),
##            BOT-009 (save + load round-trip).

const QUEST_ID := "q01_ash_wolves"
const SCENARIO_TIMEOUT := 75.0


class BotInput:
	extends RefCounted

	var _pressed: Dictionary = {}
	var _just: Dictionary = {}
	var _aim: Vector2 = Vector2.RIGHT

	func is_action_pressed(action: StringName) -> bool:
		return bool(_pressed.get(String(action), false))

	func is_action_just_pressed(action: StringName) -> bool:
		return int(_just.get(String(action), -1)) == Engine.get_physics_frames()

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
const PROFILES := {
	"cautious": {"heal_at": 0.75, "engage_range": 14.0, "dash_chance": 0.35, "detour": true},
	"normal": {"heal_at": 0.5, "engage_range": 16.0, "dash_chance": 0.15, "detour": true},
	"aggressive": {"heal_at": 0.25, "engage_range": 20.0, "dash_chance": 0.05, "detour": false},
	"explorer": {"heal_at": 0.6, "engage_range": 12.0, "dash_chance": 0.2, "detour": true},
}

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
		if dist > float(_profile["engage_range"]):
			await _move_step(enemy.global_position)
			continue
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.25)
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
	while Time.get_ticks_msec() < deadline:
		bot_input.hold(&"move_right", heading.x > 0.35)
		bot_input.hold(&"move_left", heading.x < -0.35)
		bot_input.hold(&"move_down", heading.y > 0.35)
		bot_input.hold(&"move_up", heading.y < -0.35)
		bot_input.set_aim(_player_pos() + heading * 20.0)

		var enemy := _nearest_enemy()
		if enemy != null and _player_pos().distance_to(enemy.global_position) < 22.0:
			await _tap(&"attack")
			attack_attempts += 1
		if GameState.hp < GameState.max_hp * 0.35:
			await _tap(&"quick_slot_1")

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
	_notes.append("hp=%d/%d" % [GameState.hp, GameState.max_hp])
	_notes.append("kills=%s" % str(GameState.kills))

	# A soak run proves the game keeps running, not that the bot got lucky.
	# Passing here means: the player survived, actually moved around the map,
	# and the state stayed coherent for the whole window.
	var survived: bool = GameState.hp > 0 and GameState.hp <= GameState.max_hp
	var moved_enough: bool = travelled > 300.0
	var state_coherent: bool = GameState.gold >= 0 and GameState.level >= 1
	_result = "PASS" if survived and moved_enough and state_coherent else "FAIL"


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


func _find_node(group: String) -> Node2D:
	var nodes := get_tree().get_nodes_in_group(group)
	if nodes.is_empty():
		return null
	return nodes[0] as Node2D


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
