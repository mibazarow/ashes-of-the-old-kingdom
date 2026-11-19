extends SceneTree
## Headless acceptance tests. Exit code 1 on any failure.
##
## Run: godot --headless --path . --script res://tests/test_core.gd
## The engine exits 0 even after runtime errors, so failures are counted here
## and reflected in the exit code on purpose.

const FIXTURE_DIR := "res://tests/fixtures/saves"

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


## Minimal combatant for status tests: a real HealthComponent child (named
## "HealthComponent", which StatusComponent looks for on the dead check) plus a
## receive_damage that routes into it, so DoT ticks land as real HP loss.
class StatusTarget:
	extends Node

	var health: HealthComponent

	func _ready() -> void:
		health = HealthComponent.new()
		health.name = "HealthComponent"
		health.max_health = 30
		add_child(health)

	func get_defense() -> int:
		return 0

	func receive_damage(amount: int, info: Dictionary = {}) -> void:
		health.take_damage(amount, info)


## Target whose resistance is a fixed knob, to exercise the resistance path.
class ResistTarget:
	extends Node

	var resistance := 0.5

	func get_status_resistance(_status: String) -> float:
		return resistance


## Minimal enemy for the AOE radius test: a Node2D placed in the "enemy" group
## with the two methods DamageResolver needs. No StatusComponent, so the status
## payload is simply not applied (resolve_hit tolerates a missing component).
class AoeTarget:
	extends Node2D

	var hits := 0
	var last_damage := 0

	func get_defense() -> int:
		return 0

	func receive_damage(amount: int, _info: Dictionary = {}) -> void:
		hits += 1
		last_damage = amount


## Stationary hit target for the player's melee swing. It sits on the enemy
## physics layer (3), which is exactly what the player's AttackHitbox masks, and
## it never moves, so the damage assertion measures the swing instead of an AI
## walking out of the hitbox between frames.
class AttackDummy:
	extends StaticBody2D

	var hits := 0
	var last_damage := 0

	func get_defense() -> int:
		return 0

	func receive_damage(amount: int, _info: Dictionary = {}) -> void:
		hits += 1
		last_damage = amount


## Combatant for the combination tests (spec §9.2): a Node2D in the "enemy" group
## with a real HealthComponent and StatusComponent, so every rule resolves
## end-to-end through DamageResolver exactly as it would against a live Enemy.
## The status component does not self-process, so nothing ticks on its own.
class ComboTarget:
	extends Node2D

	var health: HealthComponent
	var statuses: StatusComponent

	func _ready() -> void:
		add_to_group("enemy")
		health = HealthComponent.new()
		health.name = "HealthComponent"
		health.max_health = 100
		add_child(health)
		statuses = StatusComponent.new()
		statuses.name = "StatusComponent"
		add_child(statuses)
		statuses.set_process(false)

	func get_defense() -> int:
		return 0

	func receive_damage(amount: int, info: Dictionary = {}) -> void:
		health.take_damage(amount, info)


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

	# Put the InputMap into a known state before any group injects real key
	# events: a stale controls.json (a real user's rebind, or one left by a
	# crashed run) must not leak into the groups that rely on project defaults.
	_reset_input_to_known_state()

	print("== input isolation ==")
	_test_input_isolation()

	print("== damage resolver ==")
	_test_damage_dedupe()
	_test_damage_reduces_by_defense()

	print("== game state ==")
	_test_inventory()
	_test_xp_and_gold()

	print("== save / load ==")
	_test_save_load_roundtrip()
	_test_corrupt_slot()
	_test_slot_isolation()
	_test_save_fixtures()

	print("== quests ==")
	_test_quest_reward_once()

	print("== enemies ==")
	await _test_ranged_enemy_fires()
	await _test_melee_enemy_telegraphs()

	print("== human input path ==")
	await _test_human_keyboard_moves_player()

	print("== quick slots ==")
	await _test_quick_slots()

	print("== movement and camera ==")
	await _test_diagonal_is_normalized()
	_test_camera_limits()

	print("== scene smoke ==")
	await _test_scene_loads()
	await _test_world_enemy_composition()

	print("== map panel ==")
	await _test_map_panel()

	print("== world chests ==")
	await _test_world_chests()

	print("== ability ==")
	await _test_ability()

	print("== skills ==")
	await _test_skills()

	print("== bot quest target ==")
	await _test_bot_quest_target()

	print("== projectile vs walls ==")
	await _test_projectile_wall_collision()

	print("== statuses ==")
	_test_statuses()

	print("== status lifecycle ==")
	await _test_status_lifecycle()

	print("== combinations ==")
	await _test_combinations()

	print("== stagger recovery ==")
	await _test_stagger_recovery()

	print("== weapon combos ==")
	await _test_weapon_combos()

	print("== hit-stop ==")
	await _test_hit_stop()

	print("== inventory equip ==")
	await _test_inventory_equip()

	print("== input bindings ==")
	_test_input_bindings()

	# Leave no settings residue for the next run, a bot or the editor.
	_reset_input_to_known_state()
	_check(not FileAccess.file_exists(String(InputBindings.PATH)),
		"suite left no controls file behind")

	_check(completed.size() == 32, "every test group ran to completion (got %d/32)" % completed.size())

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

## A corrupt primary with no valid backup must be refused. The whole slot state
## is owned by this test: a backup left behind by an earlier run (a bot, or a
## previous suite) would let load_game recover and mask the corruption, which is
## exactly how this test used to depend on whether bots had run before.
func _test_corrupt_slot() -> void:
	_clear_slot(3)
	var path: String = sm.slot_path(3)
	var f := FileAccess.open(path, FileAccess.WRITE)
	_check(f != null, "corrupt slot fixture opens for writing")
	if f == null:
		_clear_slot(3)
		completed["corrupt"] = true
		return
	f.store_string("{ this is not json")
	f.close()
	# The refusal below has to come from corruption, not from a missing file:
	# an absent primary reports "empty_slot" and would pass for the wrong reason.
	_check(FileAccess.file_exists(path), "corrupt primary is on disk before the load")
	_check(not FileAccess.file_exists(sm.slot_backup_path(3)), "corrupt slot has no backup")
	var res: Dictionary = sm.load_game(3)
	_check(not bool(res.get("ok", false)), "corrupt slot refuses to load")
	_check(String(res.get("error", "")) != "", "corrupt slot reports an error")
	_check(String(res.get("error", "")) == "corrupt_and_no_backup",
		"corrupt slot error names the corrupt-and-no-backup case")
	_clear_slot(3)
	completed["corrupt"] = true


## Isolation regression: pins the property the corrupt-slot test used to violate.
## A valid save followed by a corrupt primary *does* load (the backup recovery
## that used to hide the corruption), while the same corruption with no backup is
## refused — and the corrupt-slot test above leaves slot 3 completely empty.
func _test_slot_isolation() -> void:
	# Runs immediately after _test_corrupt_slot, before this test touches slot 3
	# itself, so any residue found here belongs to the test above.
	var leftover: Array[String] = _slot_residue(3)
	_check(leftover.is_empty(),
		"corrupt slot test left no slot_3 residue (found: %s)" % ", ".join(leftover))

	_clear_slot(3)
	var first: Dictionary = sm.save_game(3)
	_check(bool(first.get("ok", false)), "isolation: save into an empty slot 3 ok")
	_check(not FileAccess.file_exists(sm.slot_backup_path(3)),
		"isolation: first save creates no backup")
	var second: Dictionary = sm.save_game(3)
	_check(bool(second.get("ok", false)), "isolation: rewrite of slot 3 ok")
	_check(FileAccess.file_exists(sm.slot_backup_path(3)),
		"isolation: rewrite keeps the previous copy as a backup")

	# The exact failure mode: corrupt primary + valid backup = a successful load.
	_write_corrupt_primary(3)
	var recovered: Dictionary = sm.load_game(3)
	_check(bool(recovered.get("ok", false)),
		"isolation: corrupt primary with a valid backup recovers from the backup")

	# Same corruption, no backup: refused, and refused *as corruption*.
	_clear_slot(3)
	_write_corrupt_primary(3)
	_check(FileAccess.file_exists(sm.slot_path(3)),
		"isolation: corrupt primary is on disk when the load is refused")
	var refused: Dictionary = sm.load_game(3)
	_check(not bool(refused.get("ok", false)), "isolation: corrupt primary without a backup is refused")
	_check(String(refused.get("error", "")) == "corrupt_and_no_backup",
		"isolation: refusal is corrupt_and_no_backup, not empty_slot")
	_clear_slot(3)
	completed["slot_isolation"] = true


## Remove every file the save manager keeps for a slot, through its own public
## path helpers, so a test always starts from a slot it fully controls.
func _clear_slot(slot: int) -> void:
	var paths: Array[String] = [
		String(sm.slot_path(slot)),
		String(sm.slot_backup_path(slot)),
		String(sm.slot_temp_path(slot)),
	]
	for path in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## Write an unparseable primary save, bypassing the atomic writer on purpose.
func _write_corrupt_primary(slot: int) -> void:
	var f := FileAccess.open(String(sm.slot_path(slot)), FileAccess.WRITE)
	if f == null:
		return
	f.store_string("{ this is not json")
	f.close()


## Names of the files still present for a slot, read from the saves directory
## the save manager itself derives its paths from.
func _slot_residue(slot: int) -> Array[String]:
	var found: Array[String] = []
	var saves_dir := String(sm.slot_path(1)).get_base_dir()
	var dir := DirAccess.open(saves_dir)
	if dir == null:
		return found
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("slot_%d." % slot):
			found.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	found.sort()
	return found


