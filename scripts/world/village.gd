class_name Village
extends ZoneBase
## The fifth zone: Последняя деревня, the village the six NPCs actually live in.
##
## The village used to be a dirt clearing inside the forest, which made the
## forest carry two jobs — a safe home and a hunting ground — and made every
## "walk to the village head" a walk across a map full of wolves. This zone owns
## the home half: the six scheduled villagers, their houses, the forge, the mill
## and the safe zone the enemies are turned back from. The forest keeps the
## wild half and is reachable through `ForestGate` at the east road; the forest
## answers with `VillageGate` at its west clearing.
##
## Everything generic (grid reader, tileset build, exploration, camera, schedule
## wiring) lives in `ZoneBase`; this file is content only, like every other zone.

const NPC_SCENE := "res://scenes/npcs/edrik.tscn"
const VILLAGER_SCRIPT := "res://scripts/npcs/villager.gd"

## Authored map, not a generated one: a village is streets and house plots, and
## a seeded scatter cannot promise a road reaches the gate. The grid is fixed
## text, so every run, every test and every bot seed sees the same streets.
const MAP_W := 40
const MAP_H := 26

## The tile the player arrives on when he walks in from the forest: the east
## road, two tiles inside the wall. `data/zones.json` names the same tile as the
## zone's `entry_tile`; the two are asserted equal by the zone registry group.
const ENTRY_TILE := Vector2i(36, 12)

## The way back to the forest, one tile west of the wall gap the road runs
## through. Two tiles (32 px) from the arrival tile, so the interact reach
## (26 px) never shows a prompt under the player's feet on arrival — the same
## margin the forest keeps between its own spawn and `VillageGate`.
const FOREST_GATE_TILE := Vector2i(38, 12)

## The village safe zone: everything inside the walls. `Enemy` reads this
## through the `safe_zone_owner` group and refuses to step inside; the village
## spawns no enemies at all, so the rect is a promise the zone keeps by
## construction, and the promise a test can measure.
const SAFE_ZONE_RECT := Rect2i(2, 2, 36, 22)

## The villagers' posts. Authored tiles, each one walkable ground on the grid
## below, each one at least three tiles (Chebyshev) from every other villager
## and four from Edrik: the debug bot walks the FIRST interactable and presses
## E inside a 26 px reach, so standing at Edrik must never put the till, the
## forge or another quest-giver under the same key press. Edrik is also spawned
## first among the interactables for the same reason the forest always spawned
## him first.
const EDRIK_TILE := Vector2i(20, 12)
const YOREK_TILE := Vector2i(24, 10)
const BRAN_TILE := Vector2i(28, 15)
const MILA_TILE := Vector2i(16, 9)
const SERIS_TILE := Vector2i(12, 16)
const ALVENA_TILE := Vector2i(26, 19)

var _npc_node: Node2D
var _merchant_node: Node2D
var _smith_node: Node2D
var _mila_node: Node2D
var _seris_node: Node2D
var _alvena_node: Node2D
var _gate_node: Node2D

## House plots, the forge, the mill, the tannery yard and the square's well —
## solid `#` blocks on the authored grid. Listed as rects so the map reads as
## buildings rather than as forty rows of punctuation.
const BUILDINGS: Array[Rect2i] = [
	Rect2i(18, 7, 3, 2),	# Эдрик — the headman's house
	Rect2i(25, 7, 3, 2),	# Йорек — the trader's shop
	Rect2i(14, 7, 3, 2),	# Мила — the herbwife's hut, door on the north street
	Rect2i(29, 13, 3, 3),	# Бран — the forge
	Rect2i(10, 19, 3, 3),	# Серис — the mill
	Rect2i(26, 21, 3, 2),	# Альвена — the tannery yard
	Rect2i(22, 13, 1, 1),	# the well in the square
]

