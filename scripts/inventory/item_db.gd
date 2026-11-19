class_name ItemDB
extends RefCounted
## Item definitions loaded once from data/items.json.

const PATH := "res://data/items.json"

## Used for any weapon without an explicit "combo_window" in the data, so a
## hand-written or legacy item still gets a playable chain window.
const DEFAULT_COMBO_WINDOW := 0.4

static var _items: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_error("ItemDB: missing %s" % PATH)
		return
	var text := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		_items = parsed.get("items", {})
	else:
		push_error("ItemDB: cannot parse %s" % PATH)


static func get_item(item_id: String) -> Dictionary:
	_ensure_loaded()
	var def: Variant = _items.get(item_id, {})
	return def if def is Dictionary else {}


static func all_items() -> Dictionary:
	_ensure_loaded()
	return _items


static func display_name(item_id: String) -> String:
	var def := get_item(item_id)
	return String(def.get("name", item_id))


static func is_consumable(item_id: String) -> bool:
	return String(get_item(item_id).get("type", "")) == "consumable"


## Attack chain of a weapon (spec §6 "Комбо зависят от оружия"): an ordered list
## of steps, each one a Dictionary with damage_mult / windup / active / recovery
## / reach / arc. An item without a combo (unarmed, armor, a legacy weapon)
## returns an empty array, and the caller falls back to its own single swing.
static func combo_steps(item_id: String) -> Array:
	var raw: Variant = get_item(item_id).get("combo", [])
	return raw if raw is Array else []


## Seconds after a swing in which the next attack continues the chain. Anything
## missing, non-numeric or non-positive falls back to DEFAULT_COMBO_WINDOW.
static func combo_window(item_id: String) -> float:
	var raw: Variant = get_item(item_id).get("combo_window", 0.0)
	if raw is float or raw is int:
		var value := float(raw)
		if value > 0.0:
			return value
	return DEFAULT_COMBO_WINDOW
