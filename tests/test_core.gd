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

	print("== attributes ==")
	await _test_attributes()

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
	await _test_enemy_variants()

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

	print("== equipment slots ==")
	_test_equipment_slots()

	print("== item rarity ==")
	_test_item_rarity()

	print("== character panel ==")
	await _test_character_panel()

	print("== shop ==")
	await _test_shop()

	print("== craft ==")
	await _test_craft()

	print("== dialogues ==")
	_test_dialogues()

	print("== day cycle ==")
	await _test_day_cycle()

	print("== input bindings ==")
	_test_input_bindings()

	# Leave no settings residue for the next run, a bot or the editor.
	_reset_input_to_known_state()
	_check(not FileAccess.file_exists(String(InputBindings.PATH)),
		"suite left no controls file behind")

	_check(completed.size() == 41, "every test group ran to completion (got %d/41)" % completed.size())

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


## Attributes and progression (spec §7.1–7.2): the four stats, the data-driven XP
## curve, the per-level point pool, and the single recomputation path that turns
## points into numbers. The bulk of it is pure state work, so nothing can drift
## between two checks; the tail runs on a real player and a real enemy in a bare
## arena, because the derived numbers only count once a combatant actually reads
## them. The arena is freed and GameState reset at both ends.
func _test_attributes() -> void:
	gs.reset()

	# --- defaults --------------------------------------------------------------
	_check(gs.attribute("strength") == 5, "strength starts at 5")
	_check(gs.attribute("agility") == 5, "agility starts at 5")
	_check(gs.attribute("intelligence") == 5, "intelligence starts at 5")
	_check(gs.attribute("endurance") == 5, "endurance starts at 5")
	_check(gs.attribute_points == 0, "no attribute points at level 1")
	_check(gs.level == 1, "level 1 after reset")
	_check(gs.max_attribute() == 30, "the single attribute cap is 30")
	_check(absf(gs.crit_chance() - 0.05) < 0.0001, "crit chance at agility 5 is the data base 0.05")
	_check(absf(gs.move_speed_multiplier() - 1.0) < 0.0001, "movement multiplier at agility 5 is 1.0")
	_check(absf(gs.magic_multiplier() - 1.0) < 0.0001, "magic multiplier at intelligence 5 is 1.0")
	_check(absf(gs.control_resistance()) < 0.0001, "control resistance at endurance 5 is 0.0")
	_check(gs.max_hp == 100 and gs.max_mana == 60 and gs.base_attack == 5,
		"derived base values at level 1 with no points (hp=%d mana=%d attack=%d)"
		% [gs.max_hp, gs.max_mana, gs.base_attack])
	_check(gs.total_attack() == 5, "unarmed total attack equals the base attack")

	# --- the curve lives in the data ------------------------------------------
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/progression.json"))
	_check(raw is Dictionary, "data/progression.json parses as a JSON object")
	var data: Dictionary = raw if raw is Dictionary else {}
	var curve: Array = data.get("xp_curve", [])
	_check(curve.size() == 21, "xp_curve has 21 entries (got %d)" % curve.size())
	_check(int(data.get("max_level", 0)) == 20, "data max_level is 20")
	_check(int(data.get("points_per_level", 0)) == 2, "data points_per_level is 2")
	_check(not curve.is_empty() and int(curve[0]) == 0, "xp_curve starts at 0 total xp")
	var monotonic := true
	for i in range(1, curve.size()):
		if int(curve[i]) <= int(curve[i - 1]):
			monotonic = false
	_check(monotonic, "xp_curve is strictly increasing")
	# What has to stay smooth is the requirement of a single level (the difference
	# of two neighbouring totals), not the totals themselves.
	var smooth := true
	var worst_factor := 0.0
	for i in range(2, curve.size()):
		var previous := float(int(curve[i - 1]) - int(curve[i - 2]))
		var current := float(int(curve[i]) - int(curve[i - 1]))
		if previous <= 0.0:
			smooth = false
			break
		var factor := current / previous
		worst_factor = maxf(worst_factor, factor)
		if factor < 1.0 or factor > 1.8:
			smooth = false
	_check(smooth, "every per-level requirement grows by a factor within 1.0..1.8 (worst %.3f)" % worst_factor)
	_check(gs.max_level() == 20, "GameState reads max_level from the data")
	_check(gs.points_per_level() == 2, "GameState reads points_per_level from the data")
	_check(curve.size() == 21 and gs.xp_needed_for(1) == int(curve[1]) - int(curve[0]),
		"level 1 needs the first curve difference (got %d)" % gs.xp_needed_for(1))
	_check(gs.xp_to_next == gs.xp_needed_for(1), "xp_to_next at level 1 comes from the curve")

	# --- a level-up pays exactly one point grant -------------------------------
	var points_before: int = gs.attribute_points
	var level_before: int = gs.level
	gs.add_xp(gs.xp_to_next)
	_check(gs.level == level_before + 1, "one full bar raises the level by exactly 1")
	_check(gs.attribute_points == points_before + 2, "a level-up grants exactly 2 points (got %d)" % gs.attribute_points)
	var two_more: int = gs.xp_needed_for(2) + gs.xp_needed_for(3)
	gs.add_xp(two_more)
	_check(gs.level == 4, "exactly two more requirements buy exactly two levels (level %d)" % gs.level)
	_check(gs.attribute_points == 6, "three level-ups paid 3 x 2 = 6 points (got %d)" % gs.attribute_points)

	# --- the cap: no levels and no points past it ------------------------------
	gs.reset()
	gs.add_xp(1000000)
	_check(gs.level == 20, "a huge xp grant stops at the level cap (level %d)" % gs.level)
	_check(gs.attribute_points == 38, "19 level-ups grant 19 x 2 = 38 points (got %d)" % gs.attribute_points)
	var points_at_cap: int = gs.attribute_points
	gs.add_xp(1000000)
	_check(gs.level == 20, "xp past the cap does not level further")
	_check(gs.attribute_points == points_at_cap, "xp past the cap awards no points")
	_check(gs.xp <= gs.xp_to_next, "xp stops at the cap (xp=%d of %d)" % [gs.xp, gs.xp_to_next])

	# --- spending: what it refuses --------------------------------------------
	gs.reset()
	_check(not gs.spend_attribute_point("strength"), "spending out of an empty pool is refused")
	_check(gs.attribute("strength") == 5, "a refused spend leaves the attribute untouched")
	gs.attribute_points = 5
	_check(not gs.spend_attribute_point("charisma"), "an unknown attribute name is refused")
	_check(not gs.spend_attribute_point(""), "an empty attribute name is refused")
	_check(gs.attribute_points == 5, "a refused spend costs no point")
	_check(gs.spend_attribute_point("strength"), "spending into a known attribute succeeds")
	_check(gs.attribute("strength") == 6, "the point lands in the attribute")
	_check(gs.attribute_points == 4, "the pool went down by exactly 1")

	# --- strength -> attack, exactly one point per level -----------------------
	_check(gs.total_attack() == 6, "one point of strength raises total attack by exactly 1 (got %d)" % gs.total_attack())
	var attack_before: int = gs.total_attack()
	gs.spend_attribute_point("strength")
	_check(gs.total_attack() == attack_before + 1,
		"the second point of strength adds exactly 1 more (got %d)" % gs.total_attack())

	# --- endurance -> hp and control resistance --------------------------------
	gs.reset()
	gs.attribute_points = 3
	_check(gs.spend_attribute_point("endurance"), "endurance accepts a point")
	_check(gs.max_hp == 105, "one point of endurance raises max hp by exactly 5 (got %d)" % gs.max_hp)
	_check(absf(gs.control_resistance() - 0.02) < 0.0001,
		"one point of endurance adds 0.02 control resistance (got %.4f)" % gs.control_resistance())
	gs.spend_attribute_point("endurance")
	gs.spend_attribute_point("endurance")
	_check(gs.max_hp == 115, "three points of endurance raise max hp by 15 (got %d)" % gs.max_hp)
	_check(absf(gs.control_resistance() - 0.06) < 0.0001,
		"three points of endurance add 0.06 control resistance (got %.4f)" % gs.control_resistance())
	_check(gs.hp <= gs.max_hp, "raising a maximum never leaves hp above it")
	# The 0.6 ceiling is a guard against out-of-range data: the attribute cap on
	# its own tops out at 0.5, so only a hand-edited save can push past it.
	gs.attributes["endurance"] = 200
	gs.recompute_derived()
	_check(absf(gs.control_resistance() - 0.6) < 0.0001,
		"control resistance is capped at 0.6 (got %.4f)" % gs.control_resistance())

	# --- intelligence -> mana and magic power ----------------------------------
	gs.reset()
	gs.attribute_points = 2
	_check(gs.spend_attribute_point("intelligence"), "intelligence accepts a point")
	_check(gs.max_mana == 64, "one point of intelligence raises max mana by exactly 4 (got %d)" % gs.max_mana)
	# Corrected, not deleted: these two asserted the old +0.6-per-point curve
	# (1.6 / 2.2), which made intelligence 20 a ~10x spell. The tuned curve is
	# +0.06 per point above the base 5.
	_check(absf(gs.magic_multiplier() - 1.06) < 0.0001,
		"one point of intelligence raises the magic multiplier by 0.06 (got %.4f)" % gs.magic_multiplier())
	gs.spend_attribute_point("intelligence")
	_check(gs.max_mana == 68, "two points of intelligence raise max mana by 8 (got %d)" % gs.max_mana)
	_check(absf(gs.magic_multiplier() - 1.12) < 0.0001,
		"two points of intelligence raise the magic multiplier by 0.12 (got %.4f)" % gs.magic_multiplier())

	# --- the magic curve is tuned, clamped and read from the data ---------------
	_check(absf(float(data.get("magic_per_intelligence", 0.0)) - 0.06) < 0.0001,
		"data/progression.json sets magic_per_intelligence to 0.06")
	gs.attributes["intelligence"] = 15
	gs.recompute_derived()
	_check(absf(gs.magic_multiplier() - 1.6) < 0.001,
		"intelligence 15 gives the magic multiplier 1.6 (got %.4f)" % gs.magic_multiplier())
	gs.attributes["intelligence"] = 20
	gs.recompute_derived()
	_check(absf(gs.magic_multiplier() - 1.9) < 0.001,
		"intelligence 20 gives the magic multiplier 1.9 (got %.4f)" % gs.magic_multiplier())
	gs.attributes["intelligence"] = 30
	gs.recompute_derived()
	_check(absf(gs.magic_multiplier() - 2.5) < 0.001,
		"intelligence 30 sits exactly on the 2.5 ceiling (got %.4f)" % gs.magic_multiplier())
	gs.attributes["intelligence"] = 200
	gs.recompute_derived()
	_check(absf(gs.magic_multiplier() - 2.5) < 0.001,
		"the magic multiplier never climbs past its 2.5 ceiling (got %.4f)" % gs.magic_multiplier())
	gs.attributes["intelligence"] = 2
	gs.recompute_derived()
	_check(gs.magic_multiplier() >= 1.0 - 0.0001,
		"intelligence below the base 5 never weakens a spell below 1.0 (got %.4f)" % gs.magic_multiplier())
	gs.reset()

	# --- agility -> crit and speed --------------------------------------------
	gs.reset()
	gs.attribute_points = 3
	var crit_before: float = gs.crit_chance()
	var speed_before: float = gs.move_speed_multiplier()
	_check(gs.spend_attribute_point("agility"), "agility accepts a point")
	_check(gs.crit_chance() > crit_before, "agility raises the crit chance")
	_check(absf(gs.crit_chance() - (crit_before + 0.005)) < 0.0001,
		"one point of agility adds 0.005 crit (got %.4f)" % gs.crit_chance())
	_check(gs.move_speed_multiplier() > speed_before, "agility raises the movement multiplier")
	_check(absf(gs.move_speed_multiplier() - 1.008) < 0.0001,
		"one point of agility adds 0.8 percent speed (got %.4f)" % gs.move_speed_multiplier())
	gs.spend_attribute_point("agility")
	gs.spend_attribute_point("agility")
	_check(absf(gs.crit_chance() - 0.065) < 0.0001,
		"agility 8 gives 0.065 crit (got %.4f)" % gs.crit_chance())
	gs.attributes["agility"] = 500
	gs.recompute_derived()
	_check(absf(gs.move_speed_multiplier() - 1.3) < 0.0001,
		"movement multiplier is capped at 1.3 (got %.4f)" % gs.move_speed_multiplier())

	# --- the per-attribute cap -------------------------------------------------
	gs.reset()
	gs.attribute_points = 100
	for i in range(40):
		gs.spend_attribute_point("strength")
	_check(gs.attribute("strength") == gs.max_attribute(),
		"strength stops at the per-attribute cap (got %d)" % gs.attribute("strength"))
	var points_stuck: int = gs.attribute_points
	_check(not gs.spend_attribute_point("strength"), "spending into a capped attribute is refused")
	_check(gs.attribute_points == points_stuck, "a spend into a capped attribute costs no point")
	_check(gs.attribute("agility") == 5, "the cap on one attribute leaves the others alone")

	# --- one recomputation, called twice, changes nothing ----------------------
	gs.reset()
	gs.attribute_points = 6
	gs.spend_attribute_point("strength")
	gs.spend_attribute_point("endurance")
	gs.spend_attribute_point("intelligence")
	gs.spend_attribute_point("agility")
	gs.level = 5
	gs.recompute_derived()
	var snapshot := _derived_snapshot()
	gs.recompute_derived()
	gs.recompute_derived()
	_check(snapshot == _derived_snapshot(),
		"recompute_derived() is idempotent (three calls produced the same numbers)")

	# --- the strength bonus and the weapon bonus never double ------------------
	gs.reset()
	gs.attribute_points = 3
	gs.spend_attribute_point("strength")
	gs.add_item("iron_sword", 1)
	_check(gs.total_attack() == 6, "unarmed with strength 6 attacks for 6 (got %d)" % gs.total_attack())
	gs.equip("iron_sword")
	_check(gs.total_attack() == 12, "strength 6 plus the sword's 6 attacks for 12 (got %d)" % gs.total_attack())
	gs.unequip("weapon")
	_check(gs.total_attack() == 6, "taking the sword off leaves the strength bonus intact (got %d)" % gs.total_attack())
	gs.equip("iron_sword")
	_check(gs.total_attack() == 12, "equip -> unequip -> equip does not double the weapon bonus (got %d)" % gs.total_attack())
	gs.equip("iron_sword")
	_check(gs.total_attack() == 12, "equipping the same weapon twice still does not double it (got %d)" % gs.total_attack())
	gs.spend_attribute_point("strength")
	_check(gs.total_attack() == 13, "the next strength point adds exactly 1 on top of the weapon (got %d)" % gs.total_attack())
	gs.unequip("weapon")
	gs.reset()

	# --- persistence -----------------------------------------------------------
	gs.attribute_points = 7
	gs.spend_attribute_point("strength")
	gs.spend_attribute_point("endurance")
	var saved: Dictionary = gs.to_dict()
	_check(saved.get("attributes") is Dictionary, "to_dict writes an attributes block")
	_check(int(saved.get("attribute_points", -1)) == 5, "to_dict writes the remaining points")
	gs.reset()
	_check(gs.attribute("strength") == 5 and gs.attribute_points == 0, "reset clears attributes and pool")
	gs.from_dict(saved)
	_check(gs.attribute("strength") == 6, "round-trip keeps the spent strength")
	_check(gs.attribute("endurance") == 6, "round-trip keeps the spent endurance")
	_check(gs.attribute("agility") == 5 and gs.attribute("intelligence") == 5,
		"round-trip keeps the untouched attributes at 5")
	_check(gs.attribute_points == 5, "round-trip keeps the unspent points (got %d)" % gs.attribute_points)
	_check(gs.total_attack() == 6, "round-trip recomputes the same attack (got %d)" % gs.total_attack())
	_check(gs.max_hp == 105, "round-trip recomputes the same max hp (got %d)" % gs.max_hp)

	# a save written before the attributes existed
	var legacy: Dictionary = saved.duplicate(true)
	legacy.erase("attributes")
	legacy.erase("attribute_points")
	gs.from_dict(legacy)
	_check(gs.attribute("strength") == 5 and gs.attribute("agility") == 5
			and gs.attribute("intelligence") == 5 and gs.attribute("endurance") == 5,
			"a save with no attributes restores 5/5/5/5")
	_check(gs.attribute_points == 0, "a save with no point pool restores 0 points")

	# a hand-edited block falls back per key instead of taking the block down
	var junk: Dictionary = saved.duplicate(true)
	junk["attributes"] = {"strength": -3, "agility": "quick", "intelligence": 9, "endurance": null}
	junk["attribute_points"] = "many"
	gs.from_dict(junk)
	_check(gs.attribute("strength") == 5, "a negative strength falls back to 5")
	_check(gs.attribute("agility") == 5, "a string agility falls back to 5")
	_check(gs.attribute("endurance") == 5, "a null endurance falls back to 5")
	_check(gs.attribute("intelligence") == 9, "a valid intelligence in the same block survives")
	_check(gs.attribute_points == 0, "a string point pool falls back to 0")
	_check(gs.max_mana == 76, "the recomputed maxima follow the restored attributes (got %d)" % gs.max_mana)

	# --- the pools never outlive a maximum that shrank -------------------------
	var inflated: Dictionary = saved.duplicate(true)
	inflated["attributes"] = {"strength": 5, "agility": 5, "intelligence": 5, "endurance": 5}
	inflated["attribute_points"] = 0
	inflated["level"] = 1
	inflated["max_hp"] = 400
	inflated["hp"] = 400
	inflated["max_mana"] = 300
	inflated["mana"] = 300
	gs.from_dict(inflated)
	_check(gs.max_hp == 100, "the loaded max hp comes from the recompute (got %d)" % gs.max_hp)
	_check(gs.hp == 100, "hp above the recomputed maximum is clamped on load (got %d)" % gs.hp)
	_check(gs.max_mana == 60, "the loaded max mana comes from the recompute (got %d)" % gs.max_mana)
	_check(gs.mana == 60, "mana above the recomputed maximum is clamped on load (got %d)" % gs.mana)
	gs.attributes["endurance"] = 30
	gs.recompute_derived()
	gs.hp = gs.max_hp
	_check(gs.hp == 225, "endurance 30 owns 225 hp (got %d)" % gs.hp)
	gs.attributes["endurance"] = 5
	gs.recompute_derived()
	_check(gs.hp == 100 and gs.hp <= gs.max_hp,
		"a shrunken maximum pulls hp back under its ceiling (hp=%d max=%d)" % [gs.hp, gs.max_hp])
	gs.reset()

	# --- control resistance reaches the status system ---------------------------
	# `GameState.control_resistance()` used to be computed and never consumed:
	# StatusComponent asks its owner for `get_status_resistance(status)`, no
	# combatant had that method, so every control status landed at full duration.
	# A real player in a bare arena proves the whole chain, and the same hook is
	# pinned on an enemy so the contract is symmetrical.
	var arena := Node2D.new()
	root.add_child(arena)
	var hero := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node2D
	arena.add_child(hero)
	await process_frame
	gs.reset()
	gs.attributes["endurance"] = 15
	gs.recompute_derived()
	_check(absf(gs.control_resistance() - 0.2) < 0.0001,
		"endurance 15 owns 0.2 control resistance (got %.4f)" % gs.control_resistance())
	_check(hero.has_method("get_status_resistance"), "Player exposes get_status_resistance()")
	if hero.has_method("get_status_resistance"):
		_check(absf(float(hero.call("get_status_resistance", "root")) - 0.2) < 0.0001,
			"the player answers 0.2 resistance for root (got %.4f)" % float(hero.call("get_status_resistance", "root")))
		_check(absf(float(hero.call("get_status_resistance", "stun")) - 0.2) < 0.0001,
			"the player answers 0.2 resistance for stun (got %.4f)" % float(hero.call("get_status_resistance", "stun")))
		_check(absf(float(hero.call("get_status_resistance", "shock")) - 0.2) < 0.0001,
			"the player answers 0.2 resistance for shock (got %.4f)" % float(hero.call("get_status_resistance", "shock")))
		_check(absf(float(hero.call("get_status_resistance", "burn"))) < 0.0001,
			"the player answers 0.0 resistance for burn (got %.4f)" % float(hero.call("get_status_resistance", "burn")))
	var hero_statuses := hero.get_node_or_null("StatusComponent") as StatusComponent
	_check(hero_statuses != null, "the player owns a StatusComponent")
	if hero_statuses != null:
		# Nothing may tick between the apply and the read, or the clock measured
		# below would be the resistance minus a frame of physics.
		hero_statuses.set_process(false)
		hero_statuses.clear_all()
		_check(bool(hero_statuses.apply_status("stun", 2.0)), "the stun lands on the player")
		_check(absf(hero_statuses.time_left("stun") - 1.6) < 0.0001,
			"0.2 resistance shortens a 2.0 s stun to 1.6 s (got %.4f)" % hero_statuses.time_left("stun"))
		hero_statuses.clear_all()

	# An enemy has no attributes, so it answers zero explicitly rather than
	# leaving StatusComponent to its "owner has no hook" fallback.
	var wolf := (load("res://scenes/enemies/wolf.tscn") as PackedScene).instantiate() as Node2D
	_check(wolf != null and wolf.has_method("get_status_resistance"), "Enemy exposes get_status_resistance()")
	var enemy_resistance_is_zero := wolf != null
	if wolf != null:
		for control_status: String in ["burn", "chill", "shock", "root", "blight", "stun"]:
			if absf(float(wolf.call("get_status_resistance", control_status))) > 0.0001:
				enemy_resistance_is_zero = false
	_check(enemy_resistance_is_zero, "an enemy reports 0.0 resistance for every status")
	if wolf != null:
		wolf.free()

	# --- the magic multiplier really reaches a cast -----------------------------
	# fire_burst is an aoe, so its damage goes through Player._magic_damage() and
	# out through DamageResolver onto a target with get_defense() == 0 and no crit
	# path (an aoe payload carries no "critical" key). The only slop left is the
	# integer rounding of the final damage, hence the 1-point tolerance.
	DamageResolver.reset()
	gs.mana = gs.max_mana
	gs.learn_skill("fire_burst")
	gs.select_skill("fire_burst")
	var cds: Dictionary = hero.get("_skill_cooldowns")
	var burst := SkillDB.get_skill("fire_burst")
	var aim := InputSource.aim_direction(hero.global_position)
	var burst_dir: Vector2 = aim if aim.length() > 0.01 else (hero.get("facing") as Vector2)
	var dummy := AoeTarget.new()
	arena.add_child(dummy)
	dummy.add_to_group("enemy")
	dummy.global_position = hero.global_position + burst_dir * float(burst.get("range", 0.0))
	cds["fire_burst"] = 0.0
	_check(bool(hero.try_ability()), "fire_burst casts at intelligence 5")
	var damage_at_int5: int = dummy.last_damage
	_check(damage_at_int5 == 18, "fire_burst lands its raw 18 at intelligence 5 (got %d)" % damage_at_int5)
	gs.attributes["intelligence"] = 20
	gs.recompute_derived()
	gs.mana = gs.max_mana
	cds["fire_burst"] = 0.0
	_check(bool(hero.try_ability()), "fire_burst casts again at intelligence 20")
	var damage_at_int20: int = dummy.last_damage
	_check(absf(float(damage_at_int20) - float(damage_at_int5) * 1.9) <= 1.0,
			"intelligence 20 lands the same cast at 1.9x (got %d vs %d)" % [damage_at_int20, damage_at_int5])
	_check(damage_at_int20 > damage_at_int5,
		"the smarter caster hits harder (%d > %d)" % [damage_at_int20, damage_at_int5])

	dummy.queue_free()
	arena.queue_free()
	await process_frame
	_check(get_first_node_in_group("player") == null, "the attributes rig left no player behind")
	_check(get_nodes_in_group("enemy").is_empty(), "the attributes rig left no enemy behind")
	DamageResolver.reset()
	gs.reset()
	completed["attributes"] = true


