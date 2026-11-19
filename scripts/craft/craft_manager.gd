class_name CraftManager
extends RefCounted
## Pure crafting rules for the stations of spec §14.4 (blacksmith, herbalist).
##
## The mirror of `ShopManager` for the other half of the economy: the class holds
## no scene, reads no autoload by name, and takes a `GameState` reference in the
## constructor, so the same rules run in the live game and in a headless test with
## a throwaway state. `data/recipes.json` is the single source of recipes —
## nothing here hardcodes an item, a price or a material.
##
## A recipe is: one `station`, one `output` item (+ `output_amount`), a `gold`
## fee, a `materials` dictionary of item id -> count, an optional `unlock_flag`
## (empty means known from the start; anything else is a `GameState` flag an NPC,
## a note or an exploration reward sets — spec §14.4 "recipes unlock through NPCs,
## notes, exploration and rare rewards"), and an optional `upgrade` block that
## makes this a permanent equipment upgrade rather than a plain craft.
##
## Atomicity (spec §14.4): `can_craft` is pure and writes nothing, and `craft`
## runs it in full before the first mutation. Everything that can be refused —
## the fee, every material, the output stack cap, the already-upgraded gate — is
## decided up front, so the steps that follow are the ones that cannot fail and
## no half-applied craft is possible. The steps are still ordered so that the
## only fallible one (spending gold) runs first, and each later step has a
## rollback that undoes everything before it. That rollback is deliberately
## unreachable in normal play: it exists so that a hand-edited data file or a
## future GameState that refuses more at commit time can never mint or destroy
## items, not so that a normal failure can be papered over.

const PATH := "res://data/recipes.json"

## Stack cap used by the free-space check, the same rule the shop applies: the
## inventory keeps one slot per item id, so a craft is refused when it would push
## that stack past the cap rather than silently dropping or splitting the result.
const MAX_STACK := 99

## The injected `GameState`. Typed loosely as `Node` so this script compiles
## without an autoload identifier in scope; every call is a plain method call.
var _state: Node
var _recipes: Dictionary = {}
## The station this instance was handed out for ("" = not bound to one). A station
## NPC passes its own id so the panel it opens lists that station's recipes and
## nothing else; a manager built without one still answers every rule, it simply
## has no single station to advertise.
var _station: String = ""


func _init(state: Node, for_station: String = "") -> void:
	_state = state
	_station = for_station
	_load()


## Reads and sanitises the data. A recipe that could not work even in principle —
## no id, no station, an output the item table does not know, a negative fee or a
## negative material count — is dropped rather than half-loaded, so the panel can
## never offer a recipe that would fail at commit time for a data reason.
func _load() -> void:
	if not FileAccess.file_exists(PATH):
		push_error("CraftManager: missing %s" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary):
		push_error("CraftManager: cannot parse %s" % PATH)
		return
	var block: Variant = (parsed as Dictionary).get("recipes", {})
	if not (block is Dictionary):
		push_error("CraftManager: %s has no recipes dictionary" % PATH)
		return
	_recipes = {}
	for raw_id: Variant in (block as Dictionary):
		var recipe_id := String(raw_id)
		var raw_recipe: Variant = (block as Dictionary)[raw_id]
		if recipe_id == "" or not (raw_recipe is Dictionary):
			continue
		var recipe := _sanitize(recipe_id, raw_recipe as Dictionary)
		if not recipe.is_empty():
			_recipes[recipe_id] = recipe


