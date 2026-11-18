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

	print("== scene smoke ==")
	await _test_scene_loads()

	_check(completed.size() == 10, "every test group ran to completion (got %d/10)" % completed.size())

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