## Every number `recompute_derived()` owns, so the idempotency check can compare
## one dictionary instead of nine separate assertions.
func _derived_snapshot() -> Dictionary:
	return {
		"max_hp": gs.max_hp,
		"max_mana": gs.max_mana,
		"base_attack": gs.base_attack,
		"hp": gs.hp,
		"mana": gs.mana,
		"total_attack": gs.total_attack(),
		"crit": gs.crit_chance(),
		"speed": gs.move_speed_multiplier(),
		"magic": gs.magic_multiplier(),
		"resist": gs.control_resistance(),
	}

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


## Six behaviour exports were added to the shared `Enemy` script for the two new
## forest types (roadmap stage D, spec §10). This group proves three things at
## once: the world really spawns both of them and on ground an enemy can stand
## on; the exports actually change how the new enemies move and die rather than
## only their hit points; and the wolf and the cultist still read every default,
## which is the regression risk of putting a knob on a shared script. The last
## blocks measure behaviour on a bare arena instead of reading numbers back.
func _test_enemy_variants() -> void:
	gs.reset()
	DamageResolver.reset()

	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var world := scene.get_node_or_null("World")
	var boars: Array[Node] = []
	var wisps: Array[Node] = []
	var wolves: Array[Node] = []
	var archers: Array[Node] = []
	for node in get_nodes_in_group("enemy"):
		var type: Variant = node.get("enemy_type")
		if type == &"ash_boar":
			boars.append(node)
		elif type == &"ash_wisp":
			wisps.append(node)
		elif type == &"ash_wolf":
			wolves.append(node)
		elif type == &"ash_archer":
			archers.append(node)

	_check(boars.size() == 2, "world spawns exactly 2 ash_boar (got %d)" % boars.size())
	_check(wisps.size() == 2, "world spawns exactly 2 ash_wisp (got %d)" % wisps.size())
	# The two new types must not disturb the composition the quest and the other
	# groups depend on: five wolves and the single cultist.
	_check(wolves.size() >= 5, "world still spawns at least 5 wolves (got %d)" % wolves.size())
	_check(archers.size() == 1 and String(archers[0].name) == "ArcherA",
		"world still spawns exactly one cultist named ArcherA")

	# Both new spawns go through `_find_walkable_near`, so neither may end up on
	# stone or in a tree cluster. The tile is read back through the public Forest
	# API rather than assumed from the anchor.
	var new_spawns: Array[Node] = []
	new_spawns.append_array(boars)
	new_spawns.append_array(wisps)
	var solid_spawns := 0
	for node: Node in new_spawns:
		var body := node as Node2D
		var tile := Vector2i(
			floori(body.global_position.x / 16.0),
			floori(body.global_position.y / 16.0)
		)
		var cell := String(world.call("cell_at", tile)) if world != null else ""
		if cell != "." and cell != ",":
			solid_spawns += 1
			print("      %s stands on %s = '%s'" % [String(node.name), str(tile), cell])
	_check(solid_spawns == 0, "every new enemy stands on a walkable tile (%d on solid)" % solid_spawns)

	var boar: Node = boars[0] if not boars.is_empty() else null
	var wisp: Node = wisps[0] if not wisps.is_empty() else null
	var wolf: Node = wolves[0] if not wolves.is_empty() else null
	var cultist: Node = archers[0] if not archers.is_empty() else null
	_check(boar != null and wisp != null, "a boar and a wisp are available to inspect")
	if boar != null and wisp != null and wolf != null and cultist != null:
		# The kinds are compared against the two original enemies rather than
		# against `Enemy.Kind`: naming that class here would drag enemy.gd into
		# the suite's compile graph, and its autoloads do not exist under --script.
		_check(int(boar.get("kind")) == int(wolf.get("kind")), "the boar fights melee like a wolf")
		_check(int(wisp.get("kind")) == int(cultist.get("kind")), "the wisp fights ranged like a cultist")
		_check(float(boar.get("speed_multiplier")) > 1.0,
			"the boar is built to outrun a wolf (speed_multiplier=%.2f)" % float(boar.get("speed_multiplier")))
		_check(bool(boar.get("charge_on_sight")), "the boar charges on sight")
		_check(not bool(wisp.get("charge_on_sight")), "the wisp does not charge, it keeps its distance")
		_check(float(boar.get("windup_multiplier")) > 1.0, "the boar telegraphs longer than a wolf")
		_check(float(boar.get("attack_cooldown_multiplier")) > 1.0,
			"the boar pays for its heavy swing with a longer pause")
		_check(float(wisp.get("windup_multiplier")) < 1.0, "the wisp telegraphs shorter than a cultist")
		_check(float(wisp.get("attack_cooldown_multiplier")) < 1.0,
			"the wisp shoots more often than a cultist")
		_check(boar.get("projectile_scene") == null, "the melee boar carries no projectile")
		_check(wisp.get("projectile_scene") != null, "the wisp carries the shared projectile scene")
		_check(int(boar.get("max_health")) == 46, "the boar pool is 46 hp")
		_check(int(wisp.get("max_health")) == 16, "the wisp pool is 16 hp")
		_check(String(boar.get("loot_item")) == "wolf_fang"
			and String(wisp.get("loot_item")) == "mana_potion",
			"both new enemies drop items that already exist in the data")

		# The tint is the only thing separating a reused placeholder sprite from
		# its original owner, so it has to be on the sprite from the first frame.
		var boar_sprite := boar.get_node_or_null("Sprite2D") as Sprite2D
		var wisp_sprite := wisp.get_node_or_null("Sprite2D") as Sprite2D
		_check(boar_sprite != null
			and (boar.get("sprite_tint") as Color).is_equal_approx(boar_sprite.modulate),
			"the boar sprite carries its exported tint at start")
		_check(wisp_sprite != null
			and (wisp.get("sprite_tint") as Color).is_equal_approx(wisp_sprite.modulate),
			"the wisp sprite carries its exported tint at start")
		_check(boar_sprite != null and wisp_sprite != null
			and not boar_sprite.modulate.is_equal_approx(wisp_sprite.modulate),
			"the two new enemies do not read as the same tinted sprite")

	if wolf != null:
		_check_original_enemy_defaults("wolf", wolf)
	if cultist != null:
		_check_original_enemy_defaults("cultist", cultist)

	scene.queue_free()
	await process_frame
	await process_frame

	# --- behaviour, measured on a bare arena ----------------------------------
	var arena := Node2D.new()
	root.add_child(arena)
	var player_scene: PackedScene = load("res://scenes/player/player.tscn")
	var player := player_scene.instantiate() as Node2D
	player.position = Vector2.ZERO
	arena.add_child(player)
	var boar_scene: PackedScene = load("res://scenes/enemies/boar.tscn")
	var wisp_scene: PackedScene = load("res://scenes/enemies/wisp.tscn")
	var wolf_scene: PackedScene = load("res://scenes/enemies/wolf.tscn")

	# Same distance from the player on opposite sides, so both acquire it on the
	# same frame, neither can block the other on the way in, and both are walked
	# by the same physics delta. The first frame only turns IDLE into CHASE, so
	# three of the four frames are real movement for both — the comparison holds
	# whatever the actual tick length turns out to be.
	var charger := boar_scene.instantiate() as Node2D
	charger.position = Vector2(0, -60)
	var baseline := wolf_scene.instantiate() as Node2D
	baseline.position = Vector2(0, 60)
	arena.add_child(charger)
	arena.add_child(baseline)
	await process_frame

	var charger_start := charger.global_position
	var baseline_start := baseline.global_position
	for i in range(4):
		await physics_frame
	var charger_moved := charger.global_position.distance_to(charger_start)
	var baseline_moved := baseline.global_position.distance_to(baseline_start)
	_check(charger_moved > baseline_moved * 1.15,
		"the boar closes on the player faster than a wolf over the same frames (%.2f px vs %.2f px)" % [charger_moved, baseline_moved])
	# Out of the way before the next blocks: two live chasers would beat the
	# player down while the slower kiting and firing checks are still stepping.
	charger.queue_free()
	baseline.queue_free()
	await process_frame
	await process_frame

	# A boar eats exactly its own pool: 46 hp in 10 hp bites is five hits, the
	# fifth one lands on zero, and the kill is credited to the new type.
	var tank := boar_scene.instantiate() as Node2D
	tank.position = Vector2(400, 400)
	arena.add_child(tank)
	var tank_health := tank.get_node("HealthComponent") as HealthComponent
	var hits := 0
	while not tank_health.is_dead and hits < 20:
		hits += 1
		tank.receive_damage(10, {"damage": 10, "hit_id": "variants-%d" % hits})
	_check(hits == 5, "a boar dies to exactly 5 hits of 10 damage (got %d)" % hits)
	_check(tank_health.current_health == 0, "the boar hp lands exactly on zero")
	_check(int(gs.call("kill_count", "ash_boar")) == 1, "the boar death is credited to ash_boar")

	# The wisp kites: inside the ranged minimum distance it backs off, which is
	# the one thing a wolf never does. It cannot fire there either, so the only
	# movement it can show is the retreat.
	var kite := wisp_scene.instantiate() as Node2D
	kite.position = Vector2(40, 0)
	arena.add_child(kite)
	await process_frame
	var kite_from := kite.global_position.distance_to(player.global_position)
	for i in range(6):
		await physics_frame
	var kite_to := kite.global_position.distance_to(player.global_position)
	_check(kite_to > kite_from,
		"the wisp backs away inside the ranged minimum distance (%.1f -> %.1f px)" % [kite_from, kite_to])

	# And at a distance it really is the ranged kind: it fires the shared
	# projectile, exactly like the cultist does in the `ranged` group.
	gs.hp = gs.max_hp
	var shooter := wisp_scene.instantiate() as Node2D
	shooter.position = Vector2(90, 0)
	arena.add_child(shooter)
	var saw_shot := false
	for i in range(180):
		await physics_frame
		for child in arena.get_children():
			if child is Area2D and child.get_script() != null and String(child.get_script().resource_path).ends_with("projectile.gd"):
				saw_shot = true
		if saw_shot:
			break
	_check(saw_shot, "the wisp fires a projectile")

	arena.queue_free()
	await process_frame
	gs.reset()
	DamageResolver.reset()
	completed["enemy_variants"] = true