## One usable recipe built from the raw data, or {} when the entry is unusable.
## Numbers are coerced to ints, unknown material entries keep their count (the
## check below reports them as missing rather than crashing), and an absent
## `upgrade` becomes an empty dictionary so callers never test for the key.
func _sanitize(recipe_id: String, raw: Dictionary) -> Dictionary:
	var station := String(raw.get("station", ""))
	var output := String(raw.get("output", ""))
	if station == "" or output == "" or ItemDB.get_item(output).is_empty():
		return {}
	var amount_raw: Variant = raw.get("output_amount", 1)
	var amount := int(amount_raw) if (amount_raw is int or amount_raw is float) else 1
	if amount < 1:
		amount = 1
	var gold_raw: Variant = raw.get("gold", 0)
	var gold := int(gold_raw) if (gold_raw is int or gold_raw is float) else 0
	gold = maxi(0, gold)
	var materials: Dictionary = {}
	var raw_materials: Variant = raw.get("materials", {})
	if raw_materials is Dictionary:
		for raw_item: Variant in (raw_materials as Dictionary):
			var item_id := String(raw_item)
			var count_raw: Variant = (raw_materials as Dictionary)[raw_item]
			var count := int(count_raw) if (count_raw is int or count_raw is float) else 0
			if item_id == "" or count < 1:
				continue
			materials[item_id] = count
	var upgrade: Dictionary = {}
	var raw_upgrade: Variant = raw.get("upgrade", {})
	if raw_upgrade is Dictionary:
		for raw_stat: Variant in (raw_upgrade as Dictionary):
			var stat := String(raw_stat)
			var value_raw: Variant = (raw_upgrade as Dictionary)[raw_stat]
			var value := int(value_raw) if (value_raw is int or value_raw is float) else 0
			if stat == "" or value < 1:
				continue
			upgrade[stat] = value
	return {
		"name": String(raw.get("name", recipe_id)),
		"station": station,
		"output": output,
		"output_amount": amount,
		"gold": gold,
		"materials": materials,
		"unlock_flag": String(raw.get("unlock_flag", "")),
		"upgrade": upgrade,
	}


## The raw (sanitised) recipe, or {} for an id the data does not define.
func recipe(recipe_id: String) -> Dictionary:
	var raw: Variant = _recipes.get(recipe_id, {})
	return raw if raw is Dictionary else {}


func recipe_name(recipe_id: String) -> String:
	return String(recipe(recipe_id).get("name", recipe_id))


func station_of(recipe_id: String) -> String:
	return String(recipe(recipe_id).get("station", ""))


## The station this instance was created for, or "" when it was built unbound.
func station() -> String:
	return _station


## Every recipe id in data order, whatever its station.
func recipe_ids() -> Array[String]:
	var ids: Array[String] = []
	for recipe_id: String in _recipes:
		ids.append(recipe_id)
	return ids


## Recipe ids belonging to one station, in data order. The order is stable so the
## panel cursor never jumps under the player between refreshes. An empty station
## asks for nothing rather than for everything: "show me the smith's bench" and
## "show me whatever exists" are different questions.
func station_recipes(station: String) -> Array[String]:
	var ids: Array[String] = []
	if station == "":
		return ids
	for recipe_id: String in _recipes:
		if station_of(recipe_id) == station:
			ids.append(recipe_id)
	return ids


func gold_cost(recipe_id: String) -> int:
	return int(recipe(recipe_id).get("gold", 0))


## Material id -> required count, as the data defines it.
func materials_of(recipe_id: String) -> Dictionary:
	var raw: Variant = recipe(recipe_id).get("materials", {})
	return raw if raw is Dictionary else {}


## The permanent equipment upgrade this recipe applies, stat -> bonus. Empty for
## a plain craft (a potion), non-empty for a smith tempering.
func upgrade_of(recipe_id: String) -> Dictionary:
	var raw: Variant = recipe(recipe_id).get("upgrade", {})
	return raw if raw is Dictionary else {}


## Whether the recipe is known to the player: a recipe without an `unlock_flag`
## is known from the start, the rest need their flag set in `GameState` — which
## is exactly what a save carries, so an unlocked recipe survives a round-trip.
func is_unlocked(recipe_id: String) -> bool:
	var def := recipe(recipe_id)
	if def.is_empty():
		return false
	var flag := String(def.get("unlock_flag", ""))
	if flag == "":
		return true
	return bool(_state.get_flag(flag, false))


## Marks the recipe known by setting its unlock flag. Returns false when there is
## nothing to do: an unknown recipe, or one that was already craftable without a
## flag. Unlocking is deliberately a plain flag write — the same mechanism the
## quest and exploration rewards already use — so no new save field is needed.
func unlock(recipe_id: String) -> bool:
	var def := recipe(recipe_id)
	if def.is_empty():
		return false
	var flag := String(def.get("unlock_flag", ""))
	if flag == "":
		return false
	_state.set_flag(flag, true)
	return true