## Read one of the committed save fixtures out of the repo.
func _read_fixture(file_name: String) -> Dictionary:
	var path := "%s/%s" % [FIXTURE_DIR, file_name]
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Read back whatever is currently stored in a slot, bypassing the load path on
## purpose, so a refused load can be shown to have left the file alone.
func _read_slot(slot: int) -> Dictionary:
	var path := String(sm.slot_path(slot))
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Put a payload into a slot as an already existing save, dropping the backup and
## the temp file first so the load reads exactly this payload and nothing else.
func _write_payload_to_slot(payload: Dictionary, slot: int) -> void:
	var stale: Array[String] = [String(sm.slot_backup_path(slot)), String(sm.slot_temp_path(slot))]
	for path in stale:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	var f := FileAccess.open(String(sm.slot_path(slot)), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


## Spec §25: three committed save fixtures are loaded through the real
## SaveManager, which pins both the load path and the v0 -> v1 schema migration.
## Slot 1 belongs to this group alone and is emptied again before it finishes.
func _test_save_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(String(sm.slot_path(1)).get_base_dir())
	_clear_slot(1)

	# A complete v1 save: every asserted value has to come out of the file.
	var full: Dictionary = _read_fixture("fixture_v1_full.json")
	_check(not full.is_empty(), "fixture_v1_full parses as a JSON object")
	_check(int(full.get("schema_version", -1)) == 1, "fixture_v1_full is a schema v1 save")
	gs.reset()
	qm.reset()
	_write_payload_to_slot(full, 1)
	var full_res: Dictionary = sm.load_game(1)
	_check(bool(full_res.get("ok", false)), "fixture_v1_full loads through SaveManager")
	_check(gs.level == 7, "fixture_v1_full: level came from the file")
	_check(gs.gold == 123, "fixture_v1_full: gold came from the file")
	_check(gs.count_item("wolf_fang") == 5, "fixture_v1_full: inventory came from the file")
	_check(String(gs.equipment.get("weapon", "")) == "iron_sword", "fixture_v1_full: equipment came from the file")
	_check(gs.quick_slot_item(2) == "health_potion", "fixture_v1_full: quick slot 3 came from the file")
	_check(qm.state_of("q01_ash_wolves") == qm.STATE_DONE, "fixture_v1_full: quest state came from the file")

	# v0 -> v1 migration: a save written before quest blocks existed must gain an
	# empty one instead of failing or leaving the quest manager half-initialised.
	var no_quests: Dictionary = _read_fixture("fixture_v0_no_quests.json")
	_check(not no_quests.is_empty(), "fixture_v0_no_quests parses as a JSON object")
	_check(not no_quests.has("quests"), "fixture_v0_no_quests really has no quest block")
	gs.reset()
	qm.reset()
	_write_payload_to_slot(no_quests, 1)
	var migrated_res: Dictionary = sm.load_game(1)
	_check(bool(migrated_res.get("ok", false)), "fixture_v0_no_quests loads through SaveManager")
	_check(gs.level == 2, "fixture_v0_no_quests: level came from the file")
	_check(qm.states.is_empty(), "fixture_v0_no_quests: migration produced an empty quest block")

	# A sparse v0 save holds almost nothing: every missing field must fall back to
	# a safe default rather than crash or leave nulls behind.
	var sparse: Dictionary = _read_fixture("fixture_v0_sparse.json")
	_check(not sparse.is_empty(), "fixture_v0_sparse parses as a JSON object")
	gs.reset()
	qm.reset()
	_write_payload_to_slot(sparse, 1)
	var sparse_res: Dictionary = sm.load_game(1)
	_check(bool(sparse_res.get("ok", false)), "fixture_v0_sparse loads through SaveManager")
	_check(gs.level == 3, "fixture_v0_sparse: the field the file does have is honoured")
	_check(gs.gold == 9, "fixture_v0_sparse: gold came from the file")
	_check(gs.hp > 0, "fixture_v0_sparse: missing hp falls back to a live player")
	_check(gs.inventory is Array and gs.inventory.size() == 0,
		"fixture_v0_sparse: missing inventory is an empty array, not null")
	_check(gs.quick_slot_item(0) == "health_potion",
		"fixture_v0_sparse: missing quick_slots fall back to the defaults")
	var sparse_pos: Variant = sparse_res.get("player_position", null)
	_check(sparse_pos is Array and (sparse_pos as Array).is_empty(),
		"fixture_v0_sparse: missing player_position reads as empty")

	# Negative case on the same fixture, no extra file: a save from a newer schema
	# must be refused as it is, never loaded and never rewritten by this game.
	var newer: Dictionary = full.duplicate(true)
	newer["schema_version"] = 99
	_write_payload_to_slot(newer, 1)
	var refused: Dictionary = sm.load_game(1)
	_check(not bool(refused.get("ok", false)), "save from a newer schema is refused")
	_check(String(refused.get("error", "")) == "newer_schema_99",
		"newer schema is refused as newer_schema_99")
	_check(int(_read_slot(1).get("schema_version", 0)) == 99,
		"refused newer-schema load leaves the file untouched")

	_clear_slot(1)
	var leftover: Array[String] = _slot_residue(1)
	_check(leftover.is_empty(),
		"save fixture group left no slot_1 residue (found: %s)" % ", ".join(leftover))
	completed["save_fixtures"] = true


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


## Quick slots 1–4 (spec §6): the assignment is data on GameState, not a
## hard-wired HUD branch, so it can be re-assigned, listed in the inventory
## panel and carried through a save.
func _test_quick_slots() -> void:
	gs.reset()
	qm.reset()

	for index in range(1, 5):
		var action := StringName("quick_slot_%d" % index)
		_check(InputMap.has_action(action), "action %s exists" % action)
		var bound := false
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_1 + index - 1:
				bound = true
		_check(bound, "%s is bound to key %d" % [action, index])

	_check(gs.quick_slot_item(0) == "health_potion", "slot 1 defaults to health_potion")
	_check(gs.quick_slot_item(1) == "mana_potion", "slot 2 defaults to mana_potion")
	_check(gs.quick_slot_item(2) == "", "slot 3 defaults to empty")
	_check(gs.quick_slot_item(3) == "", "slot 4 defaults to empty")
	_check(gs.quick_slot_item(-1) == "" and gs.quick_slot_item(4) == "", "out-of-range slot reads as empty")

	_check(not gs.set_quick_slot(2, "iron_sword"), "equipment is rejected by set_quick_slot")
	_check(not gs.set_quick_slot(4, "health_potion"), "index past the last slot is rejected")
	_check(not gs.set_quick_slot(-1, "health_potion"), "negative index is rejected")
	_check(gs.quick_slot_item(2) == "", "rejected writes left slot 3 empty")
	_check(gs.set_quick_slot(2, "mana_potion"), "consumable is accepted")
	_check(gs.quick_slot_item(2) == "mana_potion", "slot 3 now holds mana_potion")
	_check(gs.set_quick_slot(2, ""), "slot is cleared with an empty id")
	_check(gs.quick_slot_item(2) == "", "slot 3 is empty after clearing")

	gs.set_quick_slot(2, "health_potion")
	var save: Dictionary = sm.save_game(2)
	_check(bool(save.get("ok", false)), "save slot 2 ok for quick slots")
	gs.quick_slots[2] = "mana_potion"
	gs.quick_slots[3] = "mana_potion"
	var load_res: Dictionary = sm.load_game(2)
	_check(bool(load_res.get("ok", false)), "load slot 2 ok for quick slots")
	_check(gs.quick_slot_item(2) == "health_potion", "slot 3 assignment came back from the save")
	_check(gs.quick_slot_item(3) == "", "cleared slot came back empty")

	var legacy: Dictionary = gs.to_dict()
	legacy.erase("quick_slots")
	gs.quick_slots[0] = ""
	gs.from_dict(legacy)
	_check(gs.quick_slot_item(0) == "health_potion", "save without quick_slots falls back to defaults")
	legacy["quick_slots"] = ["a"]
	gs.quick_slots[0] = ""
	gs.from_dict(legacy)
	_check(gs.quick_slot_item(0) == "health_potion" and gs.quick_slot_item(2) == "",
		"malformed quick_slots falls back to defaults")

	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	gs.reset()
	gs.set_quick_slot(2, "health_potion")
	gs.add_item("health_potion", 1)
	gs.hp = 50
	var toasts: Array[String] = []
	var listener := func(message: String) -> void: toasts.append(message)
	bus.toast.connect(listener)

	await _tap_key(KEY_3)
	_check(gs.count_item("health_potion") == 0, "key 3 consumed exactly one potion")
	_check(gs.hp == 90, "key 3 healed exactly 40 hp (hp=%d)" % gs.hp)

	gs.hp = 50
	var items_before: int = gs.inventory.size()
	toasts.clear()
	await _tap_key(KEY_4)
	_check(gs.hp == 50, "key 4 on an empty slot heals nothing (hp=%d)" % gs.hp)
	_check(gs.inventory.size() == items_before and gs.count_item("health_potion") == 0,
		"key 4 on an empty slot consumes nothing")
	_check(toasts.has("Слот 4 пуст"), "key 4 on an empty slot says the slot is empty")

	bus.toast.disconnect(listener)
	scene.queue_free()
	await process_frame

	var slot_file: String = sm.slot_path(2)
	if FileAccess.file_exists(slot_file):
		DirAccess.remove_absolute(slot_file)
	var slot_backup: String = sm.slot_backup_path(2)
	if FileAccess.file_exists(slot_backup):
		DirAccess.remove_absolute(slot_backup)
	gs.reset()
	qm.reset()
	completed["quick_slots"] = true


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


## Regression guard for the ArcherA spawn: the world must contain five melee
## wolves and exactly one real ranged cultist, not six wolves as it did while
## forest.gd instantiated WOLF_SCENE for the node named ArcherA.
func _test_world_enemy_composition() -> void:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var wolves: Array[Node] = []
	var archers: Array[Node] = []
	for node in get_nodes_in_group("enemy"):
		if not node.is_in_group("enemy"):
			continue
		if node.get("enemy_type") == &"ash_wolf":
			wolves.append(node)
		elif node.get("enemy_type") == &"ash_archer":
			archers.append(node)

	_check(wolves.size() >= 5, "world spawns at least 5 melee wolves (got %d)" % wolves.size())
	_check(archers.size() == 1, "world spawns exactly one ranged cultist (got %d)" % archers.size())

	var archer: Node = archers[0] if archers.size() == 1 else null
	_check(archer != null and String(archer.name) == "ArcherA",
		"the ranged cultist is the node named ArcherA")
	var wolf: Node = wolves[0] if not wolves.is_empty() else null
	_check(archer != null and wolf != null and int(archer.get("kind")) != int(wolf.get("kind")),
		"the cultist kind differs from the wolf kind (ranged vs melee)")

	scene.queue_free()
	await process_frame
	completed["world_composition"] = true


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


## The iron spear must be reachable in the world, not just defined in items.json.
## Pins that the forest spawns exactly two chests with distinct ids and loot,
## that the spear chest sits on a walkable tile, that both show on the map, and
## that each chest is independently one-shot through its own GameState flag.
## GameState is reset at both ends and the scene is freed so neither the opened
## flags nor the loot leak into a later group or a bot run.
func _test_world_chests() -> void:
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var world := scene.get_node_or_null("World")
	var chests := _find_chests()
	_check(chests.size() == 2, "world spawns exactly two chests (got %d)" % chests.size())
	if chests.size() != 2 or world == null:
		scene.queue_free()
		await process_frame
		gs.reset()
		completed["world_chests"] = true
		return

	var ids: Array[String] = []
	var items: Array[String] = []
	for chest in chests:
		ids.append(String(chest.get("chest_id")))
		items.append(String(chest.get("item_id")))
	_check(ids.size() == 2 and ids[0] != ids[1], "the two chests have distinct chest_ids (%s)" % ", ".join(ids))
	_check(items.has("iron_sword") and items.has("iron_spear"),
		"the chests carry iron_sword and iron_spear (%s)" % ", ".join(items))

	var spear: Node = null
	var sword: Node = null
	for chest in chests:
		if String(chest.get("item_id")) == "iron_spear":
			spear = chest
		elif String(chest.get("item_id")) == "iron_sword":
			sword = chest
	_check(spear != null and sword != null, "resolved both the spear and the sword chest by item")
	if spear == null or sword == null:
		scene.queue_free()
		await process_frame
		gs.reset()
		completed["world_chests"] = true
		return

	_check(String(spear.get("chest_id")) == "chest_forest_02",
		"the spear chest uses chest_forest_02 (got %s)" % String(spear.get("chest_id")))
	_check(int(spear.get("gold")) == 0, "the spear chest carries no gold (got %d)" % int(spear.get("gold")))
	_check(String(sword.get("chest_id")) == "chest_forest_01",
		"the sword chest keeps chest_forest_01 (got %s)" % String(sword.get("chest_id")))
	_check(int(sword.get("gold")) == 25, "the sword chest still carries 25 gold (got %d)" % int(sword.get("gold")))

	# The spear chest must sit on a walkable tile derived from the generated grid.
	var spear_tile := Vector2i(
		floori(spear.global_position.x / 16.0),
		floori(spear.global_position.y / 16.0)
	)
	var spear_cell := String(world.call("cell_at", spear_tile))
	_check(spear_cell == "." or spear_cell == ",",
		"spear chest sits on a walkable tile %s cell '%s'" % [str(spear_tile), spear_cell])

	# Both chests appear as landmarks so the map can draw them.
	var lms: Array = world.call("landmarks")
	var chest_lm_ids: Array[String] = []
	var spear_lm: Dictionary = {}
	for lm in lms:
		var entry: Dictionary = lm
		if String(entry.get("kind", "")) == "chest":
			chest_lm_ids.append(String(entry.get("id", "")))
			if Vector2i(entry.get("tile", Vector2i(-9999, -9999))) == spear_tile:
				spear_lm = entry
	_check(chest_lm_ids.size() == 2 and chest_lm_ids.has("Chest") and chest_lm_ids.has("ChestSpear"),
		"landmarks list both chests by id (%s)" % ", ".join(chest_lm_ids))
	_check(not spear_lm.is_empty(), "landmarks include an entry on the spear chest tile")
	_check(not spear_lm.is_empty()
			and (String(world.call("cell_at", spear_lm.get("tile", Vector2i(-1, -1)))) == "."
				or String(world.call("cell_at", spear_lm.get("tile", Vector2i(-1, -1)))) == ","),
		"the spear landmark tile is walkable")

	# --- opening the spear chest: one spear, no gold, only its own flag --------
	gs.reset()
	var gold_before: int = gs.gold
	spear.call("interact", null)
	_check(gs.count_item("iron_spear") == 1, "opening the spear chest adds exactly one iron_spear")
	_check(gs.gold == gold_before, "opening the spear chest adds no gold")
	_check(bool(gs.get_flag("chest_opened_chest_forest_02", false)), "spear chest sets its own flag")
	_check(not bool(gs.get_flag("chest_opened_chest_forest_01", false)),
		"opening the spear chest leaves the sword chest flag unset")

	# --- one-shot: a second open adds nothing ----------------------------------
	spear.call("interact", null)
	_check(gs.count_item("iron_spear") == 1, "second open of the spear chest adds nothing")
	_check(gs.gold == gold_before, "second open of the spear chest still adds no gold")

	# --- the sword chest is independent and unaffected -------------------------
	var spear_count_before_sword: int = gs.count_item("iron_spear")
	var gold_before_sword: int = gs.gold
	sword.call("interact", null)
	_check(gs.count_item("iron_sword") == 1, "opening the sword chest adds the sword")
	_check(gs.gold == gold_before_sword + 25, "opening the sword chest adds 25 gold")
	_check(gs.count_item("iron_spear") == spear_count_before_sword,
		"opening the sword chest does not touch the spear")
	_check(bool(gs.get_flag("chest_opened_chest_forest_01", false)), "sword chest sets its own flag")

	# --- after both: both flags set, both items held ---------------------------
	_check(bool(gs.get_flag("chest_opened_chest_forest_01", false))
			and bool(gs.get_flag("chest_opened_chest_forest_02", false)),
		"both chest flags are set after opening both")
	_check(gs.count_item("iron_sword") == 1 and gs.count_item("iron_spear") == 1,
		"both weapons are in the inventory after opening both chests")

	scene.queue_free()
	await process_frame
	gs.reset()
	completed["world_chests"] = true


## The two Chest nodes in the world, found through the interactable group and
## narrowed by the chest-only chest_id property so the NPC and any pickup drop
## out. Returns them in tree order.
func _find_chests() -> Array[Node]:
	var out: Array[Node] = []
	for node in get_nodes_in_group("interactable"):
		var chest_id: Variant = node.get("chest_id")
		if chest_id != null and String(chest_id) != "":
			out.append(node)
	return out


## Right mouse button casts the selected skill (spec §9). This group replaces the
## old dash-ability group with the same human-input rigour (a real
## InputEventMouseButton through Input, not the bot override): a mana-costing
## cast with a per-skill cooldown, instead of a dash. The dash assertions were
## rewritten to cast assertions, not deleted.
func _test_ability() -> void:
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	_check(InputMap.has_action(&"ability"), "ability action exists")
	var ability_has_rmb := false
	for ev in InputMap.action_get_events(&"ability"):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
			ability_has_rmb = true
	_check(ability_has_rmb, "ability action is bound to right mouse button")

	var player := get_first_node_in_group("player") as Node2D
	_check(player != null, "player present for ability test")
	if player == null:
		scene.queue_free()
		await process_frame
		completed["ability"] = true
		return

	# Default selection is fire_bolt (8 mana). A real right-click spends exactly
	# that and does NOT enter DASH — the dash placeholder is gone.
	gs.mana = gs.max_mana
	gs.select_skill("fire_bolt")
	await _settle_idle(player)
	var mana_before: int = gs.mana
	await _tap_rmb()
	_check(gs.mana == mana_before - 8, "right-click casts fire_bolt and spends 8 mana (%d -> %d)" % [mana_before, gs.mana])
	_check(int(player.get("state")) != 3, "right-click casts instead of dashing (state=%d)" % int(player.get("state")))

	# Cooldown: the second press lands while fire_bolt is still cooling down.
	var mana_after_first: int = gs.mana
	await _settle_idle(player)
	await _tap_rmb()
	_check(gs.mana == mana_after_first, "second press during cooldown spends no mana")

	# Out of mana (cooldown forced expired): must not fire, mana stays 0.
	await _settle_idle(player)
	gs.mana = 0
	var cds: Dictionary = player.get("_skill_cooldowns")
	cds["fire_bolt"] = 0.0
	await _tap_rmb()
	_check(gs.mana == 0, "no mana -> cast does not fire, mana stays 0")

	# Cooldown expired with mana restored: the cast works again.
	await _settle_idle(player)
	gs.mana = gs.max_mana
	cds["fire_bolt"] = 0.0
	var mana_before_recover: int = gs.mana
	await _tap_rmb()
	_check(gs.mana == mana_before_recover - 8, "cast works again after cooldown expires")

	await _settle_idle(player)
	scene.queue_free()
	await process_frame
	completed["ability"] = true


## Data-driven skills (spec §9): the SkillDB schema, GameState selection/learn
## persistence, and the four cast shapes through Player.try_ability. Uses a bare
## arena (no walls, no real enemies) so the AOE radius and the projectile payload
## are fully deterministic. GameState is reset at both ends so the learned
## ice_barrier/fire_burst do not leak into later groups.
func _test_skills() -> void:
	DamageResolver.reset()
	gs.reset()

	# --- SkillDB schema --------------------------------------------------------
	_check(SkillDB.all_skills().size() == 8, "SkillDB loads exactly 8 skills")
	var school_list := SkillDB.schools()
	_check(school_list.size() == 4, "SkillDB reports 4 schools")
	_check(school_list.size() == 4 and school_list[0] == "fire" and school_list[1] == "ice" \
			and school_list[2] == "lightning" and school_list[3] == "nature",
		"schools are in the stable order fire, ice, lightning, nature")
	var two_each := true
	for school in school_list:
		if SkillDB.skills_of_school(school).size() != 2:
			two_each = false
	_check(two_each, "every school has exactly 2 skills")
	_check(SkillDB.is_shape("fire_bolt", "projectile"), "fire_bolt is a projectile")
	_check(SkillDB.is_shape("fire_burst", "aoe"), "fire_burst is an aoe")
	_check(SkillDB.is_shape("ice_barrier", "self"), "ice_barrier is self-target")
	_check(not SkillDB.is_shape("fire_bolt", "aoe"), "is_shape is false for a wrong shape")

	var required := ["name", "school", "shape", "mana", "cooldown", "damage", "status",
		"status_duration", "radius", "range", "speed", "description", "heal", "barrier"]
	# Godot's JSON parser yields float for every number, so the numeric fields are
	# checked as "is a number" (int or float) rather than a strict int/float pin;
	# the string fields are pinned to String.
	var numeric := [TYPE_INT, TYPE_FLOAT]
	var fields_ok := true
	var types_ok := true
	for id: String in SkillDB.all_skills().keys():
		var s := SkillDB.get_skill(id)
		for f in required:
			if not s.has(f):
				fields_ok = false
		if not (s.get("name") is String and s.get("school") is String and s.get("shape") is String \
				and s.get("status") is String and s.get("description") is String):
			types_ok = false
		for n in ["mana", "cooldown", "damage", "status_duration", "radius", "range", "speed", "heal", "barrier"]:
			if not (typeof(s.get(n)) in numeric):
				types_ok = false
	_check(fields_ok, "every skill carries all 14 required fields")
	_check(types_ok, "every skill field has the expected type")

	# --- GameState selection / learn / persistence -----------------------------
	_check(gs.selected_skill == "fire_bolt", "default selection is fire_bolt")
	_check(gs.known_skills.has("fire_bolt") and gs.known_skills.has("heal_impulse"),
		"default known loadout has fire_bolt and heal_impulse")
	_check(not gs.known_skills.has("fire_burst"), "fire_burst is not known by default")
	_check(gs.select_skill("fire_bolt"), "select_skill accepts a known skill")
	_check(not gs.select_skill("fire_burst"), "select_skill rejects an unlearned skill")
	_check(not gs.select_skill("not_a_skill"), "select_skill rejects an unknown id")
	_check(gs.selected_skill == "fire_bolt", "rejected selects left the selection unchanged")
	_check(gs.learn_skill("fire_burst"), "learn_skill adds a known skill")
	_check(gs.known_skills.has("fire_burst"), "fire_burst is now known")
	_check(not gs.learn_skill("fire_burst"), "learn_skill is idempotent")
	_check(not gs.learn_skill("not_a_skill"), "learn_skill rejects an unknown id")
	_check(gs.select_skill("fire_burst"), "select_skill accepts the newly learned skill")

	var roundtrip: Dictionary = gs.to_dict()
	roundtrip["known_skills"].append("not_a_skill")
	gs.from_dict(roundtrip)
	_check(gs.selected_skill == "fire_burst", "round-trip keeps the selection")
	_check(gs.known_skills.has("fire_burst"), "round-trip keeps the learned skill")
	_check(not gs.known_skills.has("not_a_skill"), "round-trip drops an unknown id")

	# --- casting rig: a bare arena with one player ------------------------------
	var arena := Node2D.new()
	root.add_child(arena)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(player)
	await process_frame
	gs.reset()
	gs.mana = gs.max_mana
	var cds: Dictionary = player.get("_skill_cooldowns")

	# fire_bolt: mana cost, projectile payload, per-skill cooldown.
	gs.select_skill("fire_bolt")
	cds["fire_bolt"] = 0.0
	var mana_before: int = gs.mana
	_check(player.try_ability(), "fire_bolt cast returns true")
	_check(gs.mana == mana_before - 8, "fire_bolt spends exactly 8 mana (%d -> %d)" % [mana_before, gs.mana])
	var proj: Node = null
	for child in arena.get_children():
		if child is SpellProjectile:
			proj = child
	_check(proj != null, "casting fire_bolt spawns a SpellProjectile")
	_check(proj != null and int(proj.get("damage")) == 12, "spell projectile carries damage 12")
	_check(proj != null and String(proj.get("status")) == "burn", "spell projectile carries status burn")
	var mana_after_first: int = gs.mana
	_check(not player.try_ability(), "recast during cooldown returns false")
	_check(gs.mana == mana_after_first, "recast during cooldown spends no mana")
	if proj != null:
		proj.queue_free()

	# Insufficient mana: nothing happens, mana unchanged.
	cds["fire_bolt"] = 0.0
	gs.mana = 4
	var mana_low_before: int = gs.mana
	_check(not player.try_ability(), "cast without enough mana returns false")
	_check(gs.mana == mana_low_before, "failed cast leaves mana unchanged")

	# heal_impulse: heals 25 and costs 12.
	gs.mana = gs.max_mana
	gs.hp = gs.max_hp - 40
	gs.select_skill("heal_impulse")
	var hp_before: int = gs.hp
	var mana_heal_before: int = gs.mana
	_check(player.try_ability(), "heal_impulse cast returns true")
	_check(gs.hp == hp_before + 25, "heal_impulse heals 25 (hp %d -> %d)" % [hp_before, gs.hp])
	_check(gs.mana == mana_heal_before - 12, "heal_impulse costs 12 mana")

	# ice_barrier: a damage-reduction buff on the player (data barrier = percent).
	gs.mana = gs.max_mana
	gs.learn_skill("ice_barrier")
	gs.select_skill("ice_barrier")
	_check(player.try_ability(), "ice_barrier cast returns true")
	_check(float(player.get("_barrier_left")) > 0.0, "ice_barrier starts the barrier timer")
	_check(absf(float(player.get("_barrier_reduction")) - 8.0) < 0.001, "ice_barrier reduction is 8 percent")
	player.set("_barrier_left", 0.0)
	player.set("_barrier_reduction", 0.0)
	player.set("_iframe_left", 0.0)
	gs.hp = gs.max_hp
	var plain_before: int = gs.hp
	player.receive_damage(20)
	var plain_loss: int = plain_before - gs.hp
	player.set("_barrier_left", 4.0)
	player.set("_barrier_reduction", 8.0)
	player.set("_iframe_left", 0.0)
	gs.hp = gs.max_hp
	var guard_before: int = gs.hp
	player.receive_damage(20)
	var guard_loss: int = guard_before - gs.hp
	_check(plain_loss == 20, "no barrier -> full 20 damage (got %d)" % plain_loss)
	_check(guard_loss < plain_loss, "barrier reduces incoming damage (%d < %d)" % [guard_loss, plain_loss])
	_check(guard_loss == 18, "8 percent barrier shaves 20 to 18 (got %d)" % guard_loss)
	player.set("_barrier_left", 0.0)
	player.set("_barrier_reduction", 0.0)

	# aoe: fire_burst hits an enemy inside the radius and not one outside it.
	gs.mana = gs.max_mana
	gs.learn_skill("fire_burst")
	gs.select_skill("fire_burst")
	var burst := SkillDB.get_skill("fire_burst")
	var aim := InputSource.aim_direction(player.global_position)
	var dir: Vector2 = aim if aim.length() > 0.01 else (player.get("facing") as Vector2)
	var aim_point: Vector2 = player.global_position + dir * float(burst.get("range", 0.0))
	var radius := float(burst.get("radius", 0.0))
	var inside := AoeTarget.new()
	arena.add_child(inside)
	inside.add_to_group("enemy")
	inside.global_position = aim_point
	var outside := AoeTarget.new()
	arena.add_child(outside)
	outside.add_to_group("enemy")
	outside.global_position = aim_point + Vector2(radius + 40.0, 0.0)
	_check(player.try_ability(), "fire_burst cast returns true")
	_check(inside.hits == 1, "aoe damages the enemy inside the radius")
	_check(outside.hits == 0, "aoe does not damage the enemy outside the radius")
	inside.queue_free()
	outside.queue_free()

	# stun blocks casting entirely (no mana spent).
	var psc := player.get_node_or_null("StatusComponent") as StatusComponent
	_check(psc != null, "player has a StatusComponent for the stun test")
	if psc != null:
		gs.mana = gs.max_mana
		gs.select_skill("fire_bolt")
		cds["fire_bolt"] = 0.0
		psc.apply_status("stun", 2.0)
		var mana_stun_before: int = gs.mana
		_check(not player.try_ability(), "casting while stunned does nothing")
		_check(gs.mana == mana_stun_before, "stunned cast spends no mana")
		psc.clear_all()

	arena.queue_free()
	await process_frame
	gs.reset()
	DamageResolver.reset()
	completed["skills"] = true


## Wait until the player leaves DASH/ATTACK and returns to a free state, so the
## next input tap is observed from a known-clean state.
func _settle_idle(player: Node) -> void:
	for i in range(40):
		await physics_frame
		if int(player.get("state")) != 3 and int(player.get("state")) != 2:
			return


## A single key tap through the real Input path, with fresh event objects so a
## held state from an earlier tap cannot mask the edge.
func _tap_key(key: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = key
	down.keycode = key
	down.pressed = true
	Input.parse_input_event(down)
	for i in range(4):
		await physics_frame
	var up := InputEventKey.new()
	up.physical_keycode = key
	up.keycode = key
	up.pressed = false
	Input.parse_input_event(up)
	await physics_frame


## A single right-mouse-button click through the real Input path, using fresh
## event objects so a held state from an earlier tap cannot mask the edge.
func _tap_rmb() -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = Vector2(360, 135)
	Input.parse_input_event(down)
	for i in range(2):
		await physics_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = Vector2(360, 135)
	Input.parse_input_event(up)


## BOT-002 determinism guard, pinned without a full bot run: the quest-aware
## target picker must lock onto the enemy type the objective counts (ash_wolf)
## and never a closer non-objective enemy, and must return null for an unknown
## quest id. The world does spawn one cultist, but far to the east, so we plant
## a second one (archer.tscn, ash_archer) right next to the player — closer than
## any wolf — and assert the picker still skips it and returns an ash_wolf.
func _test_bot_quest_target() -> void:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var bot := scene.get_node_or_null("Bot")
	var player := get_first_node_in_group("player") as Node2D
	var world := scene.get_node_or_null("World")
	_check(bot != null and player != null and world != null, "bot, player and world present for quest-target test")
	if bot == null or player == null or world == null:
		scene.queue_free()
		await process_frame
		completed["bot_quest_target"] = true
		return

	# A type-blind picker would lock onto this cultist (it is the nearest enemy);
	# the quest-aware picker must ignore it because its type is not the objective.
	var cultist: Node2D = (load("res://scenes/enemies/archer.tscn") as PackedScene).instantiate()
	world.add_child(cultist)
	cultist.global_position = player.global_position + Vector2(4, 0)
	await process_frame
	_check(String(cultist.get("enemy_type")) == "ash_archer", "planted enemy is the non-objective cultist")
	var blind := bot.call("_nearest_enemy") as Node2D
	_check(blind == cultist, "a type-blind picker would lock onto the nearer cultist")

	var target := bot.call("_nearest_quest_enemy", "q01_ash_wolves") as Node2D
	_check(target != null, "quest target picker returns an enemy")
	_check(target != null and String(target.get("enemy_type")) == "ash_wolf",
		"quest target picker skips the cultist and returns an ash_wolf")
	_check(target != cultist, "quest target picker does not return the cultist")
	_check(bot.call("_nearest_quest_enemy", "no_such_quest") == null,
		"quest target picker returns null for unknown quest id")

	cultist.queue_free()
	scene.queue_free()
	await process_frame
	completed["bot_quest_target"] = true


## Defect #2 regression: an enemy projectile must stop at walls and trees
## (TileMapLayer collision, physics layer 1) instead of flying through them,
## and a wall hit must not damage the player. The solid tile and the open
## control stretch are located by scanning the deterministic map through the
## public Forest API (map_size / cell_at), never hardcoded.
func _test_projectile_wall_collision() -> void:
	DamageResolver.reset()
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var world := scene.get_node_or_null("World")
	var player := get_first_node_in_group("player") as Node2D
	_check(world != null and player != null, "world and player present for projectile-wall test")
	if world == null or player == null:
		scene.queue_free()
		await process_frame
		completed["projectile_wall"] = true
		return

	var size: Vector2i = world.call("map_size")
	# First solid tile whose two tiles to the left are open, so the projectile
	# starts on clear ground and flies straight right into the solid one.
	var solid := Vector2i(-1, -1)
	for y in range(2, size.y - 2):
		for x in range(4, size.x - 2):
			var cell := String(world.call("cell_at", Vector2i(x, y)))
			var left1 := String(world.call("cell_at", Vector2i(x - 1, y)))
			var left2 := String(world.call("cell_at", Vector2i(x - 2, y)))
			if (cell == "#" or cell == "T") and left1 != "#" and left1 != "T" \
					and left2 != "#" and left2 != "T":
				solid = Vector2i(x, y)
				break
		if solid.x >= 0:
			break
	_check(solid.x >= 0, "found a solid wall/tree tile with an open approach")

	# First stretch of 10 open tiles in a row for the control case.
	var open_run := Vector2i(-1, -1)
	for y in range(2, size.y - 2):
		for x in range(3, size.x - 11):
			var clear := true
			for dx in range(0, 10):
				var c := String(world.call("cell_at", Vector2i(x + dx, y)))
				if c == "#" or c == "T":
					clear = false
					break
			if clear:
				open_run = Vector2i(x, y)
				break
		if open_run.x >= 0:
			break
	_check(open_run.x >= 0, "found an open ground stretch for the control case")
	if solid.x < 0 or open_run.x < 0:
		scene.queue_free()
		await process_frame
		completed["projectile_wall"] = true
		return

	var hp_before: int = gs.hp
	var wall_center := Vector2(solid.x * 16 + 8, solid.y * 16 + 8)
	var proj := (load("res://scenes/items/projectile.tscn") as PackedScene).instantiate()
	proj.setup(Vector2.RIGHT, 6, null)
	proj.global_position = wall_center + Vector2(-32, 0)
	world.add_child(proj)
	var freed_frame := -1
	for i in range(60):
		await physics_frame
		if not is_instance_valid(proj):
			freed_frame = i
			break
	_check(freed_frame >= 0, "projectile is freed when it hits a wall/tree (frame %d)" % freed_frame)
	_check(gs.hp == hp_before, "wall hit does not damage the player")

	# Control: the same projectile over open ground must keep flying.
	var ctrl := (load("res://scenes/items/projectile.tscn") as PackedScene).instantiate()
	ctrl.setup(Vector2.RIGHT, 6, null)
	ctrl.global_position = Vector2(open_run.x * 16 + 8, open_run.y * 16 + 8)
	world.add_child(ctrl)
	var survived := true
	for i in range(30):
		await physics_frame
		if not is_instance_valid(ctrl):
			survived = false
			break
	_check(survived, "control projectile survives 30 frames over open ground")
	_check(gs.hp == hp_before, "control flight does not damage the player")
	if is_instance_valid(ctrl):
		ctrl.queue_free()

	scene.queue_free()
	await process_frame
	completed["projectile_wall"] = true


## Spec §8.2 statuses: durations, stacking, resistance, DoT through
## DamageResolver, dead-target safety, the query multipliers, and the resolver's
## optional status payload. Fully deterministic — StatusComponent.set_process is
## turned off so only explicit tick() calls advance time; no real frames pass
## inside this group.
func _test_statuses() -> void:
	DamageResolver.reset()

	# --- rejection + basics ----------------------------------------------------
	var owner := Node.new()
	root.add_child(owner)
	var sc := StatusComponent.new()
	sc.name = "StatusComponent"
	owner.add_child(sc)
	sc.set_process(false)

	_check(not sc.apply_status("not_a_status", 5.0), "unknown status name is rejected")
	_check(not sc.apply_status("burn", 0.0), "zero duration is rejected")
	_check(not sc.apply_status("burn", -1.0), "negative duration is rejected")
	_check(not sc.has_status("burn"), "rejected applies left no burn")

	_check(sc.apply_status("burn", 2.0), "burn applies")
	_check(sc.has_status("burn"), "has_status true after apply")
	_check(absf(sc.time_left("burn") - 2.0) < 0.001, "time_left ~ duration")
	sc.tick(1.0)
	_check(absf(sc.time_left("burn") - 1.0) < 0.001, "tick decrements time_left")
	_check(sc.has_status("burn"), "burn still active at 1.0 left")
	sc.tick(1.0)
	_check(not sc.has_status("burn"), "burn expires exactly at zero")
	_check(absf(sc.time_left("burn")) < 0.001, "time_left is zero after expiry")

	sc.apply_status("burn", 1.0, null, 1)
	sc.apply_status("burn", 1.0, null, 10)
	_check(sc.stacks("burn") == 5, "burn stacks cap at 5")
	sc.clear_all()
	sc.apply_status("burn", 1.0)
	sc.tick(0.5)
	sc.apply_status("burn", 3.0)
	_check(absf(sc.time_left("burn") - 3.0) < 0.001, "refresh to the longer duration")
	sc.apply_status("burn", 1.0)
	_check(absf(sc.time_left("burn") - 3.0) < 0.001, "shorter reapply keeps the longer time")

	sc.clear_all()
	sc.apply_status("stun", 1.0, null, 3)
	_check(sc.stacks("stun") == 1, "stun does not stack")
	sc.apply_status("stun", 2.0, null, 3)
	_check(sc.stacks("stun") == 1, "stun stacks stay 1 after reapply")
	_check(absf(sc.time_left("stun") - 2.0) < 0.001, "stun refreshes duration")
	owner.queue_free()

	# --- resistance ------------------------------------------------------------
	var rt := ResistTarget.new()
	root.add_child(rt)
	var rsc := StatusComponent.new()
	rsc.name = "StatusComponent"
	rt.add_child(rsc)
	rsc.set_process(false)
	_check(rsc.apply_status("burn", 4.0), "resisted status still applies")
	_check(absf(rsc.time_left("burn") - 2.0) < 0.001, "resistance 0.5 halves the duration")
	rt.queue_free()

	var full := ResistTarget.new()
	full.resistance = 1.0
	root.add_child(full)
	var fsc := StatusComponent.new()
	fsc.name = "StatusComponent"
	full.add_child(fsc)
	fsc.set_process(false)
	_check(not fsc.apply_status("burn", 4.0), "resistance 1.0 rejects the status")
	_check(not fsc.has_status("burn"), "resistance 1.0 leaves no effect")
	full.queue_free()

	# --- DoT through DamageResolver -------------------------------------------
	var t1 := StatusTarget.new()
	root.add_child(t1)
	var sc1 := StatusComponent.new()
	sc1.name = "StatusComponent"
	t1.add_child(sc1)
	sc1.set_process(false)
	sc1.apply_status("burn", 3.0, null, 1)
	_check(t1.health.current_health == 30, "status target starts at full hp")
	sc1.tick(1.0)
	_check(t1.health.current_health == 27, "burn tick deals 3 damage (1 stack)")

	var t2 := StatusTarget.new()
	root.add_child(t2)
	var sc2 := StatusComponent.new()
	sc2.name = "StatusComponent"
	t2.add_child(sc2)
	sc2.set_process(false)
	sc2.apply_status("burn", 3.0, null, 2)
	sc2.tick(1.0)
	_check(t2.health.current_health == 24, "burn tick scales with stacks (2 stacks -> 6)")
	t1.queue_free()
	t2.queue_free()

	var dead := StatusTarget.new()
	root.add_child(dead)
	var dsc := StatusComponent.new()
	dsc.name = "StatusComponent"
	dead.add_child(dsc)
	dsc.set_process(false)
	dead.health.take_damage(999)
	_check(dead.health.is_dead and dead.health.current_health == 0, "fixture target is dead")
	dsc.apply_status("burn", 3.0, null, 1)
	dsc.tick(1.0)
	_check(dead.health.current_health == 0, "DoT does not damage a dead target")
	dead.queue_free()

	# --- query helpers ---------------------------------------------------------
	var q := Node.new()
	root.add_child(q)
	var qsc := StatusComponent.new()
	qsc.name = "StatusComponent"
	q.add_child(qsc)
	qsc.set_process(false)
	qsc.apply_status("chill", 2.0)
	_check(absf(qsc.move_multiplier() - 0.6) < 0.001, "chill move_multiplier 0.6")
	qsc.clear_all()
	qsc.apply_status("root", 2.0)
	_check(qsc.move_multiplier() == 0.0, "root move_multiplier 0.0")
	qsc.clear_all()
	qsc.apply_status("stun", 2.0)
	_check(qsc.move_multiplier() == 0.0, "stun move_multiplier 0.0")
	qsc.clear_all()
	_check(qsc.move_multiplier() == 1.0, "clean move_multiplier 1.0")
	qsc.apply_status("blight", 2.0)
	_check(absf(qsc.healing_multiplier() - 0.5) < 0.001, "blight healing_multiplier 0.5")
	qsc.clear_all()
	_check(qsc.healing_multiplier() == 1.0, "clean healing_multiplier 1.0")
	qsc.apply_status("stun", 2.0)
	_check(qsc.blocks_actions(), "stun blocks actions")
	qsc.clear_all()
	qsc.apply_status("root", 2.0)
	_check(qsc.blocks_actions(), "root blocks actions")
	qsc.clear_all()
	qsc.apply_status("shock", 2.0)
	_check(qsc.blocks_actions(), "shock blocks actions")
	qsc.clear_all()
	qsc.apply_status("burn", 2.0)
	_check(not qsc.blocks_actions(), "burn does not block actions")
	qsc.clear_all()
	qsc.apply_status("chill", 2.0)
	_check(not qsc.blocks_actions(), "chill does not block actions")
	qsc.clear_all()
	qsc.apply_status("blight", 2.0)
	_check(not qsc.blocks_actions(), "blight does not block actions")
	q.queue_free()

	# --- resolve_hit applies a status -----------------------------------------
	var rt3 := StatusTarget.new()
	root.add_child(rt3)
	var scc := StatusComponent.new()
	scc.name = "StatusComponent"
	rt3.add_child(scc)
	scc.set_process(false)
	var res := DamageResolver.resolve_hit(null, rt3, {
		"damage": 5, "hit_id": "status-hit-1",
		"status": "burn", "status_duration": 2.0,
	})
	_check(bool(res.get("status_applied", false)), "resolve_hit reports status_applied true")
	_check(scc.has_status("burn"), "resolve_hit left burn applied")
	_check(absf(scc.time_left("burn") - 2.0) < 0.001, "burn duration came from status_duration")
	rt3.queue_free()

	var rt4 := StatusTarget.new()
	root.add_child(rt4)
	var res2 := DamageResolver.resolve_hit(null, rt4, {"damage": 5, "hit_id": "status-hit-2"})
	_check(not bool(res2.get("status_applied", true)), "payload without status reports status_applied false")
	rt4.queue_free()

	completed["statuses"] = true


## Follow-up group for the six status defects: death and respawn clearing, the
## dead guard on the player side (HP lives in GameState, not in a
## HealthComponent), DoT tick accounting and the per-tick cap, the resolver
## refusing to attach a status to a hit that did not land or that just killed
## its target, and a stun interrupting an in-progress swing.
func _test_status_lifecycle() -> void:
	DamageResolver.reset()
	gs.reset()

	# --- the player: death and respawn wipe every status -----------------------
	var arena := Node2D.new()
	root.add_child(arena)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(player)
	await process_frame
	var psc := player.get_node_or_null("StatusComponent") as StatusComponent
	_check(psc != null, "player owns a StatusComponent")
	if psc != null:
		psc.set_process(false)
		psc.apply_status("burn", 3.0, null, 1)
		psc.apply_status("chill", 3.0)
		_check(psc.has_status("burn"), "burn is live on the player before death")
		gs.take_damage(999)
		_check(gs.hp == 0, "the real damage path kills the player")
		_check(not psc.has_status("burn"), "player death clears statuses")
		_check(psc.effects.is_empty(), "player death clears every status, not just burn")
		player.call("_respawn")
		_check(gs.hp > 0, "respawn restores hp")
		_check(not psc.has_status("burn"), "respawn does not resurrect statuses")
		_check(psc.effects.is_empty(), "respawn leaves the player with no effects")

		# --- the dead guard covers the player ----------------------------------
		gs.reset()
		psc.apply_status("burn", 3.0, null, 1)
		gs.hp = 0
		var resolved := [0]
		var on_dealt := func(_result: Dictionary) -> void: resolved[0] += 1
		bus.damage_dealt.connect(on_dealt)
		psc.tick(1.0)
		bus.damage_dealt.disconnect(on_dealt)
		_check(gs.hp == 0, "DoT does not damage a player already at 0 hp")
		_check(resolved[0] == 0, "no damage is resolved against a dead player")
		psc.clear_all()
		gs.reset()
	arena.queue_free()
	await process_frame

	# --- the enemy: death wipes every status -----------------------------------
	DamageResolver.reset()
	var corpse := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	root.add_child(corpse)
	await process_frame
	var csc := corpse.get_node_or_null("StatusComponent") as StatusComponent
	_check(csc != null, "enemy owns a StatusComponent")
	if csc != null:
		csc.set_process(false)
		csc.apply_status("burn", 3.0, null, 2)
		csc.apply_status("chill", 3.0)
		_check(csc.has_status("burn"), "burn is live on the wolf before the killing hit")
		var kill := DamageResolver.resolve_hit(null, corpse, {
			"damage": 999, "hit_id": "lifecycle-kill-1",
			"status": "burn", "status_duration": 3.0,
		})
		_check(bool(kill.get("applied", false)), "the killing hit lands")
		_check(not bool(kill.get("status_applied", true)), "a killing hit reports status_applied false")
		var corpse_clean := not is_instance_valid(corpse)
		if is_instance_valid(csc):
			corpse_clean = csc.effects.is_empty()
		_check(corpse_clean, "a killing hit leaves no status on the corpse")
	gs.reset()

	# --- a hit that does not land never applies a status -----------------------
	var stump := Node.new()
	root.add_child(stump)
	var scc := StatusComponent.new()
	scc.name = "StatusComponent"
	stump.add_child(scc)
	scc.set_process(false)
	var miss := DamageResolver.resolve_hit(null, stump, {
		"damage": 5, "hit_id": "lifecycle-miss-1",
		"status": "burn", "status_duration": 2.0,
	})
	_check(not bool(miss.get("applied", true)), "target without receive_damage does not take the hit")
	_check(not bool(miss.get("status_applied", true)), "a hit that does not land reports status_applied false")
	_check(not scc.has_status("burn"), "a hit that does not land leaves no status behind")
	stump.queue_free()

	# --- DoT accounting: the tick count matches the duration -------------------
	var meter := StatusTarget.new()
	root.add_child(meter)
	var msc := StatusComponent.new()
	msc.name = "StatusComponent"
	meter.add_child(msc)
	msc.set_process(false)
	var fired := [0]
	var dealt := [0]
	var on_tick := func(_status_name: String, amount: int) -> void:
		fired[0] += 1
		dealt[0] += amount
	msc.ticked.connect(on_tick)
	msc.apply_status("burn", 3.0, null, 1)
	msc.tick(1.0)
	msc.tick(1.0)
	msc.tick(1.0)
	msc.ticked.disconnect(on_tick)
	_check(fired[0] == 3, "3.0 s burn at 1.0 s interval fires 3 ticks (got %d)" % fired[0])
	_check(dealt[0] == 9, "3 burn ticks total 9 damage (got %d)" % dealt[0])
	_check(meter.health.current_health == 21, "burn accounting lands as 9 hp of damage (hp=%d)" % meter.health.current_health)
	_check(not msc.has_status("burn"), "burn is gone once its duration is paid out")
	meter.queue_free()

	# --- DoT per-tick cap -------------------------------------------------------
	var capped := StatusTarget.new()
	root.add_child(capped)
	var xsc := StatusComponent.new()
	xsc.name = "StatusComponent"
	capped.add_child(xsc)
	xsc.set_process(false)
	xsc.apply_status("burn", 5.0, null, 5)
	_check(xsc.stacks("burn") == 5, "burn reached the stack cap of 5")
	_check(xsc._dot_damage("burn") == 15, "per-tick burn is capped at 15 (got %d)" % xsc._dot_damage("burn"))
	xsc.tick(1.0)
	_check(capped.health.current_health == 15, "a capped tick lands exactly 15 damage (hp=%d)" % capped.health.current_health)
	xsc.clear_all()
	xsc.apply_status("blight", 5.0, null, 5)
	_check(xsc._dot_damage("blight") == 10, "blight stays below the cap (got %d)" % xsc._dot_damage("blight"))
	capped.queue_free()

	# --- a stun interrupts an in-progress swing --------------------------------
	DamageResolver.reset()
	gs.reset()
	var ring := Node2D.new()
	root.add_child(ring)
	var wolf := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	wolf.position = Vector2(12, 0)
	ring.add_child(wolf)
	var victim := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	victim.position = Vector2(0, 0)
	ring.add_child(victim)

	var attacking := false
	for i in range(180):
		await physics_frame
		if int(wolf.get("state")) == 4:
			attacking = true
			break
	_check(attacking, "wolf entered ATTACK before the stun (state=%d)" % int(wolf.get("state")))
	if attacking:
		var wsc := wolf.get_node_or_null("StatusComponent") as StatusComponent
		var shape := wolf.get_node_or_null("AttackHitbox/CollisionShape2D") as CollisionShape2D
		var telegraph := wolf.get_node_or_null("Telegraph") as ColorRect
		_check(wsc != null and shape != null and telegraph != null,
			"attacker exposes status component, hitbox and telegraph")
		if wsc != null and shape != null and telegraph != null:
			wsc.apply_status("stun", 1.0)
			await physics_frame
			_check(int(wolf.get("state")) != 4, "stun aborts the enemy swing (state=%d)" % int(wolf.get("state")))
			_check(shape.disabled, "aborted swing leaves the hitbox disabled")
			_check(not telegraph.visible, "aborted swing hides the telegraph")
	ring.queue_free()
	await process_frame
	gs.reset()

	completed["status_lifecycle"] = true


## Spec §9.2 elemental combinations. Every rule is driven through the real
## DamageResolver so the wiring is pinned and not just the rule table, plus one
## direct call per rule to prove the rule alone is enough. Fully deterministic:
## status components do not self-process, the arena owns every node the rules can
## spawn, and the smoke-marker group is emptied at both ends so a marker can never
## leak into another group or into a bot run.
func _test_combinations() -> void:
	DamageResolver.reset()
	Combinations.reset()
	gs.reset()
	_free_smoke_zones()
	await process_frame

	var arena := Node2D.new()
	root.add_child(arena)

	# --- ice + physical: deeper stagger, never more damage ----------------------
	var clean := ComboTarget.new()
	arena.add_child(clean)
	var chilled := ComboTarget.new()
	arena.add_child(chilled)
	chilled.statuses.apply_status("chill", 5.0)
	_check(chilled.statuses.has_status("chill"), "chill is live on the chilled target")
	var clean_res := DamageResolver.resolve_hit(null, clean, {
		"damage": 10, "hit_id": "combo-plain-1", "damage_type": "physical",
	})
	var chilled_res := DamageResolver.resolve_hit(null, chilled, {
		"damage": 10, "hit_id": "combo-chill-1", "damage_type": "physical",
	})
	var clean_loss := 100 - _hp_of(clean)
	var chilled_loss := 100 - _hp_of(chilled)
	_check(clean_loss == 10, "plain physical hit costs 10 hp (got %d)" % clean_loss)
	_check(chilled_loss == clean_loss,
		"ice+physical adds no damage (%d vs %d hp)" % [chilled_loss, clean_loss])
	var ice_combo: Variant = chilled_res.get("combination", {})
	_check(ice_combo is Dictionary and not (ice_combo as Dictionary).is_empty(),
		"ice+physical reports a combination")
	_check(String((ice_combo as Dictionary).get("triggered", "")) == "ice_physical",
		"combination names the ice+physical rule")
	_check(float((ice_combo as Dictionary).get("extra_stagger", 0.0)) > 0.0,
		"ice+physical carries a positive stagger bonus")
	var plain_has_combo := clean_res.has("combination") \
			and not (clean_res.get("combination") as Dictionary).is_empty()
	_check(not plain_has_combo, "no rule fires on a plain hit against a clean target")
	_check(String(clean_res.get("damage_type", "")) == "physical" \
			and int(clean_res.get("final_damage", 0)) == 10 \
			and bool(clean_res.get("applied", false)),
		"the combination hook left the existing result keys alone")

	# --- the bonus reaches the enemy stagger clock -------------------------------
	var wolf := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(wolf)
	await process_frame
	var wolf_sc := wolf.get_node_or_null("StatusComponent") as StatusComponent
	_check(wolf_sc != null, "wolf owns a StatusComponent")
	if wolf_sc != null:
		wolf_sc.set_process(false)
		DamageResolver.resolve_hit(null, wolf, {
			"damage": 3, "hit_id": "combo-stagger-1", "damage_type": "physical",
		})
		var plain_clock := float(wolf.get("_stagger_left"))
		wolf_sc.apply_status("chill", 5.0)
		DamageResolver.resolve_hit(null, wolf, {
			"damage": 3, "hit_id": "combo-stagger-2", "damage_type": "physical",
		})
		var chilled_clock := float(wolf.get("_stagger_left"))
		_check(plain_clock > 0.0, "a physical hit starts the stagger clock (%.2f s)" % plain_clock)
		_check(chilled_clock > plain_clock,
			"ice+physical extends the stagger clock (%.2f > %.2f s)" % [chilled_clock, plain_clock])
		# 5 == Enemy.State.STAGGER, spelled as a number on purpose: naming the Enemy
		# class here would make the suite a compile dependency of enemy.gd, whose
		# autoload identifiers do not exist under `godot --script`.
		_check(int(wolf.get("state")) == 5,
			"the combo hit leaves the wolf staggered (state=%s)" % str(wolf.get("state")))
		_check(float(wolf.get("_stagger_bonus")) == 0.0,
			"the stagger bonus is consumed by the stagger entry")

	# --- fire + roots: the roots burn away, the marker deals nothing -------------
	var rooted := ComboTarget.new()
	arena.add_child(rooted)
	rooted.global_position = Vector2(200, 0)
	rooted.statuses.apply_status("root", 5.0)
	rooted.statuses.apply_status("burn", 3.0)
	var hp_before_burn := _hp_of(rooted)
	Combinations.on_status_applied(rooted, "burn", null)
	_check(not rooted.statuses.has_status("root"),
		"fire on a rooted target burns the roots away")
	_check(rooted.statuses.has_status("burn"), "the burn itself is not consumed")
	_check(_count_smoke_zones() == 1, "exactly one smoke marker (got %d)" % _count_smoke_zones())
	_check(_hp_of(rooted) == hp_before_burn,
		"the smoke marker deals no damage (hp %d -> %d)" % [hp_before_burn, _hp_of(rooted)])
	var marker := _first_smoke_zone()
	_check(marker != null and String(marker.name) == "SmokeZone", "the marker is named SmokeZone")
	_check(marker != null and marker.get_child_count() > 0 and marker.get_child(0) is ColorRect,
		"the marker is a ColorRect under a Node2D")
	_check(marker != null and not marker.has_method("receive_damage") \
			and marker.get_node_or_null("CollisionShape2D") == null \
			and marker.get_node_or_null("Area2D") == null,
		"the marker has no hitbox and cannot damage anything")
	_check(marker != null and marker.global_position.distance_to(rooted.global_position) < 0.01,
		"the marker sits on the target that burned")

	# The same rule through the real resolver: the only HP the target loses is the
	# hit it was actually dealt, so the combination cannot smuggle in mass damage.
	rooted.statuses.apply_status("root", 5.0)
	var hp_before_burst := _hp_of(rooted)
	var burst_res := DamageResolver.resolve_hit(null, rooted, {
		"damage": 8, "hit_id": "combo-burn-1", "damage_type": "fire",
		"status": "burn", "status_duration": 3.0,
	})
	_check(bool(burst_res.get("status_applied", false)), "the resolver applied the burn")
	_check(not rooted.statuses.has_status("root"), "the resolver's burn burned the roots away too")
	_check(_count_smoke_zones() == 2, "the second burn left a second marker (got %d)" % _count_smoke_zones())
	_check(hp_before_burst - _hp_of(rooted) == int(burst_res.get("final_damage", 0)),
		"the fire+roots hit costs exactly its own damage (got %d)" % (hp_before_burst - _hp_of(rooted)))

	# --- lightning + wet: a capped arc, never a cascade -------------------------
	var wet := ComboTarget.new()
	arena.add_child(wet)
	wet.global_position = Vector2(400, 0)
	wet.statuses.apply_status("chill", 5.0)
	var near: Array = []
	for i in range(5):
		var neighbour := ComboTarget.new()
		arena.add_child(neighbour)
		neighbour.global_position = Vector2(400.0 + float(i + 1) * 10.0, 0)
		near.append(neighbour)
	var far := ComboTarget.new()
	arena.add_child(far)
	far.global_position = Vector2(400.0 + Combinations.CHAIN_RADIUS + 40.0, 0)
	var shock_res := DamageResolver.resolve_hit(null, wet, {
		"damage": 11, "hit_id": "combo-shock-1", "damage_type": "lightning",
		"status": "shock", "status_duration": 0.6,
	})
	_check(bool(shock_res.get("status_applied", false)), "the shock landed on the wet target")
	var arc_count := 0
	for node in near:
		if _hp_of(node) < 100:
			arc_count += 1
	_check(arc_count == Combinations.MAX_CHAIN_TARGETS,
		"the arc hits at most MAX_CHAIN_TARGETS nearby enemies (got %d)" % arc_count)
	_check(_hp_of(near[0]) == 95 and _hp_of(near[1]) == 95 and _hp_of(near[2]) == 95,
		"each arc target takes half the shock damage (11 -> 5)")
	_check(_hp_of(near[3]) == 100 and _hp_of(near[4]) == 100,
		"the farthest neighbours are dropped by the cap")
	_check(_hp_of(far) == 100, "nothing outside the arc radius is touched")
	_check(100 - _hp_of(wet) == 11, "the wet target itself takes only the shock hit")
	_check(not (near[0] as ComboTarget).statuses.has_status("shock"),
		"arc targets never receive the shock itself, so nothing can cascade")

	# A payload flagged no_chain must not arc again: that flag is the recursion
	# guard, so the second level has to stay at exactly zero damage.
	var second := ComboTarget.new()
	arena.add_child(second)
	second.global_position = Vector2(700, 0)
	second.statuses.apply_status("chill", 5.0)
	var guard_near := ComboTarget.new()
	arena.add_child(guard_near)
	guard_near.global_position = Vector2(720, 0)
	DamageResolver.resolve_hit(null, second, {
		"damage": 10, "hit_id": "combo-shock-2", "damage_type": "lightning",
		"status": "shock", "status_duration": 0.6, "no_chain": true,
	})
	_check(_hp_of(guard_near) == 100, "a no_chain payload does not arc (no second-level damage)")
	_check(second.statuses.has_status("shock"), "the flagged hit still applies its own status")

	# --- healing + blight: half the heal, one stack burned off ------------------
	var blighted := ComboTarget.new()
	arena.add_child(blighted)
	blighted.statuses.apply_status("blight", 5.0, null, 2)
	_check(blighted.statuses.stacks("blight") == 2, "blight starts at two stacks")
	_check(Combinations.on_heal(blighted, 20) == 10, "a heal under blight lands at half")
	_check(blighted.statuses.stacks("blight") == 1, "the heal burned off one blight stack")
	_check(Combinations.on_heal(blighted, 20) == 10, "the second heal is still halved")
	_check(not blighted.statuses.has_status("blight"), "the last stack is removed by the heal")
	_check(Combinations.on_heal(blighted, 20) == 20, "with blight gone the heal is full")

	# The player's heal routes through the same rule, so a potion and a nature heal
	# both obey it without either caller knowing anything about statuses.
	var healer := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(healer)
	await process_frame
	var hsc := healer.get_node_or_null("StatusComponent") as StatusComponent
	_check(hsc != null, "the player owns a StatusComponent")
	if hsc != null:
		gs.reset()
		gs.hp = gs.max_hp - 60
		_check(int(healer.call("heal_with_status", 20)) == 20, "a clean heal reports the full amount")
		_check(gs.hp == gs.max_hp - 40, "a clean heal raised hp by 20 (hp=%d)" % gs.hp)
		hsc.apply_status("blight", 5.0, null, 2)
		_check(int(healer.call("heal_with_status", 20)) == 10, "a heal under blight reports half")
		_check(gs.hp == gs.max_hp - 30, "the halved heal raised hp by 10 (hp=%d)" % gs.hp)
		_check(hsc.stacks("blight") == 1, "the player heal burned off one blight stack")
		hsc.clear_all()
	gs.reset()

	# --- a corpse triggers nothing ----------------------------------------------
	var corpse := ComboTarget.new()
	arena.add_child(corpse)
	corpse.global_position = Vector2(900, 0)
	corpse.statuses.apply_status("chill", 30.0)
	corpse.statuses.apply_status("root", 30.0)
	var corpse_near := ComboTarget.new()
	arena.add_child(corpse_near)
	corpse_near.global_position = Vector2(920, 0)
	var kill_res := DamageResolver.resolve_hit(null, corpse, {
		"damage": 999, "hit_id": "combo-kill-1", "damage_type": "physical",
	})
	_check(bool(kill_res.get("applied", false)) and corpse.health.is_dead,
		"the killing hit lands and kills the target")
	_check(not kill_res.has("combination"), "a killing hit reports no combination")
	var smoke_before_corpse := _count_smoke_zones()
	Combinations.on_status_applied(corpse, "burn", null)
	Combinations.on_status_applied(corpse, "shock", null, {"damage": 10, "hit_id": "combo-dead-1"})
	_check(_count_smoke_zones() == smoke_before_corpse, "a dead target grows no smoke marker")
	_check(_hp_of(corpse_near) == 100, "a dead target arcs nothing")
	_check(corpse.statuses.has_status("root") and corpse.statuses.has_status("chill"),
		"a dead target keeps its statuses untouched")

	arena.queue_free()
	await process_frame
	_free_smoke_zones()
	await process_frame
	_check(_count_smoke_zones() == 0, "the group left no smoke marker behind")
	DamageResolver.reset()
	Combinations.reset()
	gs.reset()
	completed["combinations"] = true


## Defect #10 regression: STAGGER used to have no exit, so the first player hit
## froze an enemy forever and made combat free. Now the stagger clock runs down
## and the enemy rejoins the fight (spec §10.4). Deterministic: each wolf's own
## StatusComponent is stopped so only the explicit hits and the fixed 60 Hz
## physics clock move time, and every wolf is driven through real physics frames.
## States are spelled as numbers (3 CHASE, 5 STAGGER, 6 DEAD) so the suite stays
## out of enemy.gd's compile graph, whose autoloads do not exist under --script.
func _test_stagger_recovery() -> void:
	DamageResolver.reset()
	gs.reset()

	var arena := Node2D.new()
	root.add_child(arena)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	player.position = Vector2.ZERO
	arena.add_child(player)
	await process_frame

	# --- a plain hit staggers, then the wolf re-acquires a visible player -------
	var wolf := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	wolf.position = Vector2(40, 0)
	arena.add_child(wolf)
	var wsc := wolf.get_node_or_null("StatusComponent") as StatusComponent
	_check(wsc != null, "stagger wolf owns a StatusComponent")
	if wsc != null:
		wsc.set_process(false)
	DamageResolver.resolve_hit(null, wolf, {
		"damage": 3, "hit_id": "stag-plain-1", "damage_type": "physical",
	})
	var plain_clock := float(wolf.get("_stagger_left"))
	_check(int(wolf.get("state")) == 5, "a physical hit puts the wolf into STAGGER (state=%s)" % str(wolf.get("state")))
	_check(plain_clock > 0.0, "the plain stagger clock is running (%.2f s)" % plain_clock)

	# The player is visible and on a short leash, so the sensible next state is
	# CHASE, and the wolf only leaves once its clock is actually spent.
	var frames := await _drive_out_of_stagger(wolf, 120)
	_check(frames >= 0, "the wolf left STAGGER before the frame cap (%d)" % frames)
	_check(int(wolf.get("state")) != 5, "the wolf is no longer STAGGER once the clock expires (state=%s)" % str(wolf.get("state")))
	_check(float(wolf.get("_stagger_left")) <= 0.0, "the wolf left STAGGER only after its clock was spent")
	_check(int(wolf.get("state")) == 3, "a staggered wolf with a visible leashed player recovers into CHASE (state=%s)" % str(wolf.get("state")))

	# It must not slip back into STAGGER on its own: only a hit enters it.
	var self_recover := true
	for i in range(30):
		await physics_frame
		if int(wolf.get("state")) == 5:
			self_recover = false
	_check(self_recover, "the wolf does not re-enter STAGGER without a new hit")

	# --- ice + physical keeps the wolf down longer than a plain hit -------------
	var chilled := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	chilled.position = Vector2(40, 60)
	arena.add_child(chilled)
	var csc := chilled.get_node_or_null("StatusComponent") as StatusComponent
	if csc != null:
		csc.set_process(false)
		csc.apply_status("chill", 30.0)
	DamageResolver.resolve_hit(null, chilled, {
		"damage": 3, "hit_id": "stag-chill-1", "damage_type": "physical",
	})
	var chilled_clock := float(chilled.get("_stagger_left"))
	_check(int(chilled.get("state")) == 5, "the ice+physical hit staggers the second wolf (state=%s)" % str(chilled.get("state")))
	_check(chilled_clock > plain_clock,
		"ice+physical extends the stagger clock (%.2f > %.2f s)" % [chilled_clock, plain_clock])
	# Drive the chilled wolf frame by frame: it must still be down at the frame a
	# plain hit would already be over, and only rise after its own longer clock.
	var plain_frames := int(ceil(plain_clock * 60.0))
	var chilled_total := -1
	var down_at_plain := false
	for i in range(120):
		await physics_frame
		var stag := int(chilled.get("state")) == 5
		if i + 1 == plain_frames:
			down_at_plain = stag
		if not stag:
			chilled_total = i + 1
			break
	_check(down_at_plain, "the chilled wolf is still staggered where a plain hit would have released it (frame %d)" % plain_frames)
	_check(chilled_total > 0, "the chilled wolf eventually leaves STAGGER (%d)" % chilled_total)
	_check(int(chilled.get("state")) != 5, "the chilled wolf is no longer STAGGER after its longer clock")
	_check(chilled_total > plain_frames,
		"the chilled wolf stayed staggered for more frames than a plain hit (%d > %d)" % [chilled_total, plain_frames])

	# --- no visible player: the wolf gives up and INVESTIGATEs ------------------
	var far := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	far.position = Vector2(200, 0)
	arena.add_child(far)
	var fsc := far.get_node_or_null("StatusComponent") as StatusComponent
	if fsc != null:
		fsc.set_process(false)
	DamageResolver.resolve_hit(null, far, {
		"damage": 3, "hit_id": "stag-far-1", "damage_type": "physical",
	})
	_check(int(far.get("state")) == 5, "the far wolf is staggered by the hit (state=%s)" % str(far.get("state")))
	var far_frames := await _drive_out_of_stagger(far, 120)
	_check(far_frames >= 0, "the far wolf leaves STAGGER (%d)" % far_frames)
	_check(int(far.get("state")) == 2,
		"a staggered wolf with no visible player recovers into INVESTIGATE (state=%s)" % str(far.get("state")))

	# --- a killing blow taken mid-stagger still kills cleanly -------------------
	var victim := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	victim.position = Vector2(40, 120)
	arena.add_child(victim)
	var vsc := victim.get_node_or_null("StatusComponent") as StatusComponent
	if vsc != null:
		vsc.set_process(false)
	DamageResolver.resolve_hit(null, victim, {
		"damage": 3, "hit_id": "stag-kill-1", "damage_type": "physical",
	})
	_check(int(victim.get("state")) == 5, "the victim is staggered before the killing blow (state=%s)" % str(victim.get("state")))
	DamageResolver.resolve_hit(null, victim, {
		"damage": 999, "hit_id": "stag-kill-2", "damage_type": "physical",
	})
	_check(int(victim.get("state")) == 6, "a killing blow during stagger leaves the wolf DEAD (state=%s)" % str(victim.get("state")))
	var stays_dead := true
	for i in range(8):
		await physics_frame
		if is_instance_valid(victim) and int(victim.get("state")) != 6:
			stays_dead = false
	_check(stays_dead, "a wolf killed while staggered stays DEAD (never pops back to STAGGER)")

	arena.queue_free()
	await process_frame
	DamageResolver.reset()
	gs.reset()
	completed["stagger_recovery"] = true


## Drive real physics frames until the enemy leaves STAGGER. Returns the number of
## frames driven, or -1 if it never left within the cap. The caller separately
## asserts the stagger clock is spent at exit, which catches a premature exit;
## this loop returning -1 catches a wolf stuck in STAGGER after its clock hit zero.
## 5 == Enemy.State.STAGGER, spelled as a number on purpose (see the group header).
func _drive_out_of_stagger(node: Node, max_frames: int) -> int:
	for i in range(max_frames):
		await physics_frame
		if int(node.get("state")) != 5:
			return i + 1
	return -1


## Spec §6 "Комбо зависят от оружия": the attack chain is item data, not a
## hardcoded swing. A sword chains three fast steps, a spear two slower steps
## with longer reach, and the chain only survives inside the combo window the
## weapon declares. Deterministic: a bare arena holds the player, so nothing
## else can move it, block it or be hit by it, and every swing is started
## through _start_attack() rather than injected input (the real mouse path stays
## pinned by the human_input group). 2 == Player.State.ATTACK, spelled as a
## number on purpose, as everywhere else in this suite.
func _test_weapon_combos() -> void:
	DamageResolver.reset()
	gs.reset()

	# --- the chain is data ------------------------------------------------------
	var sword_steps := ItemDB.combo_steps("iron_sword")
	var spear_steps := ItemDB.combo_steps("iron_spear")
	_check(sword_steps.size() == 3, "iron_sword carries a 3-step chain (got %d)" % sword_steps.size())
	_check(spear_steps.size() == 2, "iron_spear carries a 2-step chain (got %d)" % spear_steps.size())
	_check(ItemDB.combo_steps("health_potion").is_empty(), "an item without a combo returns no steps")
	_check(ItemDB.combo_steps("no_such_item").is_empty(), "an unknown item returns no steps")
	_check(absf(ItemDB.combo_window("iron_sword") - 0.45) < 0.001, "sword combo window is 0.45 s")
	_check(absf(ItemDB.combo_window("iron_spear") - 0.55) < 0.001, "spear combo window is 0.55 s")
	_check(absf(ItemDB.combo_window("leather_armor") - 0.4) < 0.001,
		"an item with no combo_window falls back to 0.4 s")
	_check(absf(ItemDB.combo_window("no_such_item") - 0.4) < 0.001,
		"an unknown item falls back to 0.4 s")
	var reach_ok := sword_steps.size() == 3 and spear_steps.size() == 2 \
			and float(spear_steps[0].get("reach", 0.0)) > float(sword_steps[0].get("reach", 0.0))
	_check(reach_ok, "the spear out-reaches the sword on the first step")

	# --- casting rig: a bare arena with one player ------------------------------
	var arena := Node2D.new()
	root.add_child(arena)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(player)
	await process_frame

	# --- sword: 0 -> 1 -> 2 -> wraps to 0 --------------------------------------
	_equip_weapon("iron_sword")
	_check(int(player.call("combo_step_count")) == 3, "sword player reports 3 chain steps")
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 0, "first attack starts the chain at step 0")
	_check(absf(float(player.call("current_step_multiplier")) - 1.0) < 0.001, "sword step 0 multiplier is 1.0")
	await _finish_swing(player, 90)
	_check(float(player.call("combo_window_left")) > 0.0, "a finished swing opens the combo window")
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 1, "attack inside the window advances to step 1")
	_check(absf(float(player.call("current_step_multiplier")) - 1.15) < 0.001, "sword step 1 multiplier is 1.15")
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 2, "second attack inside the window advances to step 2")
	_check(absf(float(player.call("current_step_multiplier")) - 1.4) < 0.001, "sword step 2 multiplier is 1.4")
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 0, "the attack after the last step wraps back to step 0")

	# --- an expired window restarts the chain -----------------------------------
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 1, "chain is still alive before the window expires")
	await _finish_swing(player, 90)
	player.set("_combo_window_left", 0.0)
	await physics_frame
	_check(int(player.call("combo_index")) == 0, "an expired combo window resets the chain to step 0")
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 0, "the next attack after expiry starts at step 0")
	_check(absf(float(player.call("current_step_multiplier")) - 1.0) < 0.001,
		"the restarted chain is back at multiplier 1.0")

	# --- a chain must not index past a newly equipped weapon --------------------
	await _finish_swing(player, 90)
	player.call("_start_attack")
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 2, "sword chain reached its last step")
	await _finish_swing(player, 90)
	_equip_weapon("iron_spear")
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 0,
		"swapping to a shorter weapon mid-chain restarts at step 0")

	# --- spear: 2 steps, second one 1.5 ----------------------------------------
	_check(int(player.call("combo_step_count")) == 2, "spear player reports a 2-step chain")
	_check(absf(float(player.call("current_step_multiplier")) - 1.1) < 0.001, "spear step 0 multiplier is 1.1")
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 1, "spear advances to its second step")
	_check(absf(float(player.call("current_step_multiplier")) - 1.5) < 0.001, "spear step 1 multiplier is 1.5")
	await _finish_swing(player, 90)
	player.call("_start_attack")
	_check(int(player.call("combo_index")) == 0, "spear wraps back to step 0 after its last step")
	await _finish_swing(player, 90)

	# --- the step's own timings drive the swing --------------------------------
	var sword_windup := float(sword_steps[0].get("windup", 0.0))
	var spear_windup := float(spear_steps[0].get("windup", 0.0))
	_check(spear_windup > sword_windup,
		"the spear winds up slower than the sword (%.2f > %.2f s)" % [spear_windup, sword_windup])
	_equip_weapon("iron_sword")
	var sword_frames := await _frames_until_hitbox_open(player)
	_equip_weapon("iron_spear")
	var spear_frames := await _frames_until_hitbox_open(player)
	_check(sword_frames > 0 and spear_frames > 0, "both swings opened their hitbox")
	_check(spear_frames > sword_frames,
		"the slower spear step keeps the hitbox shut longer (%d > %d frames)" % [spear_frames, sword_frames])
	_check(sword_frames >= 0 and float(sword_frames) / 60.0 >= sword_windup - (1.0 / 60.0),
		"sword hitbox opens no earlier than its own windup (%d frames vs %.2f s)" % [sword_frames, sword_windup])
	_check(spear_frames >= 0 and float(spear_frames) / 60.0 >= spear_windup - (1.0 / 60.0),
		"spear hitbox opens no earlier than its own windup (%d frames vs %.2f s)" % [spear_frames, spear_windup])

	# --- unarmed still swings, still has one step, still deals damage -----------
	_equip_weapon("")
	_check(int(player.call("combo_step_count")) == 1, "unarmed player has a single-step chain")
	await _settle_idle(player)
	var dummy := AttackDummy.new()
	dummy.collision_layer = 4
	dummy.collision_mask = 0
	var dummy_shape := CollisionShape2D.new()
	var dummy_rect := RectangleShape2D.new()
	dummy_rect.size = Vector2(10, 10)
	dummy_shape.shape = dummy_rect
	dummy.add_child(dummy_shape)
	arena.add_child(dummy)
	# The swing is aim-driven, so the dummy goes where the swing will actually be,
	# exactly the way the skill group resolves the same ambiguity.
	var aim := InputSource.aim_direction(player.global_position)
	var dir: Vector2 = aim if aim.length() > 0.01 else Vector2.DOWN
	player.set("facing", dir)
	dummy.global_position = player.global_position + dir * 12.0
	await physics_frame
	player.call("_start_attack")
	for i in range(60):
		await physics_frame
		if dummy.hits > 0:
			break
	_check(dummy.hits == 1, "unarmed swing damages the target exactly once (got %d)" % dummy.hits)
	_check(dummy.last_damage >= gs.total_attack(),
		"unarmed swing deals at least the raw attack (%d vs %d)" % [dummy.last_damage, gs.total_attack()])
	_check(absf(float(player.call("current_step_multiplier")) - 1.0) < 0.001,
		"unarmed multiplier is 1.0")
	dummy.queue_free()
	# A landed swing runs a short hit-stop through Engine.time_scale, and the
	# player owns that coroutine: freeing it mid-await would strand the time scale
	# at 0.12 for every group that follows, so let it finish first.
	for i in range(120):
		if Engine.time_scale == 1.0:
			break
		await process_frame
	_check(Engine.time_scale == 1.0, "combo group restored Engine.time_scale after the hit-stop")

	arena.queue_free()
	await process_frame
	DamageResolver.reset()
	gs.reset()
	completed["weapon_combos"] = true


