class_name ItemDB
extends RefCounted
## Item definitions loaded once from data/items.json.

const PATH := "res://data/items.json"

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