## The wolf and the cultist are built from the same script that grew the new
## behaviour exports, so every knob has to read as if it were never added. Called
## once per original enemy type; the label prefix keeps the two apart in the log.
func _check_original_enemy_defaults(who: String, node: Node) -> void:
	_check(absf(float(node.get("speed_multiplier")) - 1.0) < 0.0001,
		"%s keeps speed_multiplier 1.0" % who)
	_check(absf(float(node.get("attack_cooldown_multiplier")) - 1.0) < 0.0001,
		"%s keeps attack_cooldown_multiplier 1.0" % who)
	_check(absf(float(node.get("windup_multiplier")) - 1.0) < 0.0001,
		"%s keeps windup_multiplier 1.0" % who)
	_check(not bool(node.get("charge_on_sight")), "%s keeps charge_on_sight false" % who)
	_check((node.get("sprite_tint") as Color) == Color.WHITE, "%s keeps a white tint" % who)
	var spr := node.get_node_or_null("Sprite2D") as Sprite2D
	_check(spr != null and spr.modulate == Color.WHITE, "%s sprite is untinted" % who)


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


## Equipment slots (spec §7.3): six of them — weapon, secondary, armor, boots and
## two accessories — filled from `data/items.json`, with one aggregation helper
## behind every total. Pins that all six slots exist and start empty, that one
## item per slot produces exactly the sum of the data values, that accessories
## take the free slot and then resolve to `accessory_1` without ever dropping an
## item out of the inventory, that `equip` refuses a non-equipment item, an item
## that is not carried and an item naming a slot the game does not have, that
## unequipping each slot gives the previous totals back, that equipping a second
## time cannot double a bonus, that `speed_bonus` and `resist_bonus` stack with
## the attributes and stop at the 1.3 / 0.6 ceilings, and that a save round-trips
## all six slots while a save written for the old two-slot format gains the four
## missing ones as empty strings instead of losing the two it did have. GameState
## is reset at both ends so no later group inherits worn items.
func _test_equipment_slots() -> void:
	gs.reset()
	qm.reset()

	# --- the six slots exist and are empty by default -------------------------
	_check(gs.EQUIPMENT_SLOTS.size() == 6, "six equipment slots are declared (got %d)" % gs.EQUIPMENT_SLOTS.size())
	_check(gs.EQUIPMENT_SLOTS == ["weapon", "secondary", "armor", "boots", "accessory_1", "accessory_2"],
		"the declared slots are exactly the six of spec §7.3")
	_check(gs.equipment.size() == 6, "the equipment dictionary holds exactly six keys (got %d)" % gs.equipment.size())
	_check(_slots_all_empty(), "every slot exists and is empty after reset")
	_check(gs.equipped_count() == 0, "nothing is worn after reset")
	_check(gs.total_attack() == gs.base_attack and gs.total_defense() == gs.base_defense,
		"empty slots leave attack and defense at their base")
	_check(gs.total_bonus("attack") == 0 and gs.total_bonus("defense") == 0,
		"the aggregation helper returns 0 with nothing worn")
	_check(gs.total_bonus("not_a_stat") == 0, "an unknown item field aggregates to 0")

	# --- one item per slot: the totals are the exact sums ---------------------
	var per_slot := {
		"weapon": "iron_sword",
		"secondary": "wooden_shield",
		"armor": "leather_armor",
		"boots": "leather_boots",
		"accessory_1": "swift_ring",
		"accessory_2": "echo_amulet",
	}
	var expected_attack: int = gs.base_attack
	var expected_defense: int = gs.base_defense
	for item_id: String in per_slot.values():
		gs.add_item(item_id, 1)
		var def := ItemDB.get_item(item_id)
		_check(String(def.get("type", "")) == "equipment", "%s is typed equipment" % item_id)
		expected_attack += int(def.get("attack", 0))
		expected_defense += int(def.get("defense", 0))
	_check(gs.inventory.size() == 6, "six equipment stacks in the inventory (got %d)" % gs.inventory.size())
	_check(expected_defense == 8, "the six items carry 8 defense between them (got %d)" % expected_defense)
	# The shield, ring and amulet gate behind endurance 6 / agility 8 / intelligence
	# 7 (spec §7.3), so invest before wearing them.
	_spend_to_meet_loadout()
	_check(_equip_all(per_slot), "each of the six items equips into its own slot")
	_check(_slots_match(per_slot), "all six slots hold the item that was put in them")
	_check(gs.equipped_count() == 6, "all six slots report as worn")
	_check(gs.total_attack() == expected_attack,
		"total_attack is the base plus every equipped attack term (%d, expected %d)" % [gs.total_attack(), expected_attack])
	_check(gs.total_defense() == expected_defense,
		"total_defense sums defense across ALL six slots (%d, expected %d)" % [gs.total_defense(), expected_defense])
	_check(gs.total_bonus("attack") == 6, "only the weapon contributes attack (got %d)" % gs.total_bonus("attack"))
	_check(gs.total_bonus("defense") == expected_defense,
		"total_bonus is the single aggregation behind total_defense (got %d)" % gs.total_bonus("defense"))
	_check(gs.equipped_slot_of("wooden_shield") == "secondary",
		"the shield is found in secondary, not in weapon or armor")
	_check(gs.equipped_slot_of("echo_amulet") == "accessory_2",
		"the amulet is found in the second accessory slot")
	_check(gs.equipped_slot_of("health_potion") == "", "an item that is not worn reports no slot")
	var kept := true
	for item_id: String in per_slot.values():
		if gs.count_item(item_id) < 1:
			kept = false
	_check(kept, "equipping never consumes an item: all six are still in the inventory")

	# --- accessories: free slot first, then accessory_1 -----------------------
	gs.reset()
	gs.add_item("swift_ring", 1)
	gs.add_item("echo_amulet", 1)
	# The ring needs agility 8 and the amulet intelligence 7 before either equips.
	_spend_to_meet_loadout()
	_check(gs.equip("swift_ring"), "the first accessory equips")
	_check(String(gs.equipment.get("accessory_1", "")) == "swift_ring",
		"the first accessory takes accessory_1")
	_check(gs.equip("echo_amulet"), "the second accessory equips")
	_check(String(gs.equipment.get("accessory_2", "")) == "echo_amulet",
		"the second accessory takes the free accessory_2 instead of replacing accessory_1")
	_check(gs.count_item("swift_ring") == 1 and gs.count_item("echo_amulet") == 1,
		"neither accessory left the inventory while being worn")
	_check(gs.total_bonus("speed_bonus") == 8, "only the ring contributes speed (got %d)" % gs.total_bonus("speed_bonus"))
	_check(gs.total_bonus("defense") == 1, "only the amulet contributes defense (got %d)" % gs.total_bonus("defense"))
	# Re-wearing an item that is already worn must not put it in the other
	# accessory slot as well: one ring cannot be counted twice.
	_check(gs.equip("swift_ring"), "re-wearing a worn accessory still succeeds")
	_check(gs.equipped_slot_of("swift_ring") == "accessory_1",
		"a worn accessory is never duplicated into the other accessory slot")
	_check(gs.total_bonus("speed_bonus") == 8, "re-wearing the ring did not double its bonus (got %d)" % gs.total_bonus("speed_bonus"))
	# Both accessory slots occupied by something the incoming item is not: the
	# rule is to replace accessory_1. A save can legitimately hold an id the data
	# no longer knows about, which is how this state is built here without
	# inventing a third accessory item that the spec does not list.
	gs.equipment["accessory_1"] = "ghost_ring"
	_check(gs.equip("swift_ring"), "with both accessory slots full the equip still succeeds")
	_check(String(gs.equipment.get("accessory_1", "")) == "swift_ring",
		"a full pair of accessory slots replaces accessory_1")
	_check(String(gs.equipment.get("accessory_2", "")) == "echo_amulet",
		"that replacement leaves accessory_2 alone")
	_check(gs.count_item("swift_ring") == 1 and gs.count_item("echo_amulet") == 1,
		"the replacement lost no item from the inventory")
	_check(gs.total_bonus("defense") == 1,
		"an id the data does not know contributes nothing (got %d)" % gs.total_bonus("defense"))

	# --- equip refuses what it must -------------------------------------------
	gs.reset()
	gs.add_item("health_potion", 1)
	gs.add_item("wolf_fang", 1)
	gs.add_item("rusted_seal", 1)
	_check(not gs.equip("health_potion"), "a consumable is refused by equip")
	_check(not gs.equip("wolf_fang"), "a material is refused by equip")
	_check(not gs.equip("rusted_seal"), "a quest item is refused by equip")
	_check(not gs.equip("no_such_item"), "an unknown item id is refused by equip")
	_check(not gs.equip("iron_sword"), "an item that is not in the inventory is refused")
	_check(gs.equipment.size() == 6 and _slots_all_empty(),
		"every refusal left all six slots empty and added no key")
	_check(gs.equipped_count() == 0, "a refused equip wears nothing")
	# An item whose data names a slot the game does not have must be refused too,
	# rather than quietly create a seventh slot nothing aggregates. The entry is
	# injected into the already-loaded item cache and removed again, because no
	# shipped item is that wrong.
	var item_cache: Dictionary = ItemDB.all_items()
	item_cache["bogus_helmet"] = {"name": "Шлем ниоткуда", "type": "equipment", "slot": "head", "defense": 9}
	gs.add_item("bogus_helmet", 1)
	_check(not gs.equip("bogus_helmet"), "an item naming a slot outside the six is refused")
	_check(gs.equipment.size() == 6, "a refused slot name never becomes a seventh key")
	item_cache.erase("bogus_helmet")
	gs.reset()
	gs.add_item("iron_sword", 1)
	_check(gs.equip("iron_sword"), "the same weapon equips once it is carried")

	# --- unequipping each slot gives the previous totals back -----------------
	gs.reset()
	for item_id: String in per_slot.values():
		gs.add_item(item_id, 1)
	_spend_to_meet_loadout()
	_check(_equip_all(per_slot), "rebuilt the full six-slot loadout")
	_check(gs.total_attack() == expected_attack and gs.total_defense() == expected_defense,
		"the rebuilt loadout reads the same totals (%d/%d)" % [gs.total_attack(), gs.total_defense()])
	var walk_ok := true
	for slot: String in gs.EQUIPMENT_SLOTS:
		var item_id := String(gs.equipment.get(slot, ""))
		var def := ItemDB.get_item(item_id)
		var attack_before: int = gs.total_attack()
		var defense_before: int = gs.total_defense()
		if not gs.unequip(slot):
			walk_ok = false
			continue
		if gs.total_attack() != attack_before - int(def.get("attack", 0)):
			walk_ok = false
		if gs.total_defense() != defense_before - int(def.get("defense", 0)):
			walk_ok = false
		if gs.equipped_slot_of(item_id) != "":
			walk_ok = false
	_check(walk_ok, "unequipping each slot drops exactly that item's terms and nothing else")
	_check(gs.total_attack() == gs.base_attack,
		"unequipping all six returns attack to the base (got %d)" % gs.total_attack())
	_check(gs.total_defense() == gs.base_defense,
		"unequipping all six returns defense to the base (got %d)" % gs.total_defense())
	_check(gs.equipped_count() == 0 and _slots_all_empty(), "all six slots are empty again")
	_check(not gs.unequip("weapon"), "unequipping an already-empty slot is a no-op")
	_check(not gs.unequip("head"), "an unknown slot name is refused by unequip")
	_check(not gs.unequip("accessory"), "the data-level accessory name is not itself a slot")

	# --- equip -> unequip -> equip cannot double anything ---------------------
	_check(_equip_all(per_slot), "equipped the loadout for the cycle")
	var full_cycle := _equipment_snapshot()
	for slot: String in gs.EQUIPMENT_SLOTS:
		gs.unequip(slot)
	_check(_slots_all_empty(), "the cycle took the whole loadout off")
	_check(_equip_all(per_slot), "the cycle put the whole loadout back on")
	_check(_equipment_snapshot() == full_cycle,
		"equip -> unequip -> equip produced identical numbers (%s)" % [full_cycle])
	_check(_equip_all(per_slot), "equipping the whole loadout again succeeds")
	_check(_equipment_snapshot() == full_cycle, "equipping everything a second time changes nothing")
	_check(gs.total_attack() == expected_attack and gs.total_defense() == expected_defense,
		"the repeated passes still read the exact sums (%d/%d)" % [gs.total_attack(), gs.total_defense()])
	_check(gs.equipment.size() == 6, "no pass invented a seventh slot")

	# --- speed_bonus stacks with agility and stops at the ceiling -------------
	gs.reset()
	gs.add_item("leather_boots", 1)
	gs.add_item("swift_ring", 1)
	_check(absf(gs.move_speed_multiplier() - 1.0) < 0.0001, "no speed bonus with nothing worn")
	gs.equip("leather_boots")
	_check(absf(gs.move_speed_multiplier() - 1.05) < 0.0001,
		"the boots' 5 percent is additive on the 1.0 base (got %.4f)" % gs.move_speed_multiplier())
	# The ring now gates behind agility 8. Lift agility just long enough to wear
	# it, then drop straight back to 5 so the equipment-stacking arithmetic below
	# still measures at the agility-5 baseline — the ring stays worn, because
	# nothing unequips an item when a requirement is no longer met.
	gs.attributes["agility"] = 8
	gs.recompute_derived()
	gs.equip("swift_ring")
	gs.attributes["agility"] = 5
	gs.recompute_derived()
	_check(String(gs.equipment.get("accessory_1", "")) == "swift_ring", "the ring went into accessory_1")
	_check(absf(gs.move_speed_multiplier() - 1.13) < 0.0001,
		"boots and ring add their 13 percent together (got %.4f)" % gs.move_speed_multiplier())
	gs.attribute_points = 1
	gs.spend_attribute_point("agility")
	_check(absf(gs.move_speed_multiplier() - 1.138) < 0.0001,
		"one agility point adds its 0.8 percent on top of the equipment (got %.4f)" % gs.move_speed_multiplier())
	gs.attributes["agility"] = 30
	gs.recompute_derived()
	_check(absf(gs.move_speed_multiplier() - 1.3) < 0.0001,
		"agility 30 plus 13 percent equipment is held at the 1.3 ceiling (got %.4f)" % gs.move_speed_multiplier())
	gs.attributes["agility"] = 5
	gs.recompute_derived()
	_check(absf(gs.move_speed_multiplier() - 1.13) < 0.0001,
		"the equipment bonus survives the agility round-trip (got %.4f)" % gs.move_speed_multiplier())
	gs.unequip("boots")
	gs.unequip("accessory_1")
	_check(absf(gs.move_speed_multiplier() - 1.0) < 0.0001,
		"taking both speed items off returns the multiplier to 1.0 (got %.4f)" % gs.move_speed_multiplier())

	# --- resist_bonus stacks with endurance and stops at the ceiling ----------
	gs.reset()
	gs.add_item("echo_amulet", 1)
	_check(absf(gs.control_resistance()) < 0.0001, "no control resistance with nothing worn")
	# The amulet gates behind intelligence 7; control resistance is endurance-based,
	# so investing in intelligence meets the gate without moving the number below.
	gs.attribute_points = 2
	gs.spend_attribute_point("intelligence")
	gs.spend_attribute_point("intelligence")
	_check(gs.equip("echo_amulet"), "the amulet equips")
	_check(absf(gs.control_resistance() - 0.1) < 0.0001,
		"the amulet's 10 percent is additive on the endurance base (got %.4f)" % gs.control_resistance())
	gs.attribute_points = 1
	gs.spend_attribute_point("endurance")
	_check(absf(gs.control_resistance() - 0.12) < 0.0001,
		"one endurance point adds its 2 percent on top of the amulet (got %.4f)" % gs.control_resistance())
	gs.attributes["endurance"] = 30
	gs.recompute_derived()
	_check(absf(gs.control_resistance() - 0.6) < 0.0001,
		"endurance 30 plus 10 percent equipment sits on the 0.6 ceiling (got %.4f)" % gs.control_resistance())
	gs.attributes["endurance"] = 200
	gs.recompute_derived()
	_check(absf(gs.control_resistance() - 0.6) < 0.0001,
		"an out-of-range endurance never pushes control resistance past 0.6 (got %.4f)" % gs.control_resistance())
	gs.attributes["endurance"] = 5
	gs.recompute_derived()
	gs.unequip("accessory_1")
	_check(absf(gs.control_resistance()) < 0.0001,
		"taking the amulet off returns control resistance to 0 (got %.4f)" % gs.control_resistance())

	# --- all six slots survive a save round-trip ------------------------------
	gs.reset()
	for item_id: String in per_slot.values():
		gs.add_item(item_id, 1)
	# Wear the gated loadout, then drop the attributes back to the starting
	# 5/5/5/5 before saving: a save may legitimately hold a loadout the starting
	# attributes could not re-wear (the gate is only at equip time), and the
	# restored player must then still measure at the agility-5 / endurance-5
	# baseline the checks below assert.
	gs.attributes["endurance"] = 6
	gs.attributes["agility"] = 8
	gs.attributes["intelligence"] = 7
	gs.recompute_derived()
	_check(_equip_all(per_slot), "equipped the loadout for the round-trip")
	gs.attributes["endurance"] = 5
	gs.attributes["agility"] = 5
	gs.attributes["intelligence"] = 5
	gs.recompute_derived()
	var saved: Dictionary = gs.to_dict()
	_check(saved.get("equipment") is Dictionary, "to_dict writes an equipment block")
	var saved_equipment: Dictionary = saved.get("equipment", {})
	_check(saved_equipment.size() == 6, "to_dict writes all six slots (got %d)" % saved_equipment.size())
	gs.reset()
	_check(gs.equipped_count() == 0, "reset cleared the slots before the restore")
	gs.from_dict(saved)
	_check(_slots_match(per_slot), "from_dict restores all six slots")
	_check(gs.total_attack() == expected_attack and gs.total_defense() == expected_defense,
		"the restored loadout fights the same (%d/%d)" % [gs.total_attack(), gs.total_defense()])
	_check(absf(gs.move_speed_multiplier() - 1.13) < 0.0001,
		"the restore recomputes the speed bonus from the slots (got %.4f)" % gs.move_speed_multiplier())
	_check(absf(gs.control_resistance() - 0.1) < 0.0001,
		"the restore recomputes the control resistance from the slots (got %.4f)" % gs.control_resistance())

	# --- the old two-slot save format loads without a schema bump -------------
	gs.reset()
	gs.from_dict({"equipment": {"weapon": "iron_sword", "armor": "leather_armor"}})
	_check(String(gs.equipment.get("weapon", "")) == "iron_sword", "a two-slot save keeps its weapon")
	_check(String(gs.equipment.get("armor", "")) == "leather_armor", "a two-slot save keeps its armor")
	_check(gs.equipment.size() == 6,
		"a restored old save ends up with exactly six keys (got %d)" % gs.equipment.size())
	var gained_ok := true
	for slot: String in ["secondary", "boots", "accessory_1", "accessory_2"]:
		if String(gs.equipment.get(slot, "<missing>")) != "":
			gained_ok = false
	_check(gained_ok, "the four slots an old save never wrote come back as empty strings")
	_check(gs.total_attack() == gs.base_attack + 6,
		"the restored old weapon still attacks (got %d)" % gs.total_attack())
	_check(gs.total_defense() == gs.base_defense + 3,
		"the restored old armor still defends (got %d)" % gs.total_defense())
	# The shield gates behind endurance 6, so invest the one point it needs before
	# wearing it (spending endurance never moves attack or the base defense).
	gs.attribute_points = 1
	gs.spend_attribute_point("endurance")
	gs.add_item("wooden_shield", 1)
	_check(gs.equip("wooden_shield"), "a save restored from the old format gains the new slots")
	_check(String(gs.equipment.get("secondary", "")) == "wooden_shield",
		"the shield lands in the slot the old save never had")
	# A save whose equipment block is not a dictionary at all must still leave a
	# usable six-slot player rather than a half-built dictionary.
	var junk_ok := true
	for junk: Variant in [null, "weapon", 7, [], true]:
		gs.from_dict({"equipment": junk})
		if gs.equipment.size() != 6 or gs.equipped_count() != 0:
			junk_ok = false
	_check(junk_ok, "a non-dictionary equipment block still yields six empty slots")
	# A key that is not one of the six is dropped rather than carried, because
	# nothing aggregates it and the HUD would show a slot it cannot clear.
	gs.reset()
	gs.from_dict({"equipment": {"weapon": "iron_sword", "head": "bogus_helmet"}})
	_check(gs.equipment.size() == 6, "an unknown slot in a save is not carried into the six")
	_check(not gs.equipment.has("head"), "the unknown slot key is dropped")
	_check(String(gs.equipment.get("weapon", "")) == "iron_sword",
		"dropping the unknown key keeps the known one")

	# --- leave no residue for later groups ------------------------------------
	gs.reset()
	qm.reset()
	completed["equipment_slots"] = true