## Process-wide hit-stop (the HitStop autoload): the slow-motion clock is owned by
## a node that is never freed mid-stop, merges overlapping requests to the longest
## remaining duration, and always restores Engine.time_scale = 1.0 — even when the
## player dies or respawns while a stop is running. The clock is driven
## deterministically by calling _process directly with scaled deltas, so no real
## frames advance the stop inside this group (the only awaits are for the player
## death/respawn rig, by which point the scale is already back to 1.0).
func _test_hit_stop() -> void:
	var hit_stop := root.get_node_or_null("HitStop")
	_check(hit_stop != null, "HitStop autoload present")
	if hit_stop == null:
		Engine.time_scale = 1.0
		completed["hit_stop"] = true
		return
	var scale: float = float(hit_stop.get("SCALE"))
	Engine.time_scale = 1.0

	# --- a single request slows time, then restores after the real duration ----
	hit_stop.call("request", 0.1)
	_check(absf(Engine.time_scale - scale) < 0.0001, "request sets Engine.time_scale to the stop scale")
	_advance_hit_stop(hit_stop, 0.05)
	_check(absf(Engine.time_scale - scale) < 0.0001, "still slowed halfway through the requested time")
	_advance_hit_stop(hit_stop, 0.06)
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "restored to 1.0 after the requested real time")

	# --- overlapping requests keep the scale down until the LONGER one ends ----
	hit_stop.call("request", 0.05)
	hit_stop.call("request", 0.15)
	_check(absf(Engine.time_scale - scale) < 0.0001, "overlapping requests keep the stop scale")
	_advance_hit_stop(hit_stop, 0.10)
	_check(absf(Engine.time_scale - scale) < 0.0001,
		"still slowed past the shorter request while the longer one runs")
	_advance_hit_stop(hit_stop, 0.06)
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "restored once the longer request's time is spent")

	# --- cancel restores immediately and clears the active flag ----------------
	hit_stop.call("request", 0.5)
	_check(absf(Engine.time_scale - scale) < 0.0001, "request before cancel slows time")
	hit_stop.call("cancel")
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "cancel restores 1.0 immediately")
	_check(not bool(hit_stop.get("_active")), "cancel clears the active flag")

	# --- zero / negative durations are ignored ---------------------------------
	hit_stop.call("request", 0.0)
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "zero duration does not change the scale")
	_check(not bool(hit_stop.get("_active")), "zero duration does not activate the stop")
	hit_stop.call("request", -0.5)
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "negative duration does not change the scale")
	_check(not bool(hit_stop.get("_active")), "negative duration does not activate the stop")

	# --- death and respawn during a stop cannot strand the scale ---------------
	gs.reset()
	var arena := Node2D.new()
	root.add_child(arena)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(player)
	await process_frame
	player.call("_hit_stop", 0.5)
	_check(absf(Engine.time_scale - scale) < 0.0001, "player hit-stop delegates to the autoload")
	gs.take_damage(999)
	_check(gs.hp == 0, "the killing blow kills the player")
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "player death cancels the running hit-stop")
	player.call("_respawn")
	_check(gs.hp > 0, "respawn restores hp")
	_check(absf(Engine.time_scale - 1.0) < 0.0001, "respawn leaves full speed")
	arena.queue_free()
	await process_frame
	gs.reset()

	# --- finally-style guard: never poison a later group with a reduced scale --
	var ended_clean := absf(Engine.time_scale - 1.0) < 0.0001
	Engine.time_scale = 1.0
	_check(ended_clean, "hit-stop group ends with Engine.time_scale == 1.0")
	completed["hit_stop"] = true


