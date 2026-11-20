class_name Forest
extends Node2D
## Builds the forest slice at runtime: TileSet from the atlas, collisions,
## props and spawns. Keeps the level data readable instead of a binary .tscn.

const TILE := 16
const ATLAS := "res://assets/sprites/tiles.png"

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const WOLF_SCENE := "res://scenes/enemies/wolf.tscn"
const ARCHER_SCENE := "res://scenes/enemies/archer.tscn"
const BOAR_SCENE := "res://scenes/enemies/boar.tscn"
const WISP_SCENE := "res://scenes/enemies/wisp.tscn"
const FOREST_WARDEN_SCENE := "res://scenes/enemies/forest_warden.tscn"
const NPC_SCENE := "res://scenes/npcs/edrik.tscn"
const CHEST_SCENE := "res://scenes/interactables/chest.tscn"
const TRAP_SCENE := "res://scenes/interactables/spike_trap.tscn"
const PICKUP_SCENE := "res://scenes/items/pickup.tscn"

## Map is generated once from a fixed seed so every run and every test sees the
## same layout, while staying readable instead of a 60-line string literal.
const MAP_W := 52
const MAP_H := 32
const MAP_SEED := 20261107

const TILE_GRASS := 0
const TILE_DIRT := 1
const TILE_STONE := 2
const TILE_TREE := 3

var player: Node2D
var tile_layer: TileMapLayer
var _map: Array[String] = []

## The in-game day cycle driving the villager schedules (spec §12.1). Created as
## a child node rather than an autoload so the world slice owns it and a test gets
## it by instantiating the world scene. Exposed for the HUD and a test to reach.
var day_clock: DayClock

## Radius (in tiles) around the player that counts as explored on the map.
const VISIT_RADIUS := 3

## Tiles the player has seen, keyed by Vector2i. Read-only for the map panel.
var _visited: Dictionary = {}
var _last_visited_tile := Vector2i(-9999, -9999)

## Points of interest kept as live node references so the map can show them
## without fragile path lookups. Populated in _spawn_actors.
var _npc_node: Node2D
var _merchant_node: Node2D
var _smith_node: Node2D
var _chest_node: Node2D
var _chest_spear_node: Node2D
var _trap_node: Node2D

## Fixed anchor for the spear chest, on the south-west side away from the sword
## chest in the east clearing. The exact tile is derived from the generated grid
## (see _find_walkable_near), so the spawn stays deterministic and never lands
## inside a tree cluster.
const SPEAR_CHEST_ANCHOR := Vector2i(12, 24)

## Anchor for the smith's forge, on the road just east of the village clearing.
## He is kept well outside Edrik's interact radius on purpose (see
## `_find_walkable_away`): the debug bot walks up to Edrik and presses E on the
## NEAREST interactable, so a forge within reach would steal the quest dialogue
## and the turn-in and break every quest bot.
const SMITH_ANCHOR := Vector2i(12, 12)

## Tile distance the smith must keep from the quest-giver, the merchant and the
## spawn point. 4 tiles is 64 px against a 26 px interact radius and an 18 px bot
## stop tolerance, so standing at Edrik can never put the forge inside reach.
const SMITH_MIN_SEPARATION := 4

## Anchors for the two new predator types (roadmap stage D), on the east/south
## half of the map: far enough from the wolf pack and the village that the BOT-008
## hunter still reaches a wolf first, far enough from the eastern clearing that
## the cultist stays the only ranged enemy of note there. Each anchor is only a
## starting point — the actual tile comes from `_find_walkable_near`, so a tree
## cluster from the fixed seed can never swallow a spawn.
const BOAR_A_ANCHOR := Vector2i(38, 22)
const BOAR_B_ANCHOR := Vector2i(44, 26)
const WISP_A_ANCHOR := Vector2i(34, 26)
const WISP_B_ANCHOR := Vector2i(41, 18)

## How far the walkable scan looks around a new-enemy anchor before giving up.
## 5 tiles is 80 px against a 2x2 tree cluster, so it always finds the clearing.
const NEW_ENEMY_SCAN_RADIUS := 5

## Anchor for the forest mini-boss (roadmap stage D, spec §10.4). It sits inside
## the east clearing the archer and the sword chest already hold, one tile short
## of the archer's own tile, so the boss guards the same clearing without standing
## on top of the ranged enemy or the chest.
##
## The scan radius here is deliberately 1 rather than `NEW_ENEMY_SCAN_RADIUS`:
## the clearing is carved walkable across the whole rectangle rows 4..7 x
## cols MAP_W-9..MAP_W-2, so a one-tile scan is guaranteed to land inside it,
## while a five-tile scan would just as happily walk out of the clearing toward
## the map border. The tile it picks is (MAP_W - 9, 6) on every run: the anchor,
## the rectangle and the seed are all fixed.
const FOREST_WARDEN_ANCHOR := Vector2i(MAP_W - 8, 7)
const FOREST_WARDEN_SCAN_RADIUS := 1