## Rarity, icons, sources and attribute requirements (spec §7.3 / §14.1): every
## item carries a valid rarity plus a non-empty icon and source; the five tiers
## map to five distinct colours with a sane fallback that is not one of them; and
## the equip gate refuses an item whose attribute requirement is unmet, naming the
## exact required value through `equip_blocker()` while leaving all six slots and
## the inventory untouched. Meeting the requirement (spending to strength 7) lets
## the spear on; a non-equipment item is still refused for the existing reason.
## GameState is reset at both ends so no later group inherits raised attributes.
func _test_item_rarity() -> void:
	gs.reset()
	qm.reset()

	# --- every item is fully described (spec §14.1) ---------------------------
	var valid_rarities := ["common", "uncommon", "rare", "epic", "legendary"]
	var all := ItemDB.all_items()
	var described_ok := true
	var bad_ids: PackedStringArray = []
	for item_id: String in all.keys():
		var def: Dictionary = all[item_id]
		var tier := String(def.get("rarity", ""))
		var icon := String(def.get("icon", ""))
		var source := String(def.get("source", ""))
		if tier == "" or not valid_rarities.has(tier) or icon == "" or source == "":
			described_ok = false
			bad_ids.append(item_id)
	_check(not all.is_empty(), "the item table is not empty")
	_check(described_ok, "every item has a non-empty valid rarity, icon and source (bad: %s)" % ", ".join(bad_ids))

	# --- the assigned rarities match the spec ---------------------------------
	_check(ItemDB.rarity("iron_sword") == "uncommon", "iron_sword is uncommon")
	_check(ItemDB.rarity("iron_spear") == "uncommon", "iron_spear is uncommon")
	_check(ItemDB.rarity("leather_armor") == "common", "leather_armor is common")
	_check(ItemDB.rarity("wooden_shield") == "common", "wooden_shield is common")
	_check(ItemDB.rarity("leather_boots") == "common", "leather_boots is common")
	_check(ItemDB.rarity("swift_ring") == "rare", "swift_ring is rare")
	_check(ItemDB.rarity("echo_amulet") == "rare", "echo_amulet is rare")
	_check(ItemDB.rarity("health_potion") == "common", "health_potion is common")
	_check(ItemDB.rarity("mana_potion") == "common", "mana_potion is common")
	_check(ItemDB.rarity("wolf_fang") == "common", "wolf_fang is common")

	# --- rarity colour: five distinct tiers + a sane fallback -----------------
	var seen_colors: Array[Color] = []
	var distinct := true
	for tier: String in valid_rarities:
		var c := ItemDB.rarity_color(tier)
		for prior in seen_colors:
			if prior == c:
				distinct = false
		seen_colors.append(c)
	_check(distinct, "the five rarities map to five distinct colours")
	_check(ItemDB.rarity_color("common") != ItemDB.rarity_color("legendary"),
		"common and legendary are clearly different colours")
	var fallback := ItemDB.rarity_color("not_a_rarity")
	var collides := false
	for c in seen_colors:
		if fallback == c:
			collides = true
	_check(not collides, "an unknown rarity falls back to a colour distinct from every tier")
	_check(ItemDB.rarity("no_such_item") == "common", "an unknown item reads as common rarity")

	# --- icon / source / requirement accessors --------------------------------
	_check(ItemDB.icon("iron_sword") != "" and ItemDB.icon("iron_sword") != "?",
		"iron_sword has a real icon glyph")
	_check(ItemDB.icon("no_such_item") == "?", "an unknown item falls back to the ? icon")
	_check(ItemDB.source("iron_spear") != "", "iron_spear names a source")
	_check(ItemDB.requirements("health_potion").is_empty(), "a consumable has no requirements")

	# --- equip_blocker at the starting attributes -----------------------------
	gs.add_item("iron_sword", 1)
	_check(gs.equip_blocker("iron_sword") == "",
		"iron_sword has no blocker at the starting strength 5")
	gs.add_item("iron_spear", 1)
	var spear_blocker: String = String(gs.equip_blocker("iron_spear"))
	_check(spear_blocker != "", "iron_spear is blocked at strength 5")
	_check(spear_blocker.contains("7"), "the spear blocker names the required value 7 (%s)" % spear_blocker)

	# --- the refused spear equip changes nothing ------------------------------
	var inv_before: Array = gs.inventory.duplicate(true)
	_check(not gs.equip("iron_spear"), "the spear is refused by equip at strength 5")
	_check(_slots_all_empty(), "the refused spear equip left all six slots empty")
	_check(gs.equipment.size() == 6, "the refused spear equip added no slot")
	_check(gs.inventory == inv_before, "the refused spear equip left the inventory untouched")
	_check(String(gs.equipment.get("weapon", "")) != "iron_spear", "the spear never entered the weapon slot")

	# --- spending to strength 7 lets the spear on -----------------------------
	gs.attribute_points = 2
	gs.spend_attribute_point("strength")
	gs.spend_attribute_point("strength")
	_check(gs.attribute("strength") == 7, "strength is 7 after two points")
	_check(gs.equip_blocker("iron_spear") == "", "the spear blocker clears at strength 7")
	_check(gs.equip("iron_spear"), "the spear equips once strength reaches 7")
	_check(String(gs.equipment.get("weapon", "")) == "iron_spear", "the spear is now worn in weapon")

	# --- the amulet gates behind intelligence 7 -------------------------------
	gs.reset()
	gs.add_item("echo_amulet", 1)
	_check(gs.equip_blocker("echo_amulet").contains("7"),
		"the amulet blocker names the required intelligence 7 at the start")
	_check(not gs.equip("echo_amulet"), "the amulet is refused at intelligence 5")
	_check(_slots_all_empty(), "the refused amulet equip left every slot empty")

	# --- a non-equipment item is refused for the existing reason --------------
	gs.reset()
	gs.add_item("health_potion", 1)
	_check(not gs.equip("health_potion"), "a consumable is still refused by equip")
	_check(gs.equip_blocker("health_potion") != "",
		"equip_blocker still returns a reason for a non-equipment item")
	_check(_slots_all_empty(), "a consumable never enters a slot")

	# --- lookups are stable and a save round-trip never moves equipment -------
	# icon/rarity live in the data, not in a save, so they cannot drift; assert the
	# lookups are stable and that a round-trip leaves the worn set identical.
	var icon_a := ItemDB.icon("iron_sword")
	var rarity_a := ItemDB.rarity("iron_sword")
	_check(ItemDB.icon("iron_sword") == icon_a and ItemDB.rarity("iron_sword") == rarity_a,
		"ItemDB icon/rarity lookups are stable across calls")
	gs.reset()
	gs.add_item("iron_sword", 1)
	_check(gs.equip("iron_sword"), "sword equipped for the round-trip")
	var worn_before: Dictionary = gs.equipment.duplicate(true)
	gs.from_dict(gs.to_dict())
	_check(gs.equipment == worn_before, "a save round-trip does not change the worn equipment")
	_check(ItemDB.icon("iron_sword") == icon_a and ItemDB.rarity("iron_sword") == rarity_a,
		"a save round-trip does not change the item's icon or rarity")

	gs.reset()
	qm.reset()
	completed["item_rarity"] = true


## True when every declared slot exists in the dictionary and holds an empty
## string — the shape a fresh or freshly restored GameState must always have.
func _slots_all_empty() -> bool:
	for slot: String in gs.EQUIPMENT_SLOTS:
		if not gs.equipment.has(slot) or String(gs.equipment[slot]) != "":
			return false
	return true


## Equips one item per declared slot through the real equip() path.
func _equip_all(items_by_slot: Dictionary) -> bool:
	var ok := true
	for slot: String in items_by_slot.keys():
		if not gs.equip(String(items_by_slot[slot])):
			ok = false
	return ok


## Spend points to reach the values the gated equipment asks for (endurance 6,
## agility 8, intelligence 7), leaving strength at 5. The shield, ring and amulet
## now gate behind those (spec §7.3), so the sections that equip the full loadout
## through the real equip() gate must invest first — the requirement stays in the
## data, the test meets it rather than removing it. Strength is left at 5 so the
## attack/defense arithmetic the surrounding checks assert is unchanged.
func _spend_to_meet_loadout() -> void:
	gs.attribute_points = 6
	gs.spend_attribute_point("endurance")
	for _i in range(3):
		gs.spend_attribute_point("agility")
	for _i in range(2):
		gs.spend_attribute_point("intelligence")


## True when each declared slot holds exactly the item the caller expects.
func _slots_match(items_by_slot: Dictionary) -> bool:
	for slot: String in items_by_slot.keys():
		if String(gs.equipment.get(slot, "")) != String(items_by_slot[slot]):
			return false
	return true