## Advance the HitStop clock by `seconds` of real time in fixed real steps. The
## autoload converts the scaled delta it receives back to real seconds (it divides
## by Engine.time_scale), so handing it `step * Engine.time_scale` advances exactly
## `step` real seconds per call. Once the stop has restored the scale to 1.0 the
## autoload ignores further calls, so the loop simply runs out harmlessly.
func _advance_hit_stop(hit_stop: Node, seconds: float, step: float = 0.01) -> void:
	var remaining := seconds
	while remaining > 0.000001:
		var s := minf(step, remaining)
		hit_stop.call("_process", s * Engine.time_scale)
		remaining -= s


## P1 regression: GameState.equip() existed but nothing ever called it, so the
## player could pick up a weapon and stay unarmed forever. This group pins the
## whole reachability chain end-to-end — the equip/unequip round-trip on
## GameState, then the real HUD panel driven through real key events: the cursor
## opens at 0, walks with the existing movement actions, clamps at both ends, E
## equips an equipment row (and the row shows [надето]), E again unequips, E on a
## consumable leaves equipment untouched, movement stays blocked while the panel
## is open, and a 10-stack inventory never renders more than 8 rows. GameState
## and the scene are reset at both ends and ui_blocking is forced clear, so the
## panel is never left open for a later group.
func _test_inventory_equip() -> void:
	gs.reset()
	qm.reset()

	# --- GameState equip/unequip round-trip (pure logic, no scene) -----------
	gs.add_item("iron_sword", 1)
	var atk_base: int = gs.total_attack()
	var sword_atk := int(ItemDB.get_item("iron_sword").get("attack", 0))
	_check(sword_atk == 6, "iron_sword carries attack 6")
	_check(gs.equip("iron_sword"), "equip iron_sword succeeds")
	_check(gs.total_attack() == atk_base + sword_atk,
		"equip raises attack by exactly the weapon value (%d -> %d)" % [atk_base, gs.total_attack()])
	_check(gs.unequip("weapon"), "unequip weapon succeeds")
	_check(gs.total_attack() == atk_base,
		"unequip restores attack to the base value (%d)" % gs.total_attack())
	_check(not gs.unequip("weapon"), "unequip on an already-empty slot returns false")
	_check(not gs.unequip("armor"), "unequip on an empty armor slot returns false")
	_check(not gs.unequip("not_a_slot"), "unequip on an unknown slot returns false")

	# --- UI: drive the real HUD through real key events ----------------------
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var hud := scene.get_node_or_null("HUD")
	var player := get_first_node_in_group("player") as Node2D
	_check(hud != null and player != null, "hud and player present for inventory-equip test")
	if hud == null or player == null:
		gs.ui_blocking = false
		gs.reset()
		completed["inventory_equip"] = true
		return

	# Navigation reuses the existing movement actions; no new actions were added.
	_check(InputMap.has_action(&"move_up") and InputMap.has_action(&"move_down"),
		"move_up and move_down actions exist for inventory navigation")

	# --- open the panel: cursor at 0, clamps at the top ----------------------
	gs.reset()
	gs.add_item("iron_sword", 1)
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_inventory_open")), "key I opens the inventory")
	_check(gs.ui_blocking, "ui_blocking is set while the inventory is open")
	_check(int(hud.call("inventory_selection")) == 0, "opening the inventory puts the cursor at 0")
	await _tap_key(KEY_W)
	_check(int(hud.call("inventory_selection")) == 0, "move_up at the top stays clamped at 0")

	# --- E equips the selected equipment row, E again unequips ---------------
	await _tap_key(KEY_E)
	_check(String(gs.equipment.get("weapon", "")) == "iron_sword", "E equips the selected weapon")
	var equipped_row := _row_with_marker(hud)
	_check(equipped_row.contains("[надето]"), "the equipped row shows [надето]")
	_check(equipped_row.begins_with("> "), "the selected row carries the > cursor")
	_check(gs.total_attack() == 11, "equipping the sword raises total attack to 11 (got %d)" % gs.total_attack())
	await _tap_key(KEY_E)
	_check(String(gs.equipment.get("weapon", "")) == "", "E again unequips the weapon")
	_check(gs.total_attack() == 5, "unequipping restores total attack to 5 (got %d)" % gs.total_attack())

	# --- movement stays blocked while the panel is open ----------------------
	var before := player.global_position
	var d_down := InputEventKey.new()
	d_down.physical_keycode = KEY_D
	d_down.keycode = KEY_D
	d_down.pressed = true
	Input.parse_input_event(d_down)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) < 2.0, "inventory open blocks movement")
	var d_up := InputEventKey.new()
	d_up.physical_keycode = KEY_D
	d_up.keycode = KEY_D
	d_up.pressed = false
	Input.parse_input_event(d_up)
	await physics_frame

	# --- E on a consumable leaves equipment untouched ------------------------
	gs.add_item("health_potion", 1)   # inventory now [iron_sword, health_potion]
	await _tap_key(KEY_S)
	_check(int(hud.call("inventory_selection")) == 1, "move_down moves the cursor to row 1")
	var eq_before: Dictionary = gs.equipment.duplicate(true)
	await _tap_key(KEY_E)
	_check(gs.equipment == eq_before, "E on a consumable leaves equipment untouched")
	_check(String(gs.equipment.get("weapon", "")) == "", "a consumable never equips into the weapon slot")

	# --- scroll window keeps the panel inside 480x270 ------------------------
	await _tap_key(KEY_I)   # close
	gs.reset()
	gs.add_item("iron_sword", 1)
	gs.add_item("iron_spear", 1)
	gs.add_item("leather_armor", 1)
	gs.add_item("health_potion", 1)
	gs.add_item("mana_potion", 1)
	gs.add_item("wolf_fang", 1)
	gs.add_item("rusted_seal", 1)
	for i in range(3):
		gs.inventory.append({"id": "test_stack_%d" % i, "amount": 1})
	bus.inventory_changed.emit()
	_check(gs.inventory.size() == 10, "built a 10-stack inventory for the overflow test")
	await _tap_key(KEY_I)   # reopen
	_check(int(hud.call("inventory_selection")) == 0, "reopening resets the cursor to 0")
	_check(int(hud.call("visible_inventory_row_count")) == 8,
		"only 8 rows render with 10 stacks (got %d)" % int(hud.call("visible_inventory_row_count")))
	for i in range(9):
		await _tap_key(KEY_S)
	_check(int(hud.call("inventory_selection")) == 9, "cursor walks to the last of 10 rows")
	_check(int(hud.call("visible_inventory_row_count")) == 8,
		"the window stays capped at 8 rows after scrolling (got %d)" % int(hud.call("visible_inventory_row_count")))
	var rows: PackedStringArray = hud.call("inventory_row_texts")
	_check(rows.size() == 8 and rows[rows.size() - 1].begins_with("> "),
		"the scrolled window keeps the selected last row visible")
	await _tap_key(KEY_S)
	_check(int(hud.call("inventory_selection")) == 9, "move_down at the bottom stays clamped at the last row")

	# --- leave no residue for later groups -----------------------------------
	await _tap_key(KEY_I)   # close
	gs.ui_blocking = false
	scene.queue_free()
	await process_frame
	gs.reset()
	qm.reset()
	completed["inventory_equip"] = true