func _ready() -> void:
	_generate_map()
	_build_tileset_and_layer()
	_spawn_actors()
	_setup_day_cycle()
	_configure_camera()
	_last_visited_tile = player_tile()
	_mark_visited(_last_visited_tile)


func _process(_delta: float) -> void:
	var tile := player_tile()
	if tile == _last_visited_tile:
		return
	_last_visited_tile = tile
	_mark_visited(tile)


func _mark_visited(center: Vector2i) -> void:
	for dy in range(-VISIT_RADIUS, VISIT_RADIUS + 1):
		for dx in range(-VISIT_RADIUS, VISIT_RADIUS + 1):
			var t := Vector2i(center.x + dx, center.y + dy)
			if t.x < 0 or t.y < 0 or t.x >= MAP_W or t.y >= MAP_H:
				continue
			_visited[t] = true


func map_size() -> Vector2i:
	return Vector2i(MAP_W, MAP_H)


func cell_at(tile: Vector2i) -> String:
	if tile.x < 0 or tile.y < 0 or tile.y >= _map.size():
		return ""
	var row: String = _map[tile.y]
	if tile.x >= row.length():
		return ""
	return row[tile.x]


func is_explored(tile: Vector2i) -> bool:
	return _visited.has(tile)


func explored_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for key: Vector2i in _visited.keys():
		out.append(key)
	return out


func player_tile() -> Vector2i:
	if player == null:
		return Vector2i(-1, -1)
	return Vector2i(
		floori(player.global_position.x / float(TILE)),
		floori(player.global_position.y / float(TILE))
	)


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		["Edrik", "npc", _npc_node],
		["Yorek", "npc", _merchant_node],
		["Bran", "npc", _smith_node],
		["Chest", "chest", _chest_node],
		["ChestSpear", "chest", _chest_spear_node],
		["Trap", "trap", _trap_node],
	]:
		var node: Node2D = entry[2]
		if node == null or not is_instance_valid(node):
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
	var rng := RandomNumberGenerator.new()
	rng.seed = MAP_SEED
	var grid: Array = []
	for y in range(MAP_H):
		var row: Array = []
		for x in range(MAP_W):
			var edge := x == 0 or y == 0 or x == MAP_W - 1 or y == MAP_H - 1
			var border := x == 1 or y == 1 or x == MAP_W - 2 or y == MAP_H - 2
			if edge:
				row.append("#")
			elif border and rng.randf() < 0.55:
				row.append("T")
			else:
				row.append(".")
		grid.append(row)

	# A dirt road from the village (west) to the ruins edge (east).
	var road_y := 8
	for x in range(2, MAP_W - 2):
		road_y = clampi(road_y + rng.randi_range(-1, 1), 6, MAP_H - 5)
		for dy in range(0, 2):
			grid[road_y + dy][x] = ","

	# Village clearing around the spawn point.
	for y in range(6, 12):
		for x in range(2, 10):
			grid[y][x] = ","

	# Tree clusters, never on the road or the clearing.
	var clusters := 60
	for i in range(clusters):
		var cx := rng.randi_range(11, MAP_W - 4)
		var cy := rng.randi_range(2, MAP_H - 3)
		if grid[cy][cx] != ".":
			continue
		for dy in range(0, 2):
			for dx in range(0, 2):
				if grid[cy + dy][cx + dx] == ".":
					grid[cy + dy][cx + dx] = "T"

	# A small clearing on the east side for the archer and the chest.
	for y in range(4, 8):
		for x in range(MAP_W - 9, MAP_W - 2):
			if grid[y][x] == "T":
				grid[y][x] = "."

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


func _build_tileset_and_layer() -> void:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_mask(0, 0)

	var src := TileSetAtlasSource.new()
	src.texture = load(ATLAS)
	src.texture_region_size = Vector2i(TILE, TILE)
	# The source has to be registered before tiles are created, otherwise the
	# created TileData does not know about the physics layer added above.
	ts.add_source(src, 0)

	for i in range(4):
		src.create_tile(Vector2i(i, 0))

	var square := PackedVector2Array([
		Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)
	])
	for solid in [TILE_STONE, TILE_TREE]:
		var data := src.get_tile_data(Vector2i(solid, 0), 0)
		data.add_collision_polygon(0)
		data.set_collision_polygon_points(0, 0, square)

	tile_layer = TileMapLayer.new()
	tile_layer.name = "Ground"
	tile_layer.tile_set = ts
	tile_layer.y_sort_enabled = true
	add_child(tile_layer)

	for y in range(_map.size()):
		var row: String = _map[y]
		for x in range(row.length()):
			var ch := row[x]
			var tile := TILE_GRASS
			match ch:
				"#":
					tile = TILE_STONE
				"T":
					tile = TILE_TREE
				",":
					tile = TILE_DIRT
				_:
					tile = TILE_GRASS
			tile_layer.set_cell(Vector2i(x, y), 0, Vector2i(tile, 0))