## Every number the equipment can move, so a round-trip can be compared as one
## value instead of one assertion per field.
func _equipment_snapshot() -> Dictionary:
	return {
		"attack": gs.total_attack(),
		"defense": gs.total_defense(),
		"speed": gs.move_speed_multiplier(),
		"resist": gs.control_resistance(),
		"speed_bonus": gs.total_bonus("speed_bonus"),
		"resist_bonus": gs.total_bonus("resist_bonus"),
	}


## Character screen (spec §7.1 UI): C opens and closes it, the modal gate keeps
## the player still while it is open, E spends a point on the selected attribute
## through the real GameState path, the refusals (empty pool, per-attribute cap)
## toast and change nothing, the panel and the inventory are never open at the
## same time, and Esc closes the panel instead of pausing. Driven through real
## key events like every UI group. GameState, the pause tree, ui_blocking and
## the scene are reset at both ends so no later group inherits an open panel.
func _test_character_panel() -> void:
	gs.reset()
	qm.reset()
	paused = false

	_check(InputMap.has_action(&"character"), "character action exists")
	_check(_action_has_key("character", KEY_C), "character action is bound to key C")

	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var hud := scene.get_node_or_null("HUD")
	var player := get_first_node_in_group("player") as Node2D
	_check(hud != null and player != null, "hud and player present for character panel test")
	if hud == null or player == null:
		gs.ui_blocking = false
		paused = false
		gs.reset()
		completed["character_panel"] = true
		return

	# --- C opens the panel and the modal gate holds --------------------------
	await _tap_key(KEY_C)
	_check(bool(hud.call("is_character_open")), "key C opens the character panel")
	_check(gs.ui_blocking, "ui_blocking is true while the character panel is open")
	var before := player.global_position
	var d_down := InputEventKey.new()
	d_down.physical_keycode = KEY_D
	d_down.keycode = KEY_D
	d_down.pressed = true
	Input.parse_input_event(d_down)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) < 2.0, "character panel open blocks movement")
	var d_up := InputEventKey.new()
	d_up.physical_keycode = KEY_D
	d_up.keycode = KEY_D
	d_up.pressed = false
	Input.parse_input_event(d_up)
	await physics_frame

	# --- C again closes it -----------------------------------------------------
	await _tap_key(KEY_C)
	_check(not bool(hud.call("is_character_open")), "key C again closes the character panel")
	_check(not gs.ui_blocking, "ui_blocking cleared after closing the character panel")

	# --- move_down then E spends one point on agility --------------------------
	gs.attribute_points = 2
	var crit_before: float = gs.crit_chance()
	await _tap_key(KEY_C)
	await _tap_key(KEY_S)
	await _tap_key(KEY_E)
	_check(gs.attribute_points == 1, "E spends exactly one point (points=%d)" % gs.attribute_points)
	_check(gs.attribute("agility") == 6, "the point landed in agility (got %d)" % gs.attribute("agility"))
	_check(gs.attribute("strength") == 5, "the cursor moved: strength kept its 5")
	_check(gs.crit_chance() > crit_before, "agility raised the crit chance through the panel (%.4f)" % gs.crit_chance())

	# --- E with an empty pool spends nothing and toasts ------------------------
	gs.attribute_points = 0
	var toasts: Array[String] = []
	var listener := func(message: String) -> void: toasts.append(message)
	bus.toast.connect(listener)
	await _tap_key(KEY_E)
	_check(gs.attribute_points == 0, "E with no points spends nothing")
	_check(gs.attribute("agility") == 6, "a refused spend leaves the attribute untouched")
	_check(toasts.has("Нет очков"), "E with no points toasts Нет очков")

	# --- E at the attribute cap spends nothing ---------------------------------
	gs.attribute_points = 3
	gs.attributes["agility"] = 30
	gs.recompute_derived()
	toasts.clear()
	await _tap_key(KEY_E)
	_check(gs.attribute_points == 3, "E at the cap spends no point (points=%d)" % gs.attribute_points)
	_check(gs.attribute("agility") == 30, "a spend at the cap leaves the attribute at 30")
	_check(toasts.has("Предел характеристики"), "E at the cap toasts Предел характеристики")
	bus.toast.disconnect(listener)

	# --- the panel and the inventory are never both open -----------------------
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_inventory_open")), "I opens the inventory while the panel is open")
	_check(not bool(hud.call("is_character_open")), "opening the inventory closed the character panel")
	await _tap_key(KEY_C)
	_check(bool(hud.call("is_character_open")), "C opens the character panel again")
	_check(not bool(hud.call("is_inventory_open")), "opening the character panel closed the inventory")
	_check(bool(hud.call("is_character_open")) and not bool(hud.call("is_inventory_open")),
		"the panel and the inventory are never open at once")

	# --- Esc closes the panel and does not pause -------------------------------
	await _tap_key(KEY_ESCAPE)
	_check(not bool(hud.call("is_character_open")), "Esc closes the character panel")
	_check(not gs.ui_blocking, "ui_blocking cleared after Esc closed the panel")
	_check(not paused, "Esc closing the panel does not pause the game")

	# --- leave no residue for later groups -------------------------------------
	if bool(hud.call("is_inventory_open")):
		await _tap_key(KEY_I)
	if bool(hud.call("is_character_open")):
		await _tap_key(KEY_C)
	gs.ui_blocking = false
	paused = false
	scene.queue_free()
	await process_frame
	gs.reset()
	qm.reset()
	completed["character_panel"] = true


## Shop (spec §14.3). Two halves: the pure ShopManager rules run against the live
## GameState with no scene, then the buy/sell panel is driven through the real
## scene and the same InputSource a human uses. The whole point of §14.3 is that a
## trade never half-applies, so every refusal here is checked to leave gold,
## inventory and stock exactly as they were, not merely to return ok=false.
func _test_shop() -> void:
	gs.reset()
	qm.reset()
	paused = false

	# --- pure logic against the live GameState, no scene ---------------------
	var shop = load("res://scripts/shop/shop_manager.gd").new(gs)
	_check(shop.merchant_id() == "yorek", "shop merchant_id is yorek")
	_check(shop.stock_of("health_potion") == 5, "stock health_potion is 5 from data/shop.json")
	_check(shop.stock_of("wooden_shield") == 1, "stock wooden_shield is 1 from data/shop.json")
	_check(shop.buy_price("mana_potion") == 20, "buy price mana_potion is 20")
	_check(shop.sell_price("mana_potion") == 10, "sell price mana_potion is floor(20*0.5)=10")
	_check(shop.sell_price("wolf_fang") == 4, "sell price wolf_fang is floor(8*0.5)=4")

	# buy then sell of the same unit is a net loss, never a gold printer
	gs.gold = 100
	var r: Dictionary = shop.buy("mana_potion", 1)
	_check(bool(r.get("ok")), "buy mana_potion succeeds")
	_check(gs.gold == 80, "buying mana_potion spent 20 (gold=%d)" % gs.gold)
	_check(gs.count_item("mana_potion") == 1, "buying added one mana_potion")
	_check(shop.stock_of("mana_potion") == 2, "stock decremented on buy (got %d)" % shop.stock_of("mana_potion"))
	var s: Dictionary = shop.sell("mana_potion", 1)
	_check(bool(s.get("ok")), "sell mana_potion succeeds")
	_check(gs.gold == 90, "buy then sell is net -10, not a profit (gold=%d)" % gs.gold)
	_check(shop.stock_of("mana_potion") == 2, "selling does not restock the merchant (got %d)" % shop.stock_of("mana_potion"))

	# every refusal reason the spec names
	_check(String(shop.can_buy("nope", 1).get("reason")) == "unknown_item", "can_buy unknown_item")
	_check(String(shop.can_sell("nope", 1).get("reason")) == "unknown_item", "can_sell unknown_item")
	_check(String(shop.can_buy("wooden_shield", 2).get("reason")) == "not_in_stock", "can_buy not_in_stock when stock < amount")
	gs.gold = 0
	_check(String(shop.can_buy("health_potion", 1).get("reason")) == "not_enough_gold", "can_buy not_enough_gold")
	gs.gold = 1000
	gs.add_item("health_potion", 99)
	_check(String(shop.can_buy("health_potion", 1).get("reason")) == "no_space", "can_buy no_space at the 99 stack cap")
	gs.add_item("rusted_seal", 1)
	_check(String(shop.can_sell("rusted_seal", 1).get("reason")) == "quest_item", "can_sell refuses quest items")
	gs.add_item("leather_boots", 1)
	gs.equip("leather_boots")
	_check(String(shop.can_sell("leather_boots", 1).get("reason")) == "equipped_item", "can_sell refuses equipped items")
	_check(String(shop.can_sell("iron_sword", 1).get("reason")) == "not_owned", "can_sell refuses unowned items")

	# Gap 2: a 0-price item must not be an infinite gold printer. The smallest-
	# priced item in the shipped data is rusted_seal (price 0), so its sell price is
	# now 0, not a forced 1, and every sellable (non-quest) item still has value.
	_check(shop.sell_price("rusted_seal") == 0, "sell price of the 0-price rusted_seal is 0, not a forced 1")
	var printer_items: Array[String] = []
	for item_id in ItemDB.all_items():
		if shop.sell_price(String(item_id)) <= 0 and String(ItemDB.get_item(item_id).get("type", "")) != "quest":
			printer_items.append(String(item_id))
	_check(printer_items.is_empty(), "no sellable non-quest item is priced at 0 (would be a gold printer)")

	# the no_value refusal, exercised with a throwaway 0-price item injected into
	# ItemDB's live table for these checks and removed again — data/items.json is
	# never touched. Owning it must not let the player mint gold.
	var tmp_id := "__test_zero_value__"
	var item_table: Dictionary = ItemDB.all_items()
	item_table[tmp_id] = {"name": "Тест", "type": "material", "price": 0}
	gs.add_item(tmp_id, 1)
	_check(shop.sell_price(tmp_id) == 0, "a 0-price item sells for 0")
	_check(String(shop.can_sell(tmp_id, 1).get("reason")) == "no_value", "can_sell refuses a 0-value item with no_value")
	var gold_nv: int = gs.gold
	var cnt_nv: int = gs.count_item(tmp_id)
	var vs: Dictionary = shop.sell(tmp_id, 1)
	_check(not bool(vs.get("ok")), "sell of a 0-value item is refused")
	_check(String(vs.get("reason")) == "no_value", "sell returns no_value for a 0-value item")
	_check(gs.gold == gold_nv and gs.count_item(tmp_id) == cnt_nv, "a refused 0-value sell changes neither gold nor inventory")
	item_table.erase(tmp_id)
	gs.remove_item(tmp_id, cnt_nv)

	# atomicity: a refused buy changes nothing at all
	gs.reset()
	var shop2 = load("res://scripts/shop/shop_manager.gd").new(gs)
	gs.gold = 5
	var g0: int = gs.gold
	var c0: int = gs.count_item("wooden_shield")
	var k0: int = shop2.stock_of("wooden_shield")
	var bad: Dictionary = shop2.buy("wooden_shield", 1)
	_check(not bool(bad.get("ok")), "buy with too little gold is refused")
	_check(gs.gold == g0 and gs.count_item("wooden_shield") == c0 and shop2.stock_of("wooden_shield") == k0,
		"a refused buy leaves gold, inventory and stock untouched")

	# a full stack must not lose or split the item on an overflowing buy
	gs.reset()
	var shop3 = load("res://scripts/shop/shop_manager.gd").new(gs)
	gs.gold = 1000
	gs.add_item("health_potion", 99)
	var overflow: Dictionary = shop3.buy("health_potion", 1)
	_check(not bool(overflow.get("ok")), "buy that would overflow the stack is refused")
	_check(gs.count_item("health_potion") == 99, "the refused overflow left exactly 99, nothing lost or split")
	_check(gs.gold == 1000, "the refused overflow spent no gold")

	# --- the buy/sell panel through the live scene ---------------------------
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var hud := scene.get_node_or_null("HUD")
	var player := get_first_node_in_group("player") as Node2D
	_check(hud != null and player != null, "hud and player present for shop panel test")
	if hud == null or player == null:
		gs.ui_blocking = false
		paused = false
		gs.reset()
		completed["shop"] = true
		return

	# the merchant joins the interactable group without displacing Edrik (the
	# quest bots pick the first interactable, so Edrik must stay first)
	var prompts: Array[String] = []
	var interactables := get_nodes_in_group("interactable")
	for n in interactables:
		if n.has_method("prompt_text"):
			prompts.append(String(n.call("prompt_text")))
	_check(interactables.size() >= 2, "at least two interactables (Edrik and the merchant)")
	_check(interactables.size() > 0 and String(interactables[0].name) == "Edrik",
		"Edrik stays the first interactable so the quest bots never open the shop")
	_check(prompts.has("Торговать"), "a merchant offering Торговать is in the interactable group")

	# --- the real in-game path: E near the merchant opens the shop, buys nothing --
	# Player._process_free calls interact() on the nearest interactable; the merchant
	# must open the panel through that path and must NOT also run a trade on the same
	# frame. Every other shop test opens the panel directly, so this is the only
	# coverage of Merchant.interact -> hud.open_shop.
	var merchant: Node = null
	for n in interactables:
		if n.has_method("prompt_text") and String(n.call("prompt_text")) == "Торговать":
			merchant = n
			break
	_check(merchant != null, "a merchant interactable offering Торговать was found in the group")
	if merchant != null:
		_check(merchant != interactables[0],
			"the merchant is not the first interactable (Edrik stays first so the quest bots never open the shop)")
		gs.gold = 100
		var gold_pre: int = gs.gold
		var inv_size_pre: int = gs.inventory.size()
		var potion_pre: int = gs.count_item("health_potion")
		merchant.call("interact", player)
		await process_frame
		_check(bool(hud.call("is_shop_open")), "Merchant.interact opens the shop through the real path")
		_check(gs.ui_blocking, "Merchant.interact sets ui_blocking")
		_check(gs.gold == gold_pre, "opening the shop via interact spent no gold (got %d)" % gs.gold)
		_check(gs.inventory.size() == inv_size_pre, "opening the shop via interact left the inventory unchanged")
		_check(gs.count_item("health_potion") == potion_pre,
			"the selected row bought nothing on the open frame")
		hud.call("close_shop")
		await process_frame
		_check(not bool(hud.call("is_shop_open")), "close_shop closes the interact-opened shop")
		_check(not gs.ui_blocking, "ui_blocking cleared after closing the interact-opened shop")

	# open the shop through the HUD and check the modal gate
	gs.gold = 100
	hud.call("open_shop_for_shot")
	await process_frame
	_check(bool(hud.call("is_shop_open")), "open_shop opens the shop")
	_check(gs.ui_blocking, "ui_blocking is true while the shop is open")
	var before := player.global_position
	var d_down := InputEventKey.new()
	d_down.physical_keycode = KEY_D
	d_down.keycode = KEY_D
	d_down.pressed = true
	Input.parse_input_event(d_down)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) < 2.0, "shop open blocks player movement")
	var d_up := InputEventKey.new()
	d_up.physical_keycode = KEY_D
	d_up.keycode = KEY_D
	d_up.pressed = false
	Input.parse_input_event(d_up)
	await physics_frame

	# E buys one unit of the selected (first) stock item through the real input path
	var gold_before: int = gs.gold
	var count_before: int = gs.count_item("health_potion")
	await _tap_key(KEY_E)
	_check(gs.gold == gold_before - 25, "E buys one health_potion for 25 (gold %d -> %d)" % [gold_before, gs.gold])
	_check(gs.count_item("health_potion") == count_before + 1, "the bought item entered the inventory")

	# Tab flips to the sell list; E then sells that same unit back
	await _tap_key(KEY_TAB)
	await _tap_key(KEY_E)
	_check(gs.count_item("health_potion") == count_before, "Tab+E sells the unit back (net to the start count)")
	_check(bool(hud.call("is_shop_open")), "the shop stays open after a sell")

	# Esc closes the shop and does not pause the game underneath
	await _tap_key(KEY_ESCAPE)
	_check(not bool(hud.call("is_shop_open")), "Esc closes the shop")
	_check(not gs.ui_blocking, "ui_blocking cleared after Esc closed the shop")
	_check(not paused, "Esc closing the shop does not pause the game")

	# while the shop owns the screen the inventory key is swallowed (modal)
	hud.call("open_shop_for_shot")
	await process_frame
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_shop_open")), "the shop stays open when I is pressed (modal swallows it)")
	_check(not bool(hud.call("is_inventory_open")), "I does not open the inventory while the shop is open")
	await _tap_key(KEY_ESCAPE)

	# opening the shop closes an already-open inventory (mutual exclusivity)
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_inventory_open")), "I opens the inventory when the shop is closed")
	hud.call("open_shop_for_shot")
	await process_frame
	_check(bool(hud.call("is_shop_open")), "open_shop opens the shop over the inventory")
	_check(not bool(hud.call("is_inventory_open")), "opening the shop closed the inventory")

	# leave no residue for later groups
	if bool(hud.call("is_shop_open")):
		hud.call("close_shop")
	if bool(hud.call("is_inventory_open")):
		await _tap_key(KEY_I)
	gs.ui_blocking = false
	paused = false
	scene.queue_free()
	await process_frame
	gs.reset()
	qm.reset()
	completed["shop"] = true