## The visible row that carries the [надето] tag, or the first row when nothing
## is equipped (so the caller can still read the cursor marker off it).
func _row_with_marker(hud: Node) -> String:
	var rows: PackedStringArray = hud.call("inventory_row_texts")
	for row in rows:
		if row.contains("[надето]"):
			return row
	return "" if rows.is_empty() else rows[0]


## Put a weapon into the equipment slot (or clear it with ""). Goes through the
## real equip() path, which needs the item in the inventory first.
func _equip_weapon(item_id: String) -> void:
	gs.equipment["weapon"] = ""
	if item_id == "":
		return
	gs.add_item(item_id, 1)
	gs.equip(item_id)


## Drive frames until the player leaves ATTACK and return without an extra frame,
## so the next attack is issued while the combo window is still fresh.
func _finish_swing(player: Node, max_frames: int) -> void:
	for i in range(max_frames):
		if int(player.get("state")) != 2:
			return
		await physics_frame


## Start a guaranteed chain step 0 and drive real physics frames until the attack
## hitbox first opens. The frame count is the step's wind-up, so a weapon with a
## longer wind-up must open its hitbox strictly later than a faster one.
func _frames_until_hitbox_open(player: Node) -> int:
	for i in range(60):
		if int(player.get("state")) != 2:
			break
		await physics_frame
	# Cleared only once the previous swing is over: a finishing swing re-opens its
	# own window, which would push this one to step 1 and measure the wrong wind-up.
	player.set("_combo_window_left", 0.0)
	player.call("_start_attack")
	var shape := player.get_node_or_null("AttackHitbox/CollisionShape2D") as CollisionShape2D
	if shape == null:
		return -1
	for i in range(60):
		await physics_frame
		if not shape.disabled:
			return i + 1
	return -1