## Why `craft` would refuse right now, or {"ok": true} when it would succeed.
## Pure: reads gold, inventory, flags and upgrades, writes nothing.
##
## The order of the checks is part of the contract, because the panel shows the
## first reason it gets: an already-upgraded item can never be tempered again no
## matter how much gold the player holds, so that gate is answered before the
## costs — otherwise a player who just spent their last coin on the first temper
## would be told "not enough gold" about a recipe that is simply finished.
func can_craft(recipe_id: String) -> Dictionary:
	var def := recipe(recipe_id)
	if def.is_empty():
		return {"ok": false, "reason": "unknown_recipe"}
	if not is_unlocked(recipe_id):
		return {"ok": false, "reason": "locked"}
	var output := String(def.get("output", ""))
	var upgrade := upgrade_of(recipe_id)
	if not upgrade.is_empty():
		for stat: String in upgrade:
			if bool(_state.has_item_upgrade(output, stat)):
				return {"ok": false, "reason": "already_upgraded"}
	if _state.gold < gold_cost(recipe_id):
		return {"ok": false, "reason": "not_enough_gold"}
	var materials := materials_of(recipe_id)
	for item_id: String in materials:
		if _state.count_item(item_id) < int(materials[item_id]):
			return {"ok": false, "reason": "missing_material"}
	var amount := int(def.get("output_amount", 1))
	if _state.count_item(output) + amount > MAX_STACK:
		return {"ok": false, "reason": "no_space"}
	return {"ok": true, "reason": ""}


## Runs one craft. Everything is validated by `can_craft` before the first
## mutation, so the normal path is: check, pay, consume, produce, upgrade — and
## the rollbacks below never run. They are kept as the last line of defence: a
## step that still fails undoes every step before it and reports the reason, so
## a craft either happens whole or leaves gold, materials, inventory and
## upgrades byte for byte as they were.
func craft(recipe_id: String) -> Dictionary:
	var check := can_craft(recipe_id)
	if not bool(check.get("ok", false)):
		return {
			"ok": false,
			"reason": String(check.get("reason", "")),
			"gold_spent": 0,
			"output": "",
		}
	var def := recipe(recipe_id)
	var output := String(def.get("output", ""))
	var amount := int(def.get("output_amount", 1))
	var total := gold_cost(recipe_id)
	var materials := materials_of(recipe_id)
	var upgrade := upgrade_of(recipe_id)

	# Gold first: it is the only step that can still refuse, so a failure here
	# returns before a single material or item is touched.
	if not _state.spend_gold(total):
		return {"ok": false, "reason": "not_enough_gold", "gold_spent": 0, "output": ""}

	# Materials next. A missing one refunds the fee and removes nothing, so the
	# player never pays for a craft that did not consume his loot.
	for item_id: String in materials:
		var need := int(materials[item_id])
		if not _state.remove_item(item_id, need):
			for refunded_id: String in materials:
				if String(refunded_id) == String(item_id):
					break
				_state.add_item(String(refunded_id), int(materials[refunded_id]))
			_state.add_gold(total)
			return {"ok": false, "reason": "missing_material", "gold_spent": 0, "output": ""}

	# The result. The stack cap was proved up front, so this cannot overflow.
	_state.add_item(output, amount)

	# The permanent upgrade, last: it is the only step that can still be refused
	# (the idempotency gate lives in GameState), and refusing it must give back
	# the fee, the materials and the produced item.
	if not upgrade.is_empty() and not bool(_state.apply_item_upgrade(output, upgrade)):
		_state.remove_item(output, amount)
		for item_id: String in materials:
			_state.add_item(item_id, int(materials[item_id]))
		_state.add_gold(total)
		return {"ok": false, "reason": "already_upgraded", "gold_spent": 0, "output": ""}

	return {"ok": true, "reason": "", "gold_spent": total, "output": output}


## Everything the panel needs to show before the player confirms (spec §14.4:
## "shows the result and cost before confirming"): the recipe name, the fee, each
## material as need/have against the live inventory, the produced item and the
## upgrade block. Pure — it reads state and writes nothing, so the panel can call
## it on every frame it repaints.
func preview(recipe_id: String) -> Dictionary:
	var def := recipe(recipe_id)
	var materials: Dictionary = {}
	if def.is_empty():
		return {
			"name": "", "gold": 0, "materials": materials,
			"output": "", "output_name": "", "upgrade": {},
		}
	var raw_materials := materials_of(recipe_id)
	for item_id: String in raw_materials:
		materials[item_id] = {
			"need": int(raw_materials[item_id]),
			"have": _state.count_item(item_id),
		}
	var output := String(def.get("output", ""))
	return {
		"name": String(def.get("name", recipe_id)),
		"gold": gold_cost(recipe_id),
		"materials": materials,
		"output": output,
		"output_name": ItemDB.display_name(output),
		"upgrade": upgrade_of(recipe_id),
	}