## Crafting (spec §14.4). Three halves, in the order the risk sits in: the pure
## `CraftManager` rules against the live GameState with no scene (including the
## permanent smith upgrade and its idempotency), then the same state through a
## save round-trip, then the bench through the real scene and the same InputSource
## a human uses. Like the shop group, every refusal is checked to leave gold,
## materials and inventory exactly as they were — a craft that half-applies is the
## bug this whole section exists to prevent. GameState, ui_blocking, the pause
## tree, slot 2 and the scene are reset at both ends so no later group inherits an
## open panel, an upgrade or a save.
func _test_craft() -> void:
	gs.reset()
	qm.reset()
	paused = false
	_clear_slot(2)

	# --- pure logic against the live GameState, no scene ---------------------
	var craft = load("res://scripts/craft/craft_manager.gd").new(gs)
	var all_ids: Array = craft.recipe_ids()
	_check(all_ids.size() == 4, "data/recipes.json defines 4 recipes (got %d)" % all_ids.size())
	_check(craft.station_recipes("smith").size() == 2, "the smith bench has 2 recipes")
	_check(craft.station_recipes("herbalist").size() == 2, "the herbalist bench has 2 recipes")
	_check(craft.station_recipes("alchemy").is_empty(), "an unknown station lists no recipe")
	_check(craft.station_recipes("").is_empty(), "no station asks for nothing rather than everything")
	_check(not craft.station_recipes("smith").has("potion_health"),
		"the smith bench does not list the herbalist's recipe")

	# every refusal reason the spec names
	_check(String(craft.can_craft("no_such_recipe").get("reason")) == "unknown_recipe",
		"can_craft unknown_recipe")
	_check(String(craft.craft("no_such_recipe").get("reason")) == "unknown_recipe",
		"craft refuses an unknown recipe")
	_check(not craft.is_unlocked("potion_mana"), "potion_mana starts locked")
	_check(String(craft.can_craft("potion_mana").get("reason")) == "locked", "can_craft locked")
	gs.gold = 4
	gs.add_item("wolf_fang", 4)
	_check(String(craft.can_craft("potion_health").get("reason")) == "not_enough_gold",
		"can_craft not_enough_gold")
	gs.gold = 5
	gs.remove_item("wolf_fang", 4)
	_check(String(craft.can_craft("potion_health").get("reason")) == "missing_material",
		"can_craft missing_material")
	gs.add_item("wolf_fang", 4)
	gs.add_item("health_potion", 99)
	_check(String(craft.can_craft("potion_health").get("reason")) == "no_space",
		"can_craft no_space at the 99 stack cap of the output")

	# a successful craft moves gold, materials and the result in one go
	gs.reset()
	craft = load("res://scripts/craft/craft_manager.gd").new(gs)
	gs.gold = 20
	gs.add_item("wolf_fang", 3)
	var made: Dictionary = craft.craft("potion_health")
	_check(bool(made.get("ok")), "crafting potion_health succeeds")
	_check(gs.gold == 15, "the craft spent exactly its 5 gold (gold=%d)" % gs.gold)
	_check(gs.count_item("wolf_fang") == 1, "the craft consumed exactly 2 claws (got %d)" % gs.count_item("wolf_fang"))
	_check(gs.count_item("health_potion") == 1, "the craft produced the output item")
	_check(String(made.get("output")) == "health_potion", "the result names the produced item")
	_check(int(made.get("gold_spent")) == 5, "the result reports the 5 gold it spent")

	# a failed craft leaves everything it would have touched untouched: the gold is
	# sufficient here, only the claws are not, so a craft that paid before it
	# checked would be caught by exactly these four assertions
	gs.remove_item("wolf_fang", 1)
	var gold_before: int = gs.gold
	var fangs_before: int = gs.count_item("wolf_fang")
	var potions_before: int = gs.count_item("health_potion")
	var inv_before: int = gs.inventory.size()
	var refused: Dictionary = craft.craft("potion_health")
	_check(not bool(refused.get("ok")), "the second craft is refused for want of material")
	_check(String(refused.get("reason")) == "missing_material", "the refusal names missing_material")
	_check(gs.gold == gold_before, "a refused craft spent no gold")
	_check(gs.count_item("wolf_fang") == fangs_before, "a refused craft consumed no material")
	_check(gs.count_item("health_potion") == potions_before, "a refused craft produced nothing")
	_check(gs.inventory.size() == inv_before, "a refused craft left the inventory slots untouched")
	_check(int(refused.get("gold_spent")) == 0, "a refused craft reports zero gold spent")

	# preview is what the panel shows before confirming: fee, need/have, result
	gs.add_item("wolf_fang", 1)
	var info: Dictionary = craft.preview("potion_health")
	_check(String(info.get("name")) == "Настой здоровья", "preview names the recipe")
	_check(int(info.get("gold")) == 5, "preview reports the 5 gold fee")
	_check(String(info.get("output_name")) == "Настой здоровья", "preview names the produced item")
	var preview_materials: Dictionary = info.get("materials", {})
	var fang_entry: Dictionary = preview_materials.get("wolf_fang", {})
	_check(int(fang_entry.get("need", 0)) == 2 and int(fang_entry.get("have", 0)) == 1,
		"preview shows the claw need 2 against the 1 actually held")
	_check(craft.preview("no_such_recipe").get("name") == "", "preview of an unknown recipe is empty")

	# unlock makes a locked recipe craftable, and the unlock is a plain flag so it
	# rides the save file exactly like a quest flag does
	gs.reset()
	craft = load("res://scripts/craft/craft_manager.gd").new(gs)
	gs.gold = 10
	gs.add_item("wolf_fang", 2)
	_check(not bool(craft.craft("potion_mana").get("ok")), "a locked recipe cannot be crafted")
	_check(not craft.unlock("no_such_recipe"), "unlocking an unknown recipe does nothing")
	_check(not craft.unlock("potion_health"), "unlocking a recipe with no flag does nothing")
	_check(craft.unlock("potion_mana"), "unlock reports that it set the flag")
	_check(craft.is_unlocked("potion_mana"), "the recipe is known after unlock")
	_check(bool(craft.craft("potion_mana").get("ok")), "the unlocked recipe crafts")
	_check(gs.count_item("mana_potion") == 1, "the unlocked craft produced the mana potion")
	var save_res: Dictionary = sm.save_game(2)
	_check(bool(save_res.get("ok", false)), "craft group saved slot 2")
	gs.reset()
	_check(not bool(gs.get_flag("recipe_mana_known", false)), "reset cleared the unlock flag")
	var load_res: Dictionary = sm.load_game(2)
	_check(bool(load_res.get("ok", false)), "craft group loaded slot 2")
	_check(bool(gs.get_flag("recipe_mana_known", false)), "the unlock flag survived the round-trip")
	_check(craft.is_unlocked("potion_mana"), "the recipe is still known after the round-trip")
	_check(not craft.is_unlocked("temper_sword"), "the other locked recipe stayed locked")

	# --- the smith upgrade: permanent, exact, idempotent ---------------------
	gs.reset()
	var smith_craft = load("res://scripts/craft/craft_manager.gd").new(gs, "smith")
	gs.set_flag("recipe_temper_known", true)
	gs.gold = 200
	gs.add_item("wolf_fang", 8)
	gs.add_item("iron_sword", 1)
	gs.equip("iron_sword")
	var attack_pre: int = gs.total_attack()
	_check(attack_pre == 11, "an iron sword over strength 5 gives attack 11 (got %d)" % attack_pre)
	var temper: Dictionary = smith_craft.craft("temper_sword")
	_check(bool(temper.get("ok")), "temper_sword crafts once")
	_check(gs.total_attack() == attack_pre + 2,
		"the tempering raises total_attack by exactly 2 while the sword is worn (%d -> %d)" % [attack_pre, gs.total_attack()])
	_check(gs.gold == 170, "the tempering charged its 30 gold (gold=%d)" % gs.gold)
	_check(gs.count_item("wolf_fang") == 5, "the tempering ate its 3 claws (got %d)" % gs.count_item("wolf_fang"))
	_check(gs.count_item("iron_sword") == 2, "the tempering still handed the sword over (got %d)" % gs.count_item("iron_sword"))
	_check(gs.upgrade_bonus("iron_sword", "attack") == 2, "the stored upgrade is +2 attack")

	# the second attempt is refused outright, before a coin or a claw moves
	var gold_2: int = gs.gold
	var fangs_2: int = gs.count_item("wolf_fang")
	var swords_2: int = gs.count_item("iron_sword")
	var attack_2: int = gs.total_attack()
	var again: Dictionary = smith_craft.craft("temper_sword")
	_check(not bool(again.get("ok")), "the same tempering cannot be crafted twice")
	_check(String(again.get("reason")) == "already_upgraded", "the second attempt is refused as already_upgraded")
	_check(String(smith_craft.can_craft("temper_sword").get("reason")) == "already_upgraded",
		"can_craft answers already_upgraded before the costs")
	_check(gs.gold == gold_2, "the refused second tempering spent no gold")
	_check(gs.count_item("wolf_fang") == fangs_2, "the refused second tempering ate no claws")
	_check(gs.count_item("iron_sword") == swords_2, "the refused second tempering produced no sword")
	_check(gs.total_attack() == attack_2, "the refused second tempering added no bonus")

	# the upgrade is permanent: it rides the save, and taking the sword off and on
	# again must not stack it, because total_bonus rebuilds from the slots
	var save_2: Dictionary = sm.save_game(2)
	_check(bool(save_2.get("ok", false)), "upgrade round-trip saved slot 2")
	gs.reset()
	var load_2: Dictionary = sm.load_game(2)
	_check(bool(load_2.get("ok", false)), "upgrade round-trip loaded slot 2")
	_check(gs.total_attack() == attack_2, "the tempering survived the round-trip (%d)" % gs.total_attack())
	gs.unequip("weapon")
	_check(gs.total_attack() == 5, "taking the sword off leaves only the base attack")
	gs.equip("iron_sword")
	_check(gs.total_attack() == attack_2, "re-equipping does not double the tempering (%d)" % gs.total_attack())
	gs.equip("iron_sword")
	_check(gs.total_attack() == attack_2, "equipping twice in a row still does not double it")
	_check(smith_craft.is_unlocked("temper_sword"),
		"the unlock flag the tempering needed rode the same save round-trip")

	# the armor recipe is unlocked from the start and upgrades defense instead
	gs.reset()
	smith_craft = load("res://scripts/craft/craft_manager.gd").new(gs, "smith")
	gs.gold = 100
	gs.add_item("wolf_fang", 4)
	gs.add_item("leather_armor", 1)
	gs.equip("leather_armor")
	var defense_pre: int = gs.total_defense()
	_check(smith_craft.is_unlocked("reinforce_armor"), "reinforce_armor needs no unlock flag")
	_check(bool(smith_craft.craft("reinforce_armor").get("ok")), "reinforce_armor crafts")
	_check(gs.total_defense() == defense_pre + 1,
		"the reinforcement raises total_defense by exactly 1 (%d -> %d)" % [defense_pre, gs.total_defense()])
	_check(String(smith_craft.can_craft("reinforce_armor").get("reason")) == "already_upgraded",
		"the armor cannot be reinforced twice either")

	# --- the bench through the live scene ------------------------------------
	gs.reset()
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var hud := scene.get_node_or_null("HUD")
	var player := get_first_node_in_group("player") as Node2D
	_check(hud != null and player != null, "hud and player present for craft panel test")
	if hud == null or player == null:
		gs.ui_blocking = false
		paused = false
		_clear_slot(2)
		gs.reset()
		completed["craft"] = true
		return

	# the smith joins the interactable group without displacing Edrik, and he is
	# far enough away that standing at Edrik never reaches him
	var interactables := get_nodes_in_group("interactable")
	var prompts: Array[String] = []
	for n in interactables:
		if n.has_method("prompt_text"):
			prompts.append(String(n.call("prompt_text")))
	_check(interactables.size() >= 3, "at least three interactables (Edrik, Yorek, Bran)")
	_check(String(interactables[0].name) == "Edrik",
		"Edrik stays the first interactable so the quest bots never open the bench")
	_check(prompts.has("Ремесло"), "a station offering Ремесло is in the interactable group")

	var smith: Node = null
	for n in interactables:
		if n.has_method("prompt_text") and String(n.call("prompt_text")) == "Ремесло":
			smith = n
			break
	_check(smith != null, "the smith interactable was found in the group")
	if smith != null:
		_check(smith != interactables[0], "the smith is not the first interactable")
		var smith_2d := smith as Node2D
		var edrik := interactables[0] as Node2D
		_check(smith_2d != null and edrik != null
				and smith_2d.global_position.distance_to(edrik.global_position) > 44.0,
			"the forge sits outside the interact radius of anyone standing at Edrik")

	# the real in-game path: E at the forge opens the bench and crafts nothing
	if smith != null:
		gs.gold = 100
		gs.add_item("wolf_fang", 4)
		var gold_pre: int = gs.gold
		var fangs_pre: int = gs.count_item("wolf_fang")
		var inv_pre: int = gs.inventory.size()
		smith.call("interact", player)
		await process_frame
		_check(bool(hud.call("is_craft_open")), "Smith.interact opens the bench through the real path")
		_check(gs.ui_blocking, "Smith.interact sets ui_blocking")
		_check(gs.gold == gold_pre, "opening the bench via interact spent no gold (got %d)" % gs.gold)
		_check(gs.count_item("wolf_fang") == fangs_pre, "opening the bench via interact ate no material")
		_check(gs.inventory.size() == inv_pre, "opening the bench via interact left the inventory unchanged")
		_check(not bool(hud.call("is_shop_open")), "opening the bench did not open the shop")
		hud.call("close_craft")
		await process_frame
		_check(not bool(hud.call("is_craft_open")), "close_craft closes the interact-opened bench")
		_check(not gs.ui_blocking, "ui_blocking cleared after closing the interact-opened bench")

	# open the bench through the HUD and check the modal gate (the claws from the
	# interact block above are still there, so the bench has 3/4 of what it wants)
	gs.gold = 100
	hud.call("open_craft_for_shot")
	await process_frame
	_check(bool(hud.call("is_craft_open")), "open_craft opens the bench")
	_check(gs.ui_blocking, "ui_blocking is true while the bench is open")
	var before := player.global_position
	var d_down := InputEventKey.new()
	d_down.physical_keycode = KEY_D
	d_down.keycode = KEY_D
	d_down.pressed = true
	Input.parse_input_event(d_down)
	for i in range(12):
		await physics_frame
	_check(player.global_position.distance_to(before) < 2.0, "the open bench blocks player movement")
	var d_up := InputEventKey.new()
	d_up.physical_keycode = KEY_D
	d_up.keycode = KEY_D
	d_up.pressed = false
	Input.parse_input_event(d_up)
	await physics_frame

	# the bench lists its own station only, and promises the result before E
	var rows: PackedStringArray = hud.call("craft_row_texts")
	_check(rows.size() == 2, "the bench shows its two recipes (got %d)" % rows.size())
	var detail: String = hud.call("craft_detail_text")
	_check(detail.contains("Железный меч"), "the detail line names the produced item (%s)" % detail)
	_check(detail.contains("Атака +2"), "the detail line spells out the permanent bonus (%s)" % detail)
	var mats: PackedStringArray = hud.call("craft_material_texts")
	_check(mats.size() == 1, "the selected recipe shows its one material line")
	_check(mats.size() == 1 and mats[0].contains("3/4"), "the material line reads need/have 3/4 (%s)" % str(mats))

	# a locked recipe refuses and says so, without touching the state
	var gold_locked: int = gs.gold
	await _tap_key(KEY_E)
	_check(String(hud.call("craft_reason_text")) == "Рецепт ещё не известен",
		"E on a locked recipe shows the locked reason (%s)" % str(hud.call("craft_reason_text")))
	_check(gs.gold == gold_locked, "a locked craft spent no gold")
	_check(bool(hud.call("is_craft_open")), "a refusal keeps the bench open")

	# the second row is the armor upgrade, and the cursor really moved
	await _tap_key(KEY_S)
	var detail_2: String = hud.call("craft_detail_text")
	_check(detail_2.contains("Кожаный доспех") and detail_2.contains("Защита +1"),
		"the cursor moved to the armor recipe (%s)" % detail_2)
	await _tap_key(KEY_W)

	# unlocking the tempering the way an NPC would, then crafting it with E
	gs.set_flag("recipe_temper_known", true)
	await process_frame
	var gold_craft: int = gs.gold
	var fangs_craft: int = gs.count_item("wolf_fang")
	await _tap_key(KEY_E)
	_check(gs.gold == gold_craft - 30, "E crafts the tempering for its 30 gold (%d -> %d)" % [gold_craft, gs.gold])
	_check(gs.count_item("wolf_fang") == fangs_craft - 3, "E ate the 3 claws the tempering asks for")
	_check(gs.count_item("iron_sword") == 1, "the crafted sword entered the inventory")
	_check(String(hud.call("craft_reason_text")) == "", "a successful craft clears the reason line")
	_check(gs.upgrade_bonus("iron_sword", "attack") == 2, "the crafted sword carries the permanent +2")
	_check(gs.total_attack() == 5, "an upgrade in the bag adds nothing until the sword is worn")
	gs.equip("iron_sword")
	_check(gs.total_attack() == 13, "wearing the tempered sword gives 5 + 6 + 2 (got %d)" % gs.total_attack())

	# and the very same row now refuses as already upgraded, spending nothing
	var gold_again: int = gs.gold
	var fangs_again: int = gs.count_item("wolf_fang")
	await _tap_key(KEY_E)
	_check(String(hud.call("craft_reason_text")) == "Это уже улучшено",
		"E on an upgraded item shows the already-upgraded reason (%s)" % str(hud.call("craft_reason_text")))
	_check(gs.gold == gold_again, "the refused repeat spent no gold")
	_check(gs.count_item("wolf_fang") == fangs_again, "the refused repeat ate no claws")
	_check(gs.total_attack() == 13, "the refused repeat added no bonus")

	# Esc closes the bench and does not pause the game underneath
	await _tap_key(KEY_ESCAPE)
	_check(not bool(hud.call("is_craft_open")), "Esc closes the bench")
	_check(not gs.ui_blocking, "ui_blocking cleared after Esc closed the bench")
	_check(not paused, "Esc closing the bench does not pause the game")

	# while the bench owns the screen the inventory key is swallowed (modal)
	hud.call("open_craft_for_shot")
	await process_frame
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_craft_open")), "the bench stays open when I is pressed (modal swallows it)")
	_check(not bool(hud.call("is_inventory_open")), "I does not open the inventory while the bench is open")
	await _tap_key(KEY_ESCAPE)

	# mutual exclusion with every other panel that can be opened from outside
	await _tap_key(KEY_I)
	_check(bool(hud.call("is_inventory_open")), "I opens the inventory when the bench is closed")
	hud.call("open_craft_for_shot")
	await process_frame
	_check(bool(hud.call("is_craft_open")), "open_craft opens the bench over the inventory")
	_check(not bool(hud.call("is_inventory_open")), "opening the bench closed the inventory")
	hud.call("open_shop_for_shot")
	await process_frame
	_check(bool(hud.call("is_shop_open")), "open_shop opens the shop over the bench")
	_check(not bool(hud.call("is_craft_open")), "opening the shop closed the bench")
	_check(gs.ui_blocking, "ui_blocking stays set when one modal hands over to another")
	hud.call("open_craft_for_shot")
	await process_frame
	_check(bool(hud.call("is_craft_open")) and not bool(hud.call("is_shop_open")),
		"the bench and the shop are never open at once")
	await _tap_key(KEY_ESCAPE)
	_check(not bool(hud.call("is_craft_open")), "Esc closes the bench after the hand-over")
	_check(not gs.ui_blocking, "ui_blocking cleared after the last panel closed")

	# leave no residue for later groups
	if bool(hud.call("is_craft_open")):
		hud.call("close_craft")
	if bool(hud.call("is_shop_open")):
		hud.call("close_shop")
	if bool(hud.call("is_inventory_open")):
		await _tap_key(KEY_I)
	gs.ui_blocking = false
	paused = false
	scene.queue_free()
	await process_frame
	_clear_slot(2)
	gs.reset()
	qm.reset()
	completed["craft"] = true