func _tile_center(x: int, y: int) -> Vector2:
	return Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0)


## First walkable tile (grass "." or dirt ",") scanning row-major outward from
## the anchor, so a prop never spawns inside a tree cluster or a wall. Falls
## back to the anchor when nothing walkable is found in range. Deterministic:
## the scan order depends only on the fixed seed and the fixed anchor.
func _find_walkable_near(anchor: Vector2i, radius: int) -> Vector2i:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var t := Vector2i(anchor.x + dx, anchor.y + dy)
			var ch := cell_at(t)
			if ch == "." or ch == ",":
				return t
	return anchor


## The same outward row-major scan, but a tile that lies within `min_distance`
## tiles of any point in `avoid` (Chebyshev, so the diagonal counts as close too)
## is skipped. The smith needs this where the merchant does not: the player
## interacts with the NEAREST interactable in range, and the debug bot presses E
## the moment it is within its stop tolerance of Edrik, so the forge has to sit
## outside that reach rather than merely on a free tile. Deterministic, like every
## other spawn here: the scan order depends only on the fixed seed and the anchor.
func _find_walkable_away(anchor: Vector2i, radius: int, avoid: Array[Vector2i], min_distance: int) -> Vector2i:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var t := Vector2i(anchor.x + dx, anchor.y + dy)
			var ch := cell_at(t)
			if ch != "." and ch != ",":
				continue
			var too_close := false
			for point: Vector2i in avoid:
				if absi(t.x - point.x) < min_distance and absi(t.y - point.y) < min_distance:
					too_close = true
					break
			if not too_close:
				return t
	return anchor


