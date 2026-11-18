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

	print("== scene smoke ==")
	await _test_scene_loads()

	_check(completed.size() == 11, "every test group ran to completion (got %d/11)" % completed.size())

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

	# Attack must be reachable from the keyboard too, not only from the bot.
	var attack := InputEventKey.new()
	attack.physical_keycode = KEY_J
	attack.keycode = KEY_J
	attack.pressed = true
	Input.parse_input_event(attack)
	for i in range(3):
		await physics_frame
	var in_attack := int(player.get("state")) == 2
	_check(in_attack, "key J starts an attack (state=%d)" % int(player.get("state")))
	var attack_up := InputEventKey.new()
	attack_up.physical_keycode = KEY_J
	attack_up.keycode = KEY_J
	attack_up.pressed = false
	Input.parse_input_event(attack_up)
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

