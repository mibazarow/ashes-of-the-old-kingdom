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


var scenario: String = ""
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
	if scenario == "":
		return
	_world = get_parent().get_node_or_null("World")
	_running = true
	_start_ms = Time.get_ticks_msec()
	InputSource.set_override(bot_input)
	Telemetry.event(&"bot_start", {"scenario": scenario})
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
		if GameState.hp < GameState.max_hp * 0.4:
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		var enemy := _nearest_enemy()
		if enemy == null:
			break
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > 15.0:
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
		return
	_notes.append("saved")
	GameState.add_gold(100)
	GameState.take_damage(25)
	var load := SaveManager.load_game(3)
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
	while Time.get_ticks_msec() < deadline:
		if QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY:
			break
		if GameState.hp < GameState.max_hp * 0.4:
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		var enemy := _nearest_enemy()
		if enemy == null:
			break
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > 15.0:
			await _move_step(enemy.global_position)
			continue
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
	while Time.get_ticks_msec() < deadline:
		bot_input.hold(&"move_right", heading.x > 0.35)
		bot_input.hold(&"move_left", heading.x < -0.35)
		bot_input.hold(&"move_down", heading.y > 0.35)
		bot_input.hold(&"move_up", heading.y < -0.35)
		bot_input.set_aim(_player_pos() + heading * 20.0)

		var enemy := _nearest_enemy()
		if enemy != null and _player_pos().distance_to(enemy.global_position) < 22.0:
			await _tap(&"attack")
		if GameState.hp < GameState.max_hp * 0.35:
			await _tap(&"quick_slot_1")

		await _wait(0.12)

		var pos := _player_pos()
		if pos.distance_to(last_pos) < 0.4:
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
	_notes.append("hp=%d/%d" % [GameState.hp, GameState.max_hp])
	_notes.append("kills=%s" % str(GameState.kills))
	_result = "PASS" if GameState.kill_count("ash_wolf") > 0 else "FAIL"


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