## Current HP of a ComboTarget-shaped fixture, read through the HealthComponent
## node name so the test never depends on the fixture's own field names.
func _hp_of(node: Node) -> int:
	var hc := node.get_node_or_null("HealthComponent")
	return int(hc.get("current_health")) if hc != null else -1


## Live smoke markers, counted through the group they join rather than by name:
## Godot renames a second sibling called "SmokeZone" to "SmokeZone2".
func _count_smoke_zones() -> int:
	return get_nodes_in_group("smoke_zone").size()


func _first_smoke_zone() -> Node2D:
	return get_first_node_in_group("smoke_zone") as Node2D


func _free_smoke_zones() -> void:
	for node in get_nodes_in_group("smoke_zone"):
		node.queue_free()


## The suite must produce the same result no matter what user://settings/
## controls.json was on disk when it started. This group runs before any group
## that injects real key events and before the input_bindings group, so the only
## thing that could have produced the current state is the suite-start reset. It
## then proves that reset neutralises a pre-existing rebind by planting one
## through the engine (exactly as the settings screen would) and resetting again.
func _test_input_isolation() -> void:
	var ib := root.get_node_or_null("InputBindings")
	_check(ib != null, "InputBindings present for isolation test")
	if ib == null:
		completed["input_isolation"] = true
		return

	# State the suite-start reset is responsible for.
	_check(not FileAccess.file_exists(String(InputBindings.PATH)),
		"suite start removed any pre-existing controls file")
	_check(_action_has_key("interact", KEY_E), "interact is on default E at suite start")
	_check(not _action_has_key("interact", KEY_F),
		"no pre-existing interact->F rebind survived the suite-start reset")

	# Plant a realistic pre-existing rebind through the engine, then show the
	# suite-start reset neutralises it. Deterministic in every run, not only
	# when an external poison file happens to be present.
	_check(bool(ib.call("rebind", "interact", _key_event(KEY_F))),
		"isolation: planted an interact->F rebind")
	_check(_action_has_key("interact", KEY_F) and not _action_has_key("interact", KEY_E),
		"isolation: planted rebind is live before the reset")
	_check(FileAccess.file_exists(String(InputBindings.PATH)),
		"isolation: planted rebind wrote a controls file")

	_reset_input_to_known_state()

	_check(_action_has_key("interact", KEY_E),
		"suite-start reset neutralises a pre-existing interact->F rebind (E restored)")
	_check(not _action_has_key("interact", KEY_F),
		"suite-start reset drops the pre-existing F binding")
	_check(not FileAccess.file_exists(String(InputBindings.PATH)),
		"suite-start reset removes the pre-existing controls file")
	completed["input_isolation"] = true