## The dirt: the square, the roads that connect the houses to it, and the east
## road that runs out through the wall gap to the forest.
const DIRT: Array[Rect2i] = [
	Rect2i(18, 11, 7, 5),	# the square
	Rect2i(25, 12, 14, 1),	# the east road to the gate
	Rect2i(14, 9, 15, 1),	# the north street along the houses
	Rect2i(20, 9, 1, 10),	# the headman's lane, house door to the south gate path
	Rect2i(11, 16, 10, 1),	# the west lane to the mill
	Rect2i(28, 12, 1, 4),	# the forge yard spur
]

## Decorative tree clusters inside the wall — orchards, hedges, the copse by the
## mill. None of them stands on a road, a post, a schedule spot or a route
## between them; the day-cycle group walks every villager between every spot
## and would notice a blocked street.
const TREES: Array[Vector2i] = [
	Vector2i(5, 5), Vector2i(6, 6), Vector2i(34, 4), Vector2i(35, 5),
	Vector2i(12, 5), Vector2i(8, 8), Vector2i(36, 8), Vector2i(34, 9),
	Vector2i(13, 11), Vector2i(9, 12), Vector2i(9, 13), Vector2i(4, 17),
	Vector2i(5, 18), Vector2i(34, 18), Vector2i(35, 19), Vector2i(30, 17),
	Vector2i(15, 20), Vector2i(16, 21), Vector2i(22, 20), Vector2i(27, 18),
]


## The village shares the forest palette on purpose: it is a clearing in the
## same wood, and the CRITIC-P1-01 rule is about the four WILD zones reading
## apart from each other, not about a hamlet having its own grass.
func tile_atlas_path() -> String:
	return ATLAS_FOREST


func zone_id() -> String:
	return "village"


func zone_name() -> String:
	return "Последняя деревня"


func music_track() -> String:
	return "music_forest"


func ambience_track() -> String:
	return "ambience_forest"


## Advertise the safe zone before any actor exists, exactly like the forest used
## to: an enemy resolved through the group must honour the boundary from its
## first frame. The forest gave this group up when the village moved out — the
## wild zone promises nothing now.
func _advertise_zone() -> void:
	add_to_group("safe_zone_owner")


## The safe-zone rectangle, exposed so `Enemy` and a test read the exact rect
## the world enforces rather than a copy of its numbers.
func safe_zone_rect() -> Rect2i:
	return SAFE_ZONE_RECT


