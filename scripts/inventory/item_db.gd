class_name ItemDB
extends RefCounted
## Item definitions loaded once from data/items.json.

const PATH := "res://data/items.json"

## Used for any weapon without an explicit "combo_window" in the data, so a
## hand-written or legacy item still gets a playable chain window.
const DEFAULT_COMBO_WINDOW := 0.4

## The five rarity tiers of spec §14.1, in ascending order. The order is the
## scale `rarity_color` and any future sort walk, so a rarity that is not one of
## these five is a data typo, not a hidden sixth tier.
const RARITIES := ["common", "uncommon", "rare", "epic", "legendary"]

## Colour per rarity (spec §14.1: colour must never replace the description, it
## only reinforces it). common is a neutral grey-white so an unremarkable item
## does not shout; the tiers then climb green → blue → purple → gold.
const RARITY_COLORS := {
	"common": Color(0.82, 0.84, 0.8),
	"uncommon": Color(0.46, 0.86, 0.42),
	"rare": Color(0.42, 0.66, 0.98),
	"epic": Color(0.74, 0.5, 0.95),
	"legendary": Color(0.98, 0.82, 0.32),
}

## Fallback colour for an unknown rarity string, kept distinct from every tier
## so a data typo is visible rather than silently reading as common-white.
const RARITY_COLOR_FALLBACK := Color(0.9, 0.62, 0.86)

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


## Whether an item can go into an equipment slot at all. The type is the gate,
## not the presence of a `slot` key: a material that picked up a stray `slot` by
## a hand edit is still not wearable, and an equipment item whose slot names a
## slot the game does not have is rejected later by `GameState.equip()`.
static func is_equipment(item_id: String) -> bool:
	return String(get_item(item_id).get("type", "")) == "equipment"


## The slot an item's data names ("weapon", "armor", "accessory", …), or "" when
## it names none. The data-level name is returned as written: `accessory` covers
## both concrete accessory slots, and choosing between them is the state's job,
## not the data's.
static func equipment_slot(item_id: String) -> String:
	return String(get_item(item_id).get("slot", ""))


## Rarity tier of an item (spec §14.1). Anything missing or not one of the five
## tiers reads as "common", so a legacy or hand-edited item still has a valid
## rarity rather than an empty string that would break the colour lookup.
static func rarity(item_id: String) -> String:
	var value := String(get_item(item_id).get("rarity", "common"))
	return value if RARITIES.has(value) else "common"


## Display colour for a rarity tier. An unknown tier returns the distinct
## fallback colour rather than common-white, so a data typo is visible.
static func rarity_color(tier: String) -> Color:
	var color: Variant = RARITY_COLORS.get(tier, null)
	return color as Color if color is Color else RARITY_COLOR_FALLBACK


## The single-glyph icon shown at the head of an inventory row. A missing glyph
## reads as "?" so a row is never blank at the head.
static func icon(item_id: String) -> String:
	var value := String(get_item(item_id).get("icon", ""))
	return value if value != "" else "?"


## The inventory icon texture of an item, as a resource path, or "" when the item
## names none. A path that does not resolve also reads as "": the caller then
## falls back to `icon()`, so a typo in the data costs the player a real glyph
## instead of an empty square where the art should be. Checked through
## `ResourceLoader` rather than `FileAccess` because a shipped build carries the
## texture as an imported resource, not as a loose file.
static func icon_texture(item_id: String) -> String:
	var value := String(get_item(item_id).get("icon_texture", ""))
	if value == "":
		return ""
	return value if ResourceLoader.exists(value) else ""


## Attribute requirements to wear an item (spec §7.3): a Dictionary of
## attribute name -> required value. Empty when the item names none (and for any
## non-equipment item, which never has requirements). A non-Dictionary value is
## treated as no requirement rather than throwing.
static func requirements(item_id: String) -> Dictionary:
	var raw: Variant = get_item(item_id).get("requires", {})
	return raw if raw is Dictionary else {}


## Short human-readable origin of an item (chest id, enemy, vendor, craft).
## Empty when the data names none.
static func source(item_id: String) -> String:
	return String(get_item(item_id).get("source", ""))


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