func _spawn_actors() -> void:
	player = _instantiate(PLAYER_SCENE, _tile_center(4, 9), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	var npc := _instantiate(NPC_SCENE, _tile_center(7, 9), "Edrik")
	npc.name = "Edrik"
	_npc_node = npc

	# The merchant is added after Edrik on purpose: the debug bot picks the first
	# node in the `interactable` group, so Edrik must stay first or the quest bots
	# would open the shop instead of the dialogue. It sits on the village clearing
	# (dirt, walkable, never a tree cluster), far enough from the spawn point that
	# no prompt shows at start and far enough from Edrik that walking to him never
	# comes within the interact radius of the shop.
	var merchant := Merchant.new()
	merchant.name = "Yorek"
	merchant.sprite_texture = load("res://assets/sprites/npc.png")
	merchant.position = _tile_center(3, 11)
	add_child(merchant)
	_merchant_node = merchant

	# The smith joins last among the village NPCs, after Edrik and Yorek, for the
	# same reason the merchant does: the debug bot picks the FIRST node of the
	# `interactable` group, so Edrik must stay first or the quest bots would open a
	# bench instead of the dialogue. His tile is chosen by `_find_walkable_away` so
	# that he is also outside the interact radius of anyone standing at Edrik.
	var smith := Smith.new()
	smith.name = "Bran"
	smith.sprite_texture = load("res://assets/sprites/npc.png")
	var smith_tile := _find_walkable_away(
		SMITH_ANCHOR, 4, [Vector2i(7, 9), Vector2i(3, 11), Vector2i(4, 9)], SMITH_MIN_SEPARATION)
	smith.position = _tile_center(smith_tile.x, smith_tile.y)
	add_child(smith)
	_smith_node = smith

	var chest := _instantiate(CHEST_SCENE, _tile_center(MAP_W - 4, 5), "Chest")
	chest.name = "Chest"
	_chest_node = chest

	# Second chest, on the south-west side, holding the iron spear. The chest
	# scene is reused (not a new scene); its loot is overridden before add_child
	# so _ready() reads this chest's own opened flag, not the sword chest's.
	var spear_tile := _find_walkable_near(SPEAR_CHEST_ANCHOR, 6)
	var spear_packed: PackedScene = load(CHEST_SCENE)
	var chest_spear := spear_packed.instantiate() as Node2D
	chest_spear.name = "ChestSpear"
	chest_spear.position = _tile_center(spear_tile.x, spear_tile.y)
	chest_spear.set("chest_id", "chest_forest_02")
	chest_spear.set("item_id", "iron_spear")
	chest_spear.set("gold", 0)
	add_child(chest_spear)
	_chest_spear_node = chest_spear

	var trap := _instantiate(TRAP_SCENE, _tile_center(24, 9), "Trap")
	trap.name = "Trap"
	_trap_node = trap

	_spawn_enemy(WOLF_SCENE, 18, 14, "WolfA")
	_spawn_enemy(WOLF_SCENE, 21, 16, "WolfB")
	_spawn_enemy(WOLF_SCENE, 25, 13, "WolfC")
	_spawn_enemy(WOLF_SCENE, 30, 18, "WolfD")
	_spawn_enemy(WOLF_SCENE, 34, 20, "WolfE")
	_spawn_enemy(ARCHER_SCENE, MAP_W - 6, 6, "ArcherA")

	# The two new types differ from a wolf by behaviour, not only by numbers: the
	# boar spots the player from 1.5x the sight line, charges at 1.35x the speed
	# and lands a longer, heavier, less frequent swing, while the wisp is a fragile
	# caster that kites at 1.5x speed and fires a short-telegraph shot often.
	# Their tiles come from the generated grid instead of hardcoded coordinates.
	_spawn_enemy_walkable(BOAR_SCENE, BOAR_A_ANCHOR, "BoarA")
	_spawn_enemy_walkable(BOAR_SCENE, BOAR_B_ANCHOR, "BoarB")
	_spawn_enemy_walkable(WISP_SCENE, WISP_A_ANCHOR, "WispA")
	_spawn_enemy_walkable(WISP_SCENE, WISP_B_ANCHOR, "WispB")

	# The mini-boss goes last among the enemies on purpose. It is the only enemy
	# of its type, it owns the far east corner, and its `boss` group is what the
	# HUD looks up for the boss bar — so nothing else in the world can shadow it.
	# It is also added after every other spawn so a debug bot that walks at the
	# nearest enemy still reaches a wolf first: the boss is ~39 tiles from the
	# player spawn, well outside the 230 px leash its own post allows.
	_spawn_enemy_walkable(FOREST_WARDEN_SCENE, FOREST_WARDEN_ANCHOR, "ForestWarden",
		FOREST_WARDEN_SCAN_RADIUS)

	_instantiate(PICKUP_SCENE, _tile_center(13, 10), "PickupA")


func _spawn_enemy(scene_path: String, tx: int, ty: int, node_name: String) -> void:
	var e := _instantiate(scene_path, _tile_center(tx, ty), node_name)
	e.name = node_name


## `_spawn_enemy` for a spawn whose tile is derived from the generated grid rather
## than hardcoded: the anchor is snapped to the nearest walkable tile by the same
## deterministic outward scan the chests use, so a solid tile (stone or a tree)
## can never take an enemy. Deterministic like every other spawn here, because the
## scan order depends only on the fixed seed and the fixed anchor.
func _spawn_enemy_walkable(scene_path: String, anchor: Vector2i, node_name: String, radius: int = NEW_ENEMY_SCAN_RADIUS) -> void:
	var tile := _find_walkable_near(anchor, radius)
	_spawn_enemy(scene_path, tile.x, tile.y, node_name)


func _instantiate(scene_path: String, pos: Vector2, node_name: String) -> Node2D:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("Forest: cannot load %s" % scene_path)
		return null
	var inst := packed.instantiate() as Node2D
	inst.position = pos
	add_child(inst)
	inst.name = node_name
	return inst


func _configure_camera() -> void:
	if player == null:
		return
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = MAP_W * TILE
	cam.limit_bottom = MAP_H * TILE
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 7.0
	cam.make_current()


## Builds the day cycle and gives every scheduled villager a `ScheduleComponent`.
## The clock is added first so its `_ready` (which loads `data/schedules.json` and
## seeds the morning phase) runs before any component reads `phase()`. The smith
## keeps his forge tile: his schedule morning spot is the tile `_find_walkable_away`
## already chose, so attaching a schedule never drags him into the village and
## never breaks the separation that keeps the quest bots talking to Edrik.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
	_attach_schedule(_npc_node)
	_attach_schedule(_merchant_node)
	_attach_schedule(_smith_node)


func _attach_schedule(npc: Node2D) -> void:
	if npc == null or not is_instance_valid(npc):
		return
	var comp := ScheduleComponent.new()
	comp.name = "ScheduleComponent"
	comp.setup(npc, self, day_clock)
	npc.add_child(comp)