## Put a weapon into the equipment slot (or clear it with ""). Goes through the
## real equip() path, which needs the item in the inventory first. A weapon may
## now carry attribute requirements (spec §7.3), and this helper exists to study
## weapon behaviour rather than the gate, so it lifts the attributes to whatever
## the weapon asks for before equipping — the spear needs strength 7.
func _equip_weapon(item_id: String) -> void:
	gs.equipment["weapon"] = ""
	if item_id == "":
		return
	gs.add_item(item_id, 1)
	var requirements := ItemDB.requirements(item_id)
	for attr_name: String in requirements:
		var raw: Variant = requirements[attr_name]
		var required := int(raw) if (raw is int or raw is float) else 0
		if gs.attribute(attr_name) < required:
			gs.attributes[attr_name] = required
			gs.recompute_derived()
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


## The interactable whose node name matches exactly, so the schedule tests can
## grab Edrik/Yorek/Bran without assuming their order in the group.
func _find_interactable_named(group: String, node_name: String) -> Node:
	for node in get_nodes_in_group(group):
		if String(node.name) == node_name:
			return node
	return null


## Tile an NPC currently stands on, using the same 16 px grid the world uses.
func _npc_tile(npc: Node) -> Vector2i:
	return Vector2i(
		floori((npc as Node2D).global_position.x / 16.0),
		floori((npc as Node2D).global_position.y / 16.0)
	)


## True when every NPC stands on the tile its schedule component is aiming for.
func _all_at_spot(npcs: Array) -> bool:
	for npc in npcs:
		var comp: Node = npc.get_node_or_null("ScheduleComponent")
		if comp == null:
			return false
		if _npc_tile(npc) != comp.call("current_spot"):
			return false
	return true


## Steps physics frames (one fixed 1/60 s walk tick each) until every NPC has
## reached its scheduled spot, or the cap is hit. Physics frames, not process
## frames, because the walk runs in _physics_process.
func _settle_walks(npcs: Array, cap: int) -> void:
	for i in range(cap):
		if _all_at_spot(npcs):
			return
		await physics_frame
	await physics_frame


## Stub world for the schedule-safety tests. `cell_at` answers from explicit tile
## sets rather than the generated map, so a test can name a solid morning spot or
## a walled-off target and check the component refuses to stand the NPC on rock.
## With `default_walkable` true, listed `solid` tiles are rock and all else is
## grass; with it false, only listed `walkable` tiles are grass.
class SolidTileWorld:
	extends Node

	var solid: Dictionary = {}
	var walkable: Dictionary = {}
	var default_walkable := true

	func mark_solid(tile: Vector2i) -> void:
		solid[tile] = true

	func mark_walkable(tile: Vector2i) -> void:
		walkable[tile] = true

	func cell_at(tile: Vector2i) -> String:
		if default_walkable:
			return "#" if solid.has(tile) else "."
		return "." if walkable.has(tile) else "#"


## Stub day clock for the schedule-safety tests: serves one canned schedule and a
## fixed phase, with no `phase_changed` signal, so a ScheduleComponent's `_ready`
## runs its morning-snap path in isolation from the real world.
class StubDayClock:
	extends Node

	var data: Dictionary = {}
	var phase_id := "morning"

	func schedules() -> Dictionary:
		return data

	func phase() -> String:
		return phase_id


## Builds a ScheduleComponent wired to a caller-supplied stub world and a fresh
## clock, on an NPC placed at `npc_tile`, then adds it to `arena` so `_ready`
## runs the morning-snap path against `morning_tile`. The world must already be
## configured and in the tree. Returns {npc, world, clock, comp}.
func _build_schedule_rig(arena: Node, tag: String, home: Vector2i,
		morning_tile: Vector2i, npc_tile: Vector2i, world: Node) -> Dictionary:
	var clock := StubDayClock.new()
	clock.name = tag + "Clock"
	clock.data = {"npcs": {tag: {
		"home": [home.x, home.y],
		"spots": {"morning": [morning_tile.x, morning_tile.y]},
	}}}
	arena.add_child(clock)
	var npc := Node2D.new()
	npc.name = tag
	npc.global_position = Vector2(npc_tile.x * 16 + 8, npc_tile.y * 16 + 8)
	arena.add_child(npc)
	# Loaded by path, not by the `ScheduleComponent` identifier: that class
	# references the `GameState` autoload, and autoload globals do not exist when
	# test_core.gd is compiled under `godot --script`, so a direct class reference
	# would fail the whole suite's compilation. `load()` resolves it at runtime,
	# once the autoloads are registered, exactly as `Forest` instantiates it.
	var comp: Node = (load("res://scripts/npc/schedule_component.gd") as GDScript).new()
	comp.name = "ScheduleComponent"
	comp.setup(npc, world, clock)
	npc.add_child(comp)
	return {"npc": npc, "world": world, "clock": clock, "comp": comp}


