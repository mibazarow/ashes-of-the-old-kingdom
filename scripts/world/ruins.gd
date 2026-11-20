class_name Ruins
extends ZoneBase
## The second zone: a compact stone hall reached through the gate at the eastern
## end of the forest road. It is deliberately empty of enemies and quests — the
## point of this zone is that a second one exists, saves, loads and maps, not that
## it has content yet.
##
## The layout is written out as constants rather than rolled from a seed: a fixed
## list of wall segments, pillars and dirt patches is deterministic by
## construction, so there is no generator to keep in step and no seed to pin.

const MAP_W := 40
const MAP_H := 26

## Where the forest gate drops the player, read from `data/zones.json` so the
## table stays the single place that decides an entry point.
const FOREST_GATE_TILE := Vector2i(3, 11)

## The zone's own entry tile, used only as the fallback when the data table has
## nothing usable for this zone.
const FALLBACK_ENTRY_TILE := Vector2i(3, 8)

## How far the spawn scan widens when the entry tile named in the data turns out
## to sit on something solid. Three tiles clears a single pillar or a one-tile
## wall stub without wandering across the hall.
const ENTRY_FALLBACK_SCAN_RADIUS := 3

## Inner masonry. Each rect is (position, size) in tiles and is clamped to the
## interior when painted, so a segment can never punch a hole in the border.
## The two rects on column 14 leave a doorway at rows 9..13, which is the only
## way from the entry passage into the main hall.
const INNER_WALLS: Array[Rect2i] = [
	Rect2i(14, 1, 1, 8),
	Rect2i(14, 14, 1, 11),
	Rect2i(24, 6, 9, 1),
	Rect2i(24, 18, 9, 1),
	Rect2i(6, 20, 1, 3),
]

## Standing columns. Deliberately clear of the entry tile, the gate tile and the
## doorway, so nothing solid ever lands where the player has to walk.
const PILLARS: Array[Vector2i] = [
	Vector2i(8, 4), Vector2i(8, 12), Vector2i(8, 20),
	Vector2i(19, 4), Vector2i(19, 12), Vector2i(19, 20),
	Vector2i(29, 10), Vector2i(29, 14),
	Vector2i(34, 6), Vector2i(34, 19),
]

## Worn floor, drawn as dirt. Painted before the masonry so a patch can only ever
## be covered by a wall, never the other way round.
const DIRT_PATCHES: Array[Rect2i] = [
	Rect2i(2, 7, 8, 3),
	Rect2i(16, 10, 6, 4),
	Rect2i(26, 9, 10, 8),
	Rect2i(5, 16, 5, 3),
]

## Points of interest kept as live node references, as in `Forest`.
var _gate_node: Node2D


func zone_id() -> String:
	return "ruins"


func zone_name() -> String:
	return "Руины у опушки"


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# The validity check comes before the typed binding: assigning a freed
	# instance to `var node: Node2D` is itself a script error.
	if not is_instance_valid(_gate_node):
		return out
	var node: Node2D = _gate_node
	if node == null:
		return out
	out.append({
		"id": "ForestGate",
		"kind": "gate",
		"tile": Vector2i(
			floori(node.global_position.x / float(TILE)),
			floori(node.global_position.y / float(TILE))
		),
	})
	return out


func _generate_map() -> void:
	_map_width = MAP_W
	_map_height = MAP_H
	var grid: Array = []
	for y in range(MAP_H):
		var row: Array = []
		for x in range(MAP_W):
			var edge := x == 0 or y == 0 or x == MAP_W - 1 or y == MAP_H - 1
			row.append("#" if edge else ".")
		grid.append(row)

	for patch: Rect2i in DIRT_PATCHES:
		_paint_rect(grid, patch, ",")
	for wall: Rect2i in INNER_WALLS:
		_paint_rect(grid, wall, "#")
	for pillar: Vector2i in PILLARS:
		if _is_interior(pillar):
			grid[pillar.y][pillar.x] = "#"

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


## Paints one rect with a character, clipped to the interior so the border wall
## stays solid no matter how the constants are edited later.
func _paint_rect(grid: Array, rect: Rect2i, ch: String) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if not _is_interior(Vector2i(x, y)):
				continue
			grid[y][x] = ch


func _is_interior(tile: Vector2i) -> bool:
	return tile.x > 0 and tile.y > 0 and tile.x < MAP_W - 1 and tile.y < MAP_H - 1


func _spawn_actors() -> void:
	# The entry tile comes from the data table, snapped to the nearest walkable
	# cell so a hand-edited `entry_tile` that lands on a pillar still spawns a
	# player standing on floor. Radius 3 is enough to step off a single pillar or
	# a one-tile wall stub without wandering across the hall.
	var entry := ZoneManager.entry_tile(zone_id())
	if entry == Vector2i.ZERO:
		entry = FALLBACK_ENTRY_TILE
	var spawn_tile := _entry_spawn_tile(entry)
	player = _instantiate(PLAYER_SCENE, _tile_center(spawn_tile.x, spawn_tile.y), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	# The way back. Its tile is a fixed constant checked for walkability by a
	# radius-0 scan rather than snapped by a wide one: the gate marks the spot the
	# player arrived at, and a scan free to move it would silently relocate the
	# only exit in the zone. Three tiles from the entry tile, so arriving never
	# opens the prompt under the player's feet.
	var gate_tile := _find_walkable_near(FOREST_GATE_TILE, 0)
	var gate := ZoneExit.new()
	gate.name = "ForestGate"
	gate.target_zone = "forest"
	gate.prompt = "Вернуться в лес"
	gate.position = _tile_center(gate_tile.x, gate_tile.y)
	add_child(gate)
	_gate_node = gate


func _is_walkable(tile: Vector2i) -> bool:
	var ch := cell_at(tile)
	return ch == "." or ch == ","


## The tile the player arrives on: the entry point named in `data/zones.json`,
## unless that cell turns out to be solid, in which case the nearest walkable
## one.
##
## `ZoneBase._find_walkable_near` cannot simply be handed the entry tile with a
## radius, because it returns the first walkable cell of its scan box in
## row-major order rather than preferring the anchor — asked about (3, 8) with a
## radius of 3 it answers (1, 5), which is a different place entirely. The
## declared tile is where the player is meant to arrive, so it is used whenever it
## is walkable, and the base scan is only reached as the fallback for data that
## put an entry point inside a pillar.
func _entry_spawn_tile(entry: Vector2i) -> Vector2i:
	if _is_walkable(entry):
		return entry
	for radius in range(1, ENTRY_FALLBACK_SCAN_RADIUS + 1):
		var candidate := _find_walkable_near(entry, radius)
		if _is_walkable(candidate):
			return candidate
	return entry


## The ruins have no villagers and therefore no schedule to serve, but the day
## cycle is world-owned state the HUD reads through the `day_clock` group, so the
## zone runs its own clock. Without it the clock line would simply go blank for
## as long as the player stood here.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
