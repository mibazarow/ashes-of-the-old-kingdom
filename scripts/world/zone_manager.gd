class_name ZoneManager
extends Node
## Owns zone travel: rebuilds `Main/World` from the script `data/zones.json` names
## for a zone id, keeps `GameState.zone` in step with the live world, and hands
## the new world to the HUD so the map rebinds.
##
## The player never needs carrying. HP, mana, gold, inventory and equipment all
## live in `GameState`, so a zone owns its own `Player` and simply spawns it on
## its `entry_tile`; freeing the old world frees the old player with it.
##
## The zone table is read through static helpers so validating an id (a save
## restore, `GameState.set_zone`) never needs a manager in the tree.

const PATH := "res://data/zones.json"
const DEFAULT_ZONE_ID := "forest"

## How the rest of the game reaches the manager without a node path: the same
## group-resolution style as `hud`, `day_clock` and `safe_zone_owner`.
const GROUP := &"zone_manager"

## The name the world node keeps across travel, because `Main`, the HUD and the
## bot all look it up by that name.
const WORLD_NODE_NAME := "World"

static var _zones: Dictionary = {}
static var _loaded := false


# --- the zone table (static: no manager instance needed) -----------------------

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_error("ZoneManager: missing %s" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary):
		push_error("ZoneManager: cannot parse %s" % PATH)
		return
	var raw: Variant = (parsed as Dictionary).get("zones", {})
	if raw is Dictionary:
		_zones = raw as Dictionary


## Every declared zone, keyed by id. Read-only by convention: callers go through
## the accessors below rather than mutating the shared table.
static func zones() -> Dictionary:
	_ensure_loaded()
	return _zones


static func zone_config(zone_id: String) -> Dictionary:
	var def: Variant = zones().get(zone_id, {})
	return def if def is Dictionary else {}


static func has_zone(zone_id: String) -> bool:
	return not zone_config(zone_id).is_empty()


static func zone_display_name(zone_id: String) -> String:
	return String(zone_config(zone_id).get("name", zone_id))


static func zone_script_path(zone_id: String) -> String:
	return String(zone_config(zone_id).get("script", ""))


## Where a zone drops the player. A malformed or missing `entry_tile` reads as
## (0, 0) rather than failing the spawn; the zone's own walkable scan then keeps
## the player out of the wall that border always occupies there.
static func entry_tile(zone_id: String) -> Vector2i:
	var raw: Variant = zone_config(zone_id).get("entry_tile", [])
	if not (raw is Array):
		return Vector2.ZERO
	var arr: Array = raw as Array
	if arr.size() != 2 or not (arr[0] is int or arr[0] is float) or not (arr[1] is int or arr[1] is float):
		return Vector2.ZERO
	return Vector2i(int(arr[0]), int(arr[1]))


# --- travel -------------------------------------------------------------------

func _ready() -> void:
	add_to_group(GROUP)


## The live world node, or null while `Main` has none.
func current_zone() -> Node2D:
	var main := get_parent()
	if main == null:
		return null
	return main.get_node_or_null(WORLD_NODE_NAME) as Node2D


## Moves the player to another zone. Returns false, having changed nothing, when
## the id is not a declared zone, when it is the zone already stood in, or when
## its script cannot be built.
##
## The old world is freed with `free()`, not `queue_free()`: a queued world would
## spend one more frame in the tree with a `Player` still in the `player` group,
## and every group lookup made in that window would answer with the corpse. That
## is also why an `interact` handler must not call this directly — see `ZoneExit`.
func travel(zone_id: String) -> bool:
	if not has_zone(zone_id):
		return false
	var main := get_parent()
	if main == null:
		push_error("ZoneManager: travel without a parent")
		return false
	var previous := current_zone()
	if previous != null and String(previous.call("zone_id")) == zone_id:
		return false
	var script: GDScript = load(zone_script_path(zone_id))
	if script == null:
		push_error("ZoneManager: cannot load script for zone '%s'" % zone_id)
		return false
	var candidate: Variant = script.new()
	if not (candidate is Node2D):
		push_error("ZoneManager: zone '%s' is not a Node2D" % zone_id)
		if candidate is Node:
			(candidate as Node).free()
		return false
	var next := candidate as Node2D
	next.name = WORLD_NODE_NAME

	# Commit only once the replacement is known good, so a broken zone can never
	# leave Main without a world.
	if previous != null:
		main.remove_child(previous)
		previous.free()
	main.add_child(next)
	# The new world has to sit where the old one did — ahead of the HUD, which is
	# a CanvasLayer and must keep drawing over it. `add_child` put it last, so it
	# is moved onto the HUD's index, which pushes the HUD one place right.
	var hud := main.get_node_or_null("HUD")
	if hud != null:
		main.move_child(next, hud.get_index())

	GameState.set_zone(zone_id)
	if hud != null and hud.has_method("rebind_world"):
		hud.call("rebind_world", next)
	EventBus.toast.emit("Зона: %s" % zone_display_name(zone_id))
	return true