## Spec §6/§18: rebinding through the InputBindings autoload, persisted in a
## settings file that lives outside user://saves. The group owns the whole
## control state: it starts from defaults with no settings file and leaves
## neither behind, so no other group, bot or later run sees its bindings.
func _test_input_bindings() -> void:
	var ib := root.get_node_or_null("InputBindings")
	_check(ib != null, "InputBindings autoload present")
	if ib == null:
		completed["input_bindings"] = true
		return

	_restore_control_defaults(ib)
	_delete_settings_file()

	_check(not bool(ib.call("rebind", "not_an_action", _key_event(KEY_F))),
		"rebind rejects an action outside REBINDABLE")
	_check(not bool(ib.call("rebind", "interact", null)), "rebind rejects a null event")

	_check(bool(ib.call("rebind", "interact", _key_event(KEY_F))), "rebind interact to F succeeds")
	_check(_action_has_key("interact", KEY_F), "interact is bound to F after rebind")
	_check(not _action_has_key("interact", KEY_E), "interact no longer bound to E")

	_check(not bool(ib.call("rebind", "inventory", _key_event(KEY_F))),
		"rebind to a key owned by another rebindable action is refused")
	_check(_action_has_key("interact", KEY_F), "refused rebind keeps interact on F")
	_check(_action_has_key("inventory", KEY_I), "refused rebind keeps inventory on I")

	var save_res: Dictionary = ib.call("save_bindings")
	_check(bool(save_res.get("ok", false)), "save_bindings reports ok")
	_check(FileAccess.file_exists(String(InputBindings.PATH)), "controls file written")
	_check(not String(InputBindings.PATH).begins_with("user://saves"),
		"controls live outside the saves directory")

	# Real round-trip: wipe the runtime change by hand, let the file put it back.
	InputMap.action_erase_events(&"interact")
	_check(not _action_has_key("interact", KEY_F), "interact cleared before reload")
	ib.call("load_bindings")
	_check(_action_has_key("interact", KEY_F), "F binding comes back from the file")

	ib.call("reset_action", "interact")
	_check(_action_has_key("interact", KEY_E), "reset_action restores E")
	_check(not _action_has_key("interact", KEY_F), "reset_action drops F")

	# A corrupt file must keep the defaults instead of crashing the load.
	var file := FileAccess.open(String(InputBindings.PATH), FileAccess.WRITE)
	_check(file != null, "corrupt controls fixture opens for writing")
	if file != null:
		file.store_string("{ this is not json")
		file.close()
	ib.call("load_bindings")
	_check(_action_has_key("interact", KEY_E), "corrupt controls file keeps default bindings")

	_restore_control_defaults(ib)
	_delete_settings_file()
	_check(not FileAccess.file_exists(String(InputBindings.PATH)),
		"input bindings group left no settings file behind")
	_check(not FileAccess.file_exists(String(InputBindings.PATH) + ".tmp"),
		"input bindings group left no tmp file behind")
	completed["input_bindings"] = true


func _key_event(code: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	return event


func _action_has_key(action: String, code: int) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == code:
			return true
	return false


func _restore_control_defaults(ib: Node) -> void:
	for action in InputBindings.REBINDABLE:
		ib.call("reset_action", action)


func _delete_settings_file() -> void:
	for path in [String(InputBindings.PATH), String(InputBindings.PATH) + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## Single source of truth for putting the controls back into a known state.
## Called once at suite start (so a pre-existing user://settings/controls.json
## cannot leak into the groups that inject real key events) and once at the end
## (so the suite leaves no residue). reset_action() persists the defaults it
## writes, so the file it recreates is deleted again here. The pristine defaults
## come from InputBindings._defaults, captured before load_bindings() ran, so a
## poisoned file cannot contaminate them.
func _reset_input_to_known_state() -> void:
	var ib := root.get_node_or_null("InputBindings")
	if ib == null:
		return
	_delete_settings_file()
	_restore_control_defaults(ib)
	_delete_settings_file()