func is_in_safe_zone(tile: Vector2i) -> bool:
	return SAFE_ZONE_RECT.has_point(tile)


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		["Edrik", "npc", _npc_node],
		["Yorek", "npc", _merchant_node],
		["Bran", "npc", _smith_node],
		["Mila", "npc", _mila_node],
		["Seris", "npc", _seris_node],
		["Alvena", "npc", _alvena_node],
		["ForestGate", "gate", _gate_node],
	]:
		if not is_instance_valid(entry[2]):
			continue
		var node: Node2D = entry[2]
		if node == null:
			continue
		out.append({
			"id": String(entry[0]),
			"kind": String(entry[1]),
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

	# The tree belt just inside the wall, and the southern hedge line with the
	# three gaps that keep the ring road walkable.
	for x in range(1, MAP_W - 1):
		grid[1][x] = "T"
	for x in range(4, 36):
		if x != 10 and x != 20 and x != 30:
			grid[23][x] = "T"

	for rect: Rect2i in DIRT:
		_paint(grid, rect, ",")
	for rect: Rect2i in BUILDINGS:
		_paint(grid, rect, "#")
	for tile: Vector2i in TREES:
		grid[tile.y][tile.x] = "T"

	# The wall gap the east road runs through: the only opening in the ring, and
	# the only way in or out of the village.
	grid[ENTRY_TILE.y][MAP_W - 1] = ","

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


func _paint(grid: Array, rect: Rect2i, ch: String) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			grid[y][x] = ch


func _spawn_actors() -> void:
	player = _instantiate(PLAYER_SCENE, _tile_center(ENTRY_TILE.x, ENTRY_TILE.y), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	# Edrik first, always: the debug bot picks the FIRST node of the
	# `interactable` group, so the quest dialogue has to be the first thing the
	# village offers. The forest inherited this rule from the village and the
	# village keeps owning it now that its headman lives here.
	var npc := _instantiate(NPC_SCENE, _tile_center(EDRIK_TILE.x, EDRIK_TILE.y), "Edrik")
	npc.name = "Edrik"
	_npc_node = npc

	# The merchant joins after Edrik so the quest bots never open the till, and
	# four tiles away so standing at the headman never reaches the shop either.
	var merchant := Merchant.new()
	merchant.name = "Yorek"
	merchant.sprite_texture = load("res://assets/sprites/npc.png")
	merchant.position = _tile_center(YOREK_TILE.x, YOREK_TILE.y)
	add_child(merchant)
	_merchant_node = merchant

	# The smith joins after the merchant, for the same reason and with the same
	# clearance: his forge sits by the east road, five tiles from the headman.
	var smith := Smith.new()
	smith.name = "Bran"
	smith.sprite_texture = load("res://assets/sprites/npc.png")
	smith.position = _tile_center(BRAN_TILE.x, BRAN_TILE.y)
	add_child(smith)
	_smith_node = smith

	var mila := _spawn_villager("Mila", "Травница Мила", "mila",
		PackedStringArray(["q02_gather_fangs", "q03_clear_boars"]), MILA_TILE, Color(0.55, 0.85, 0.55))
	_mila_node = mila
	_seris_node = _spawn_villager("Seris", "Мельник Серис", "seris",
		PackedStringArray(["q09_the_mill"]), SERIS_TILE, Color(0.62, 0.78, 0.95))
	_alvena_node = _spawn_villager("Alvena", "Кожевница Альвена", "alvena",
		PackedStringArray(["q10_armor_fit"]), ALVENA_TILE, Color(0.95, 0.80, 0.55))

	# The way back to the forest. `ZoneExit` owns no overlap handler at all, so
	# nothing travels by walking over it; the key press is the only door.
	var gate := ZoneExit.new()
	gate.name = "ForestGate"
	gate.target_zone = "forest"
	gate.prompt = "В лесной край"
	gate.position = _tile_center(FOREST_GATE_TILE.x, FOREST_GATE_TILE.y)
	add_child(gate)
	_gate_node = gate


## Builds one `Villager` in code (the herbwife's type) and places it on `tile`,
## carrying `quests` as its offer list. A `Sprite2D` child is added before
## `add_child` so the base `Npc`'s `@onready` sprite lookup resolves on the
## first frame, and the per-villager `tint` is applied AFTER `add_child`
## because `Villager._ready` paints every herbwife the same green. Returns the
## live node so the caller can keep it as a landmark/schedule reference.
func _spawn_villager(node_name: String, display: String, speaker: String,
		quests: PackedStringArray, tile: Vector2i, tint: Color) -> Node2D:
	var script: GDScript = load(VILLAGER_SCRIPT)
	if script == null:
		push_error("Village: cannot load %s" % VILLAGER_SCRIPT)
		return null
	var villager: Node2D = script.new() as Node2D
	villager.name = node_name
	villager.set("display_name", display)
	villager.set("speaker_id", speaker)
	villager.set("sprite_texture", load("res://assets/sprites/npc.png"))
	villager.set("quest_ids", quests)
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load("res://assets/sprites/npc.png")
	villager.add_child(spr)
	villager.position = _tile_center(tile.x, tile.y)
	add_child(villager)
	spr.modulate = tint
	return villager


## Builds the day cycle and gives every scheduled villager a
## `ScheduleComponent`. The clock is added first so its `_ready` (which loads
## `data/schedules.json` and seeds the morning phase) runs before any component
## reads `phase()`.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
	_attach_schedule(_npc_node)
	_attach_schedule(_merchant_node)
	_attach_schedule(_smith_node)
	_attach_schedule(_mila_node)
	_attach_schedule(_seris_node)
	_attach_schedule(_alvena_node)