## Day cycle + compact villager schedules (spec §12.1). Loads the real world,
## checks the data, the clock boundaries and its ui_blocking gate, that every
## scheduled tile is walkable on the generated map, that the villagers start at
## their morning spots and move to the right place when a phase is forced, that
## nobody ever ends up inside a wall, and that neither a modal UI nor a pause
## ages the world or teleports anyone. GameState, ui_blocking and the pause flag
## are restored and the morning phase re-seeded before the group ends.
func _test_day_cycle() -> void:
	gs.reset()
	gs.ui_blocking = false
	paused = false
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var world := scene.get_node_or_null("World")
	var clock: Node = world.get_node_or_null("DayClock") if world != null else null

	# --- data loads: 4 phases, 3 npcs, a positive day length ------------------
	var data: Dictionary = {}
	if FileAccess.file_exists("res://data/schedules.json"):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/schedules.json"))
		if parsed is Dictionary:
			data = parsed as Dictionary
	_check(not data.is_empty(), "data/schedules.json parses as a JSON object")
	var phases: Array = data.get("phases", []) as Array
	var npcs_data: Dictionary = data.get("npcs", {}) as Dictionary
	_check(phases.size() == 4, "schedules data has 4 phases (got %d)" % phases.size())
	_check(npcs_data.size() == 3, "schedules data has 3 npcs (got %d)" % npcs_data.size())
	_check(float(data.get("day_length_seconds", 0)) > 0.0, "day_length_seconds is positive")
	_check(clock != null, "Forest creates a DayClock node")

	if clock == null or data.is_empty() or world == null:
		scene.queue_free()
		await process_frame
		gs.reset()
		completed["day_cycle"] = true
		return

	# --- phase boundaries: last phase whose start <= fraction -----------------
	for probe: Array in [
		[0.0, "morning"], [0.24, "morning"], [0.25, "day"], [0.54, "day"],
		[0.55, "evening"], [0.79, "evening"], [0.8, "night"], [0.99, "night"],
	]:
		clock.call("set_time_fraction", float(probe[0]))
		var got := String(clock.call("phase"))
		_check(got == String(probe[1]), "phase at %.2f is %s (got %s)" % [float(probe[0]), String(probe[1]), got])

	# --- set_time_fraction(1.0) wraps to the start of a new day ---------------
	clock.call("set_time_fraction", 1.0)
	_check(absf(float(clock.get("time_fraction"))) < 0.0001,
		"set_time_fraction(1.0) wraps to 0.0 (got %f)" % float(clock.get("time_fraction")))

	# --- the clock is frozen while a modal UI owns the input ------------------
	clock.call("set_time_fraction", 0.0)
	gs.ui_blocking = true
	var frozen := float(clock.get("time_fraction"))
	for i in range(20):
		await process_frame
	_check(absf(float(clock.get("time_fraction")) - frozen) < 0.0001,
		"clock does not advance while ui_blocking (delta %f)" % (float(clock.get("time_fraction")) - frozen))
	gs.ui_blocking = false
	for i in range(20):
		await process_frame
	_check(float(clock.get("time_fraction")) > frozen,
		"clock advances once ui_blocking clears (now %f)" % float(clock.get("time_fraction")))

	# --- every scheduled spot is walkable on the real generated map -----------
	var all_walkable := true
	var bad: Array[String] = []
	for npc_name: String in npcs_data.keys():
		var entry: Dictionary = npcs_data[npc_name] as Dictionary
		var spots: Dictionary = entry.get("spots", {}) as Dictionary
		for phase_id: String in spots.keys():
			var raw: Array = spots[phase_id] as Array
			var tile := Vector2i(int(raw[0]), int(raw[1]))
			var cell := String(world.call("cell_at", tile))
			if cell != "." and cell != ",":
				all_walkable = false
				bad.append("%s/%s%s='%s'" % [npc_name, phase_id, str(tile), cell])
	_check(all_walkable, "every schedule spot is walkable on the generated map (%s)" % ", ".join(bad))

	# --- resolve the three scheduled villagers + their components -------------
	var edrik := _find_interactable_named("interactable", "Edrik")
	var yorek := _find_interactable_named("interactable", "Yorek")
	var bran := _find_interactable_named("interactable", "Bran")
	var scheduled: Array = []
	for n in [edrik, yorek, bran]:
		if n != null:
			scheduled.append(n)
	_check(edrik != null and yorek != null and bran != null, "Edrik, Yorek and Bran are all present")
	var have_components := not scheduled.is_empty()
	for n in scheduled:
		if n.get_node_or_null("ScheduleComponent") == null:
			have_components = false
	_check(have_components, "each scheduled NPC carries a ScheduleComponent")

	if not have_components:
		clock.call("set_time_fraction", 0.0)
		scene.queue_free()
		await process_frame
		gs.reset()
		completed["day_cycle"] = true
		return

	# --- Edrik stays the first interactable (the BOT-001 path guard) ----------
	var interactables := get_nodes_in_group("interactable")
	_check(not interactables.is_empty() and String(interactables[0].name) == "Edrik",
		"Edrik remains the first interactable for the quest bots")

	# --- everyone starts at the morning spot (= their spawn) ------------------
	clock.call("set_time_fraction", 0.0)
	for n in scheduled:
		var comp: Node = n.get_node_or_null("ScheduleComponent")
		var morning := (comp.call("current_spot")) as Vector2i
		_check(String(comp.call("current_phase")) == "morning", "%s starts in the morning phase" % String(n.name))
		_check(_npc_tile(n) == morning, "%s starts on its morning spot %s (on %s)" % [String(n.name), str(morning), str(_npc_tile(n))])

	# --- forcing day moves Edrik to his day spot ------------------------------
	var edrik_day: Array = ((npcs_data["Edrik"] as Dictionary).get("spots", {}) as Dictionary).get("day", []) as Array
	var edrik_day_tile := Vector2i(int(edrik_day[0]), int(edrik_day[1]))
	clock.call("set_time_fraction", 0.30)
	_check((edrik.get_node_or_null("ScheduleComponent").call("current_spot")) == edrik_day_tile,
		"forcing day assigns Edrik his day spot %s" % str(edrik_day_tile))
	await _settle_walks(scheduled, 600)
	_check(_npc_tile(edrik) == edrik_day_tile,
		"Edrik walked to his day spot %s (on %s)" % [str(edrik_day_tile), str(_npc_tile(edrik))])

	# --- forcing night returns everyone home ----------------------------------
	clock.call("set_time_fraction", 0.85)
	await _settle_walks(scheduled, 600)
	var all_home := true
	for n in scheduled:
		var home: Array = ((npcs_data[String(n.name)]) as Dictionary).get("home", []) as Array
		if _npc_tile(n) != Vector2i(int(home[0]), int(home[1])):
			all_home = false
	_check(all_home, "forcing night returns every villager to its home tile")

	# --- after every phase change nobody stands on a solid tile ---------------
	var never_solid := true
	var solid_offenders: Array[String] = []
	for probe: Array in [[0.05, "morning"], [0.30, "day"], [0.60, "evening"], [0.85, "night"]]:
		clock.call("set_time_fraction", float(probe[0]))
		await _settle_walks(scheduled, 600)
		for n in scheduled:
			var cell := String(world.call("cell_at", _npc_tile(n)))
			if cell != "." and cell != ",":
				never_solid = false
				solid_offenders.append("%s@%s='%s'" % [String(n.name), str(probe[1]), cell])
	_check(never_solid, "no villager ever ends up on a solid tile (%s)" % ", ".join(solid_offenders))

	# --- ui_blocking and pause neither age the world nor teleport anyone ------
	clock.call("set_time_fraction", 0.0)
	await _settle_walks(scheduled, 600)
	var positions: Dictionary = {}
	for n in scheduled:
		positions[n.get_instance_id()] = (n as Node2D).global_position
	var before := float(clock.get("time_fraction"))

	gs.ui_blocking = true
	for i in range(20):
		await process_frame
	var clock_frozen := absf(float(clock.get("time_fraction")) - before) < 0.0001
	var nobody_moved := true
	for n in scheduled:
		if (n as Node2D).global_position.distance_to(positions[n.get_instance_id()]) > 0.01:
			nobody_moved = false
	_check(clock_frozen and nobody_moved, "ui_blocking neither ages the clock nor moves a villager")
	gs.ui_blocking = false

	paused = true
	for i in range(20):
		await process_frame
	var pause_clock_frozen := absf(float(clock.get("time_fraction")) - before) < 0.0001
	var pause_nobody_moved := true
	for n in scheduled:
		if (n as Node2D).global_position.distance_to(positions[n.get_instance_id()]) > 0.01:
			pause_nobody_moved = false
	_check(pause_clock_frozen and pause_nobody_moved, "pause neither ages the clock nor moves a villager")
	paused = false

	# --- a solid morning spot must not teleport the NPC into a wall -------------
	# Inject a schedule whose morning spot is rock and confirm the component keeps
	# the villager on the tile it was placed on instead of snapping onto the wall.
	var solid_world := SolidTileWorld.new()
	solid_world.name = "SolidMorningWorld"
	solid_world.mark_solid(Vector2i(9, 9))
	scene.add_child(solid_world)
	var solid_rig := _build_schedule_rig(scene, "SolidMorningVillager",
			Vector2i(3, 4), Vector2i(9, 9), Vector2i(3, 4), solid_world)
	var solid_npc: Node2D = solid_rig["npc"]
	_check(_npc_tile(solid_npc) == Vector2i(3, 4),
			"a solid morning spot keeps the NPC on its spawn tile (on %s)" % str(_npc_tile(solid_npc)))
	_check(_npc_tile(solid_npc) != Vector2i(9, 9),
			"the NPC is never snapped onto the solid morning spot")

	# --- _nearest_walkable never lands on rock when grass exists in radius ------
	var nw_world := SolidTileWorld.new()
	nw_world.name = "NearestWalkableWorld"
	nw_world.default_walkable = false
	nw_world.mark_walkable(Vector2i(20, 18))
	scene.add_child(nw_world)
	var nw_rig := _build_schedule_rig(scene, "NearestWalkableVillager",
			Vector2i(99, 99), Vector2i(99, 99), Vector2i(98, 98), nw_world)
	var nw_comp: Node = nw_rig["comp"]
	var nw_safe: Vector2i = nw_comp.call("_nearest_walkable", Vector2i(20, 20))
	_check(nw_safe == Vector2i(20, 18),
			"_nearest_walkable reaches the grass tile inside the radius (got %s)" % str(nw_safe))
	_check(bool(nw_comp.call("_is_walkable", nw_safe)),
			"_nearest_walkable never returns a solid tile when grass exists in radius")

	# --- _nearest_walkable prefers home, then the current tile ------------------
	var home_world := SolidTileWorld.new()
	home_world.name = "HomePriorityWorld"
	home_world.default_walkable = false
	home_world.mark_walkable(Vector2i(40, 40))
	home_world.mark_walkable(Vector2i(41, 41))
	scene.add_child(home_world)
	var home_rig := _build_schedule_rig(scene, "HomePriorityVillager",
			Vector2i(40, 40), Vector2i(99, 99), Vector2i(41, 41), home_world)
	var home_safe: Vector2i = (home_rig["comp"] as Node).call("_nearest_walkable", Vector2i(50, 50))
	_check(home_safe == Vector2i(40, 40),
			"_nearest_walkable prefers the walkable home tile (got %s)" % str(home_safe))

	var cur_world := SolidTileWorld.new()
	cur_world.name = "CurrentPriorityWorld"
	cur_world.default_walkable = false
	cur_world.mark_walkable(Vector2i(60, 60))
	scene.add_child(cur_world)
	var cur_rig := _build_schedule_rig(scene, "CurrentPriorityVillager",
			Vector2i(99, 99), Vector2i(99, 99), Vector2i(60, 60), cur_world)
	var cur_safe: Vector2i = (cur_rig["comp"] as Node).call("_nearest_walkable", Vector2i(70, 70))
	_check(cur_safe == Vector2i(60, 60),
			"_nearest_walkable falls back to the walkable current tile (got %s)" % str(cur_safe))

	# --- with no walkable tile anywhere it stays put rather than snapping -------
	var none_world := SolidTileWorld.new()
	none_world.name = "NoSafeTileWorld"
	none_world.default_walkable = false
	scene.add_child(none_world)
	var none_rig := _build_schedule_rig(scene, "NoSafeTileVillager",
			Vector2i(99, 99), Vector2i(99, 99), Vector2i(80, 80), none_world)
	var none_comp: Node = none_rig["comp"]
	var none_npc: Node2D = none_rig["npc"]
	var none_sentinel: Vector2i = none_comp.call("_nearest_walkable", Vector2i(85, 85))
	_check(not bool(none_comp.call("_is_walkable", none_sentinel)),
			"_nearest_walkable returns a solid sentinel only when nothing is walkable")
	none_comp.call("_go_to", Vector2i(85, 85))
	_check(_npc_tile(none_npc) == Vector2i(80, 80),
			"with no safe tile _go_to leaves the NPC exactly where it was (on %s)" % str(_npc_tile(none_npc)))

	# --- the HUD shows a readable clock line ----------------------------------
	var hud := scene.get_node_or_null("HUD")
	_check(hud != null, "HUD is present")
	if hud != null:
		# Freeze the clock at the start of morning and force one refresh, so the
		# assertion does not depend on the HUD's one-second throttle or on how
		# fast headless runs frames.
		gs.ui_blocking = true
		clock.call("set_time_fraction", 0.0)
		hud.call("refresh_clock_line")
		var clock_text := String(hud.call("clock_line_text"))
		_check(clock_text.contains(":"), "HUD clock line shows a time (got '%s')" % clock_text)
		_check(clock_text.begins_with("Утро"), "HUD clock line names the morning phase (got '%s')" % clock_text)
		# Dawn offset: fraction 0.0 must read 06:00, not midnight, and 0.25 must
		# read 12:00, so the phase label and the displayed hour agree (spec §12.1).
		_check(clock_text == "Утро · 06:00", "HUD clock at fraction 0.0 reads Утро · 06:00 (got '%s')" % clock_text)
		clock.call("set_time_fraction", 0.25)
		hud.call("refresh_clock_line")
		var noon_text := String(hud.call("clock_line_text"))
		_check(noon_text == "День · 12:00", "HUD clock at fraction 0.25 reads День · 12:00 (got '%s')" % noon_text)
		gs.ui_blocking = false

	# --- restore: morning phase, no block, no pause, no state leak ------------
	clock.call("set_time_fraction", 0.0)
	gs.ui_blocking = false
	paused = false
	scene.queue_free()
	await process_frame
	gs.reset()
	completed["day_cycle"] = true


## Branching dialogue (spec §12.2): the data table, the runner's node traversal,
## conditions, effects, the read-set that drives the HUD's fast-skip, and the
## save round-trip. The runner is built with the live GameState/QuestManager
## injected, exactly as the NPC builds it in game, so this exercises the same
## object the conversation uses. The full NPC→HUD→runner handoff and the quest
## turn-in fallback are covered end-to-end by BOT-001/BOT-002.
func _test_dialogues() -> void:
	gs.reset()
	qm.reset()

	# --- the data table -------------------------------------------------------
	_check(DialogueDB.has_dialogue("edrik_intro"), "edrik_intro is defined")
	_check(DialogueDB.has_dialogue("edrik_after_hunt"), "edrik_after_hunt is defined")
	_check(not DialogueDB.has_dialogue("nope"), "an unknown dialogue id is not present")
	_check(String(DialogueDB.get_dialogue("edrik_intro").get("speaker_id", "")) == "edrik",
		"edrik_intro names the edrik speaker")
	_check(DialogueDB.for_speaker("edrik").size() == 2, "edrik speaks both dialogues")
	_check(DialogueDB.for_speaker("nobody").is_empty(), "an unknown speaker has no lines")
	var n2 := DialogueDB.node("edrik_intro", "n2")
	_check((n2.get("options", []) as Array).size() == 2, "the choice node offers two options")
	_check(DialogueDB.node("edrik_intro", "ghost").is_empty(), "an unknown node reads as empty")
	_check(DialogueDB.node("edrik_ghost", "n1").is_empty(), "a node of an unknown dialogue reads as empty")

	# --- the after-hunt line is gated on quest_done ---------------------------
	# While the quest is only available the runner must refuse it, which is what
	# forces the NPC back onto its legacy turn-in path (the bot's completion).
	var gate := DialogueRunner.new(gs, qm)
	_check(not gate.start("edrik_after_hunt"), "after-hunt dialogue refuses while the quest is not done")
	_check(gate.is_finished(), "a refused dialogue leaves the runner finished")

	# --- unknown dialogue -----------------------------------------------------
	var ghost := DialogueRunner.new(gs, qm)
	_check(not ghost.start("no_such_dialogue"), "starting an unknown dialogue is refused")
	_check(ghost.is_finished(), "the runner stays finished after a refused start")

	# --- intro traversal: start -> n1 -> advance -> n2 -> choose(0) -> n3 ------
	gs.reset()
	qm.reset()
	var r := DialogueRunner.new(gs, qm)
	_check(r.start("edrik_intro"), "edrik_intro starts")
	_check(not r.is_finished(), "a started dialogue is not finished")
	_check(r.current_node_id() == "n1", "the runner opens on the start node")
	_check(r.current_speaker() == "Эдрик", "the speaker comes from the dialogue")
	_check(r.current_options().is_empty(), "the opening line offers no choices")
	_check(r.advance() == "n2", "advancing a plain line moves to the choice node")
	_check(r.current_node_id() == "n2", "the runner is now on the choice node")
	# advance() must not move a node that offers choices — only choose() may.
	_check(r.advance() == "" and r.current_node_id() == "n2", "advance is a no-op on a choice node")
	# A choice out of range is refused and changes nothing.
	var bad: Dictionary = r.choose(5)
	_check(not bool(bad.get("ok", false)), "choosing past the last option is refused")
	_check(r.current_node_id() == "n2", "a refused choice did not move the node")
	_check(not bool(r.choose(-1).get("ok", false)), "choosing a negative index is refused")
	# The accepted choice sets the flag and (via n3's effect) starts the quest.
	var picked: Dictionary = r.choose(0)
	_check(bool(picked.get("ok", false)), "choosing the first option is accepted")
	_check(r.current_node_id() == "n3", "the choice moved the conversation to n3")
	_check(gs.get_flag("accepted_wolf_hunt", false) == true, "the chosen option set its flag")
	_check(qm.state_of("q01_ash_wolves") == qm.STATE_ACTIVE, "the node effect started the quest")
	_check(r.current_options().is_empty(), "n3 offers no choices")
	_check(r.advance() == "", "advancing the last line ends the conversation")
	_check(r.is_finished(), "the conversation is finished after the last line")

	# --- the after-hunt line still refuses while the quest is merely active ----
	var gate2 := DialogueRunner.new(gs, qm)
	_check(not gate2.start("edrik_after_hunt"), "after-hunt dialogue refuses while the quest is active")

	# --- the second option loops back without starting anything ---------------
	gs.reset()
	qm.reset()
	var loop := DialogueRunner.new(gs, qm)
	loop.start("edrik_intro")
	loop.advance()
	var refused: Dictionary = loop.choose(1)
	_check(bool(refused.get("ok", false)) and loop.current_node_id() == "n4",
		"the greedy option leads to the refusal line")
	_check(loop.advance() == "n2", "the refusal line loops back to the choice node")
	_check(qm.state_of("q01_ash_wolves") == qm.STATE_AVAILABLE, "the greedy path started no quest")

	# --- the read-set (drives the HUD fast-skip) ------------------------------
	gs.reset()
	qm.reset()
	var rd := DialogueRunner.new(gs, qm)
	rd.start("edrik_intro")
	_check(not rd.is_read("n1"), "a fresh node reads as unseen")
	rd.mark_read("n1")
	_check(rd.is_read("n1"), "a marked node reads as seen")
	_check(gs.is_dialogue_read("edrik_intro:n1"), "the read-set is keyed by dialogue_id:node_id")
	_check(not gs.is_dialogue_read("edrik_after_hunt:n1"), "the same node id in another dialogue is separate")
	rd.mark_read("n1")
	_check(gs.dialogue_read.size() == 1, "re-marking the same node does not duplicate the entry")

	# --- the read-set survives a save round-trip ------------------------------
	var payload := JSON.stringify(gs.to_dict())
	var fresh: Node = load("res://scripts/core/game_state.gd").new()
	root.add_child(fresh)
	fresh.call("from_dict", JSON.parse_string(payload))
	_check(bool(fresh.call("is_dialogue_read", "edrik_intro:n1")), "the read-set survives a JSON save round-trip")
	_check(not bool(fresh.call("is_dialogue_read", "edrik_intro:n2")), "unseen nodes stay unseen across a load")
	fresh.queue_free()

	# --- skip_remaining marks the current line fully shown --------------------
	var sk := DialogueRunner.new(gs, qm)
	sk.start("edrik_intro")
	_check(not sk.is_revealed(), "a freshly entered line starts unrevealed")
	sk.skip_remaining()
	_check(sk.is_revealed(), "skip_remaining reveals the whole current line")

	gs.reset()
	qm.reset()
	completed["dialogues"] = true

