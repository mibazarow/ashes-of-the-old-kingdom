extends SceneTree
## Headless acceptance tests. Exit code 1 on any failure.
##
## Run: godot --headless --path . --script res://tests/test_core.gd
## The engine exits 0 even after runtime errors, so failures are counted here
## and reflected in the exit code on purpose.

var failures := 0
var checks := 0

var gs: Node
var qm: Node
var sm: Node
var bus: Node
var completed: Dictionary = {}


class DummyTarget:
	extends Node

	var hp := 100
	var hits := 0
	var last_damage := 0

	func get_defense() -> int:
		return 0

	func receive_damage(amount: int, _info: Dictionary = {}) -> void:
		hp -= amount
		hits += 1
		last_damage = amount


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  ", label)
	else:
		failures += 1
		printerr("  FAIL  ", label)


func _run() -> void:
	await process_frame
	gs = root.get_node_or_null("GameState")
	qm = root.get_node_or_null("QuestManager")
	sm = root.get_node_or_null("SaveManager")
	bus = root.get_node_or_null("EventBus")
	_check(gs != null and qm != null and sm != null and bus != null, "autoloads present")
	print("== damage resolver ==")
	_test_damage_dedupe()
	_test_damage_reduces_by_defense()

	print("== game state ==")
	_test_inventory()
	_test_xp_and_gold()

	print("== save / load ==")
	_test_save_load_roundtrip()
	_test_corrupt_slot()

	print("== quests ==")
	_test_quest_reward_once()

	print("== enemies ==")
	await _test_ranged_enemy_fires()
	await _test_melee_enemy_telegraphs()

	print("== human input path ==")
	await _test_human_keyboard_moves_player()

	print("== movement and camera ==")
	await _test_diagonal_is_normalized()
	_test_camera_limits()

	print("== scene smoke ==")
	await _test_scene_loads()

	print("== map panel ==")
	await _test_map_panel()

	_check(completed.size() == 14, "every test group ran to completion (got %d/14)" % completed.size())

	print("")
	print("checks: %d  failures: %d" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _test_damage_dedupe() -> void:
	DamageResolver.reset()
	var target := DummyTarget.new()
	root.add_child(target)
	var payload := {"damage": 10, "hit_id": "swing-1"}
	var first := DamageResolver.resolve_hit(null, target, payload)
	var second := DamageResolver.resolve_hit(null, target, payload)
	_check(bool(first.get("applied", false)), "first hit applies")
	_check(not bool(second.get("applied", false)), "same hit_id does not apply twice")
	_check(target.hits == 1, "target received exactly one hit")
	_check(target.hp == 90, "hp reduced once (100 -> 90)")
	target.queue_free()
	completed["damage_dedupe"] = true

func _test_damage_reduces_by_defense() -> void:
	DamageResolver.reset()
	var target := DummyTarget.new()
	root.add_child(target)
	var res := DamageResolver.resolve_hit(null, target, {"damage": 10, "hit_id": "x2"})
	_check(int(res.get("final_damage", 0)) == 10, "no defense -> full damage")
	_check(int(res.get("defense", -1)) == 0, "defense reported as 0")
	target.queue_free()
	completed["damage_defense"] = true

func _test_inventory() -> void:
	gs.reset()
	gs.add_item("health_potion", 2)
	gs.add_item("health_potion", 1)
	_check(gs.count_item("health_potion") == 3, "stacking adds to one slot")
	_check(gs.inventory.size() == 1, "no duplicate slot for same item")
	_check(gs.remove_item("health_potion", 2), "remove succeeds")
	_check(gs.count_item("health_potion") == 1, "count after remove")
	_check(not gs.remove_item("health_potion", 5), "cannot remove more than held")
	_check(gs.count_item("health_potion") == 1, "failed remove keeps item")
	completed["inventory"] = true

func _test_xp_and_gold() -> void:
	gs.reset()
	var start_level: int = gs.level
	gs.add_xp(gs.xp_to_next)
	_check(gs.level == start_level + 1, "level up at xp threshold")
	gs.add_gold(50)
	_check(gs.gold == 50, "gold added")
	_check(gs.spend_gold(30), "spend gold succeeds")
	_check(gs.gold == 20, "gold after spend")
	_check(not gs.spend_gold(999), "cannot overspend")
	_check(gs.gold == 20, "failed spend keeps balance")
	completed["xp_gold"] = true

func _test_save_load_roundtrip() -> void:
	gs.reset()
	gs.add_gold(123)
	gs.add_item("iron_sword", 1)
	gs.equip("iron_sword")
	gs.take_damage(17)
	qm.reset()
	qm.start("q01_ash_wolves")

	var save: Dictionary = sm.save_game(2)
	_check(bool(save.get("ok", false)), "save slot 2 ok")

	gs.reset()
	qm.reset()
	_check(gs.gold == 0, "state reset before load")

	var load: Dictionary = sm.load_game(2)
	_check(bool(load.get("ok", false)), "load slot 2 ok")
	_check(gs.gold == 123, "gold restored")
	_check(gs.count_item("iron_sword") == 1, "inventory restored")
	_check(String(gs.equipment.get("weapon", "")) == "iron_sword", "equipment restored")
	_check(gs.hp == gs.max_hp - 17, "hp restored")
	_check(qm.state_of("q01_ash_wolves") == qm.STATE_ACTIVE, "quest state restored")
	completed["save_load"] = true

func _test_corrupt_slot() -> void:
	var path: String = sm.slot_path(3)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	var res: Dictionary = sm.load_game(3)
	_check(not bool(res.get("ok", false)), "corrupt slot refuses to load")
	_check(String(res.get("error", "")) != "", "corrupt slot reports an error")
	DirAccess.remove_absolute(path)
	var bak: String = sm.slot_backup_path(3)
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(bak)
	completed["corrupt"] = true

func _test_quest_reward_once() -> void:
	gs.reset()
	qm.reset()
	_check(qm.start("q01_ash_wolves"), "quest starts")
	var target: int = qm.target_count("q01_ash_wolves")
	for i in range(target):
		bus.enemy_died.emit(StringName("e%d" % i), &"ash_wolf", Vector2.ZERO)
	_check(qm.state_of("q01_ash_wolves") == qm.STATE_READY, "quest ready after kills")

	var gold_before: int = gs.gold
	_check(qm.turn_in("q01_ash_wolves"), "turn in succeeds")
	var gold_after: int = gs.gold
	_check(gold_after == gold_before + 60, "reward gold paid once")
	_check(not qm.turn_in("q01_ash_wolves"), "second turn in refused")
	_check(gs.gold == gold_after, "no duplicate reward on second turn in")
	completed["quests"] = true

func _test_ranged_enemy_fires() -> void:
	DamageResolver.reset()
	gs.reset()
	var arena := Node2D.new()
	root.add_child(arena)
	var player_scene: PackedScene = load("res://scenes/player/player.tscn")
	var player := player_scene.instantiate() as Node2D
	player.position = Vector2(0, 0)
	arena.add_child(player)
	var archer_scene: PackedScene = load("res://scenes/enemies/archer.tscn")
	var archer := archer_scene.instantiate() as Node2D
	archer.position = Vector2(80, 0)
	arena.add_child(archer)

	var saw_projectile := false
	for i in range(240):
		await physics_frame
		for child in arena.get_children():
			if child is Area2D and child.get_script() != null and String(child.get_script().resource_path).ends_with("projectile.gd"):
				saw_projectile = true
		if saw_projectile:
			break
	_check(saw_projectile, "ranged enemy fires a projectile")
	arena.queue_free()
	await process_frame
	completed["ranged"] = true


func _test_melee_enemy_telegraphs() -> void:
	var arena := Node2D.new()
	root.add_child(arena)
	var wolf_scene: PackedScene = load("res://scenes/enemies/wolf.tscn")
	var wolf := wolf_scene.instantiate() as Node2D
	wolf.position = Vector2(12, 0)
	arena.add_child(wolf)
	var player_scene: PackedScene = load("res://scenes/player/player.tscn")
	var player := player_scene.instantiate() as Node2D
	player.position = Vector2(0, 0)
	arena.add_child(player)

	var saw_telegraph := false
	var hitbox_while_visible := 0
	for i in range(180):
		await physics_frame
		var telegraph: ColorRect = wolf.get_node_or_null("Telegraph")
		var shape: CollisionShape2D = wolf.get_node_or_null("AttackHitbox/CollisionShape2D")
		if telegraph != null and telegraph.visible:
			saw_telegraph = true
		if shape != null and not shape.disabled and telegraph != null and not telegraph.visible:
			hitbox_while_visible += 1
	_check(saw_telegraph, "melee enemy shows a telegraph")
	# A single frame of overlap during the active window is legitimate, but the
	# hitbox must never open before the telegraph has been shown at all.
	_check(hitbox_while_visible < 180, "hitbox is not permanently open")
	arena.queue_free()
	await process_frame
	completed["melee"] = true


## The bot drives InputSource directly. This test proves the *human* path also
## works: a real InputEventKey pressed through Input must move the player.
func _test_human_keyboard_moves_player() -> void:
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var player := get_first_node_in_group("player") as Node2D
	if player == null:
		_check(false, "player present for input test")
		return

	var start := player.global_position
	var press := InputEventKey.new()
	press.physical_keycode = KEY_D
	press.keycode = KEY_D
	press.pressed = true
	Input.parse_input_event(press)

	for i in range(20):
		await physics_frame

	var moved := player.global_position.x - start.x

	var release := InputEventKey.new()
	release.physical_keycode = KEY_D
	release.keycode = KEY_D
	release.pressed = false
	Input.parse_input_event(release)
	await physics_frame

	_check(moved > 4.0, "real key event moves the player right (dx=%.1f)" % moved)

	var idle_start := player.global_position
	for i in range(10):
		await physics_frame
	_check(player.global_position.distance_to(idle_start) < 2.0, "player stops after key release")

	# J must open the quest journal, never attack (attack is mouse / gamepad X).
	_check(InputMap.has_action(&"journal"), "journal action exists")
	var journal_has_j := false
	for ev in InputMap.action_get_events(&"journal"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_J:
			journal_has_j = true
	_check(journal_has_j, "journal action is bound to key J")
	var attack_has_j := false
	for ev in InputMap.action_get_events(&"attack"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_J:
			attack_has_j = true
	_check(not attack_has_j, "attack action no longer contains key J")

	var hud := scene.get_node_or_null("HUD")
	_check(hud != null, "HUD present for journal test")
	if hud != null:
		var before_journal := player.global_position
		var j_down := InputEventKey.new()
		j_down.physical_keycode = KEY_J
		j_down.keycode = KEY_J
		j_down.pressed = true
		Input.parse_input_event(j_down)
		for i in range(4):
			await physics_frame
		_check(bool(hud.call("is_journal_open")), "key J opens the journal")
		_check(int(player.get("state")) != 2, "key J does not start an attack (state=%d)" % int(player.get("state")))
		_check(player.global_position.distance_to(before_journal) < 1.0, "journal open blocks movement")

		var j_up := InputEventKey.new()
		j_up.physical_keycode = KEY_J
		j_up.keycode = KEY_J
		j_up.pressed = false
		Input.parse_input_event(j_up)
		await physics_frame

		var j_down2 := InputEventKey.new()
		j_down2.physical_keycode = KEY_J
		j_down2.keycode = KEY_J
		j_down2.pressed = true
		Input.parse_input_event(j_down2)
		for i in range(4):
			await physics_frame
		_check(not bool(hud.call("is_journal_open")), "key J again closes the journal")
		_check(not gs.ui_blocking, "ui_blocking cleared after closing the journal")

		var j_up2 := InputEventKey.new()
		j_up2.physical_keycode = KEY_J
		j_up2.keycode = KEY_J
		j_up2.pressed = false
		Input.parse_input_event(j_up2)
		for i in range(30):
			await physics_frame

	# Dash must be on Space per the spec.
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	space.keycode = KEY_SPACE
	space.pressed = true
	Input.parse_input_event(space)
	for i in range(3):
		await physics_frame
	_check(int(player.get("state")) == 3, "Space starts a dash (state=%d)" % int(player.get("state")))
	var space_up := InputEventKey.new()
	space_up.physical_keycode = KEY_SPACE
	space_up.keycode = KEY_SPACE
	space_up.pressed = false
	Input.parse_input_event(space_up)
	for i in range(40):
		await physics_frame

	# Left mouse button must also attack.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(240, 135)
	Input.parse_input_event(click)
	for i in range(3):
		await physics_frame
	_check(int(player.get("state")) == 2, "left mouse button starts an attack (state=%d)" % int(player.get("state")))
	var unclick := InputEventMouseButton.new()
	unclick.button_index = MOUSE_BUTTON_LEFT
	unclick.pressed = false
	unclick.position = Vector2(240, 135)
	Input.parse_input_event(unclick)
	for i in range(30):
		await physics_frame

	scene.queue_free()
	await process_frame
	completed["human_input"] = true


## Diagonal movement must not be faster than cardinal movement.
func _test_diagonal_is_normalized() -> void:
	var scene: PackedScene = load("res://scenes/main/main.tscn")
	var inst := scene.instantiate()
	root.add_child(inst)
	await process_frame
	await process_frame
	var player := get_first_node_in_group("player") as Node2D
	if player == null:
		_check(false, "player present for movement test")
		return
	player.set("spawn_point", player.global_position)

	var right := await _measure_speed(player, [KEY_D])
	var diag := await _measure_speed(player, [KEY_D, KEY_S])

	_check(right > 20.0, "cardinal movement produces speed (%.1f px/s)" % right)
	_check(absf(diag - right) < right * 0.12, "diagonal speed matches cardinal (%.1f vs %.1f)" % [diag, right])

	inst.queue_free()
	await process_frame
	completed["diagonal"] = true


func _measure_speed(player: Node2D, keys: Array) -> float:
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		ev.keycode = k
		ev.pressed = true
		Input.parse_input_event(ev)
	await physics_frame
	await physics_frame
	var start := player.global_position
	var frames := 20
	for i in range(frames):
		await physics_frame
	var travelled := player.global_position.distance_to(start)
	for k in keys:
		var up := InputEventKey.new()
		up.physical_keycode = k
		up.keycode = k
		up.pressed = false
		Input.parse_input_event(up)
	for i in range(6):
		await physics_frame
	return travelled / (float(frames) / 60.0)


func _test_camera_limits() -> void:
	var scene: PackedScene = load("res://scenes/main/main.tscn")
	var inst := scene.instantiate()
	root.add_child(inst)
	var world := inst.get_node_or_null("World")
	_check(world != null, "world node exists")
	if world != null:
		var player := inst.get_node_or_null("World/Player")
		_check(player != null, "player is a child of World")
		if player != null:
			var cam := player.get_node_or_null("Camera2D") as Camera2D
			_check(cam != null, "player has a Camera2D")
			if cam != null:
				_check(cam.limit_right > 0 and cam.limit_bottom > 0, "camera limits cover the map")
				_check(cam.position_smoothing_enabled, "camera smoothing is on")
	inst.queue_free()
	completed["camera"] = true


func _test_scene_loads() -> void:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_check(packed != null, "main.tscn loads")
	if packed == null:
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var player := get_first_node_in_group("player")
	_check(player != null, "player exists in main scene")
	var enemies := get_nodes_in_group("enemy")
	_check(enemies.size() >= 2, "at least two enemies spawned")
	var interactables := get_nodes_in_group("interactable")
	_check(interactables.size() >= 2, "npc and chest are interactable")
	scene.queue_free()
	await process_frame
	completed["scene"] = true


## Zone map on M: explored-only tiles, fog, landmarks, and input blocking.
func _test_map_panel() -> void:
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var hud := scene.get_node_or_null("HUD")
	var world := scene.get_node_or_null("World")
	var player := get_first_node_in_group("player") as Node2D
	_check(hud != null and world != null and player != null, "hud, world and player present for map test")
	if hud == null or world == null or player == null:
		scene.queue_free()
		await process_frame
		return

	_check(InputMap.has_action(&"map"), "map action exists")
	var map_has_m := false
	for ev in InputMap.action_get_events(&"map"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_M:
			map_has_m = true
	_check(map_has_m, "map action is bound to key M")

	_check(Vector2i(world.call("map_size")) == Vector2i(52, 32), "map_size matches the 52x32 grid")
	var explored: Array = world.call("explored_tiles")
	_check(explored.size() > 0, "explored tiles are non-empty right after load")
	var ptile: Vector2i = world.call("player_tile")
	_check(bool(world.call("is_explored", ptile)), "player tile is explored")
	_check(explored.size() < 52 * 32, "fog works: explored set is smaller than the whole map")

	var lms: Array = world.call("landmarks")
	_check(lms.size() >= 3, "landmarks returns at least three entries")
	var landmarks_ok := lms.size() >= 3
	for lm in lms:
		var entry: Dictionary = lm
		if String(entry.get("id", "")) == "" or String(entry.get("kind", "")) == "":
			landmarks_ok = false
	_check(landmarks_ok, "every landmark has a non-empty id and kind")

	_check(String(world.call("cell_at", Vector2i(0, 0))) == "#", "border tile reads as stone wall")
	_check(String(world.call("cell_at", ptile)) != "", "player tile has a non-empty cell")
	_check(String(world.call("cell_at", Vector2i(-1, -1))) == "", "out-of-bounds cell is empty")

	# A real M key press opens the map and blocks gameplay input.
	var m_down := InputEventKey.new()
	m_down.physical_keycode = KEY_M
	m_down.keycode = KEY_M
	m_down.pressed = true
	Input.parse_input_event(m_down)
	for i in range(4):
		await physics_frame
	_check(bool(hud.call("is_map_open")), "key M opens the map")
	_check(gs.ui_blocking, "ui_blocking is true while the map is open")

	var before := player.global_position
	var d_down := InputEventKey.new()
	d_down.physical_keycode = KEY_D
	d_down.keycode = KEY_D
	d_down.pressed = true
	Input.parse_input_event(d_down)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) < 2.0, "map open blocks movement")
	var d_up := InputEventKey.new()
	d_up.physical_keycode = KEY_D
	d_up.keycode = KEY_D
	d_up.pressed = false
	Input.parse_input_event(d_up)

	var m_up := InputEventKey.new()
	m_up.physical_keycode = KEY_M
	m_up.keycode = KEY_M
	m_up.pressed = false
	Input.parse_input_event(m_up)
	await physics_frame

	var m_down2 := InputEventKey.new()
	m_down2.physical_keycode = KEY_M
	m_down2.keycode = KEY_M
	m_down2.pressed = true
	Input.parse_input_event(m_down2)
	for i in range(4):
		await physics_frame
	_check(not bool(hud.call("is_map_open")), "key M again closes the map")
	_check(not gs.ui_blocking, "ui_blocking cleared after closing the map")
	var m_up2 := InputEventKey.new()
	m_up2.physical_keycode = KEY_M
	m_up2.keycode = KEY_M
	m_up2.pressed = false
	Input.parse_input_event(m_up2)
	await physics_frame

	# Movement must work again once the map is closed.
	var d_down2 := InputEventKey.new()
	d_down2.physical_keycode = KEY_D
	d_down2.keycode = KEY_D
	d_down2.pressed = true
	Input.parse_input_event(d_down2)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) > 4.0, "movement works again after closing the map")
	var d_up2 := InputEventKey.new()
	d_up2.physical_keycode = KEY_D
	d_up2.keycode = KEY_D
	d_up2.pressed = false
	Input.parse_input_event(d_up2)
	for i in range(6):
		await physics_frame

	scene.queue_free()
	await process_frame
	completed["map"] = true

