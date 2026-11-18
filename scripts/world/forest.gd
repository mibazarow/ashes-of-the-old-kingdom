class_name Forest
extends Node2D
## Builds the forest slice at runtime: TileSet from the atlas, collisions,
## props and spawns. Keeps the level data readable instead of a binary .tscn.

const TILE := 16
const ATLAS := "res://assets/sprites/tiles.png"

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const WOLF_SCENE := "res://scenes/enemies/wolf.tscn"
const ARCHER_SCENE := "res://scenes/enemies/archer.tscn"
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

## Radius (in tiles) around the player that counts as explored on the map.
const VISIT_RADIUS := 3

## Tiles the player has seen, keyed by Vector2i. Read-only for the map panel.
var _visited: Dictionary = {}
var _last_visited_tile := Vector2i(-9999, -9999)

## Points of interest kept as live node references so the map can show them
## without fragile path lookups. Populated in _spawn_actors.
var _npc_node: Node2D
var _chest_node: Node2D
var _trap_node: Node2D


func _ready() -> void:
	_generate_map()
	_build_tileset_and_layer()
	_spawn_actors()
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
		["Chest", "chest", _chest_node],
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


func _spawn_actors() -> void:
	player = _instantiate(PLAYER_SCENE, _tile_center(4, 9), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	var npc := _instantiate(NPC_SCENE, _tile_center(7, 9), "Edrik")
	npc.name = "Edrik"
	_npc_node = npc

	var chest := _instantiate(CHEST_SCENE, _tile_center(MAP_W - 4, 5), "Chest")
	chest.name = "Chest"
	_chest_node = chest

	var trap := _instantiate(TRAP_SCENE, _tile_center(24, 9), "Trap")
	trap.name = "Trap"
	_trap_node = trap

	_spawn_enemy(WOLF_SCENE, 18, 14, "WolfA")
	_spawn_enemy(WOLF_SCENE, 21, 16, "WolfB")
	_spawn_enemy(WOLF_SCENE, 25, 13, "WolfC")
	_spawn_enemy(WOLF_SCENE, 30, 18, "WolfD")
	_spawn_enemy(WOLF_SCENE, 34, 20, "WolfE")
	_spawn_enemy(ARCHER_SCENE, MAP_W - 6, 6, "ArcherA")

	_instantiate(PICKUP_SCENE, _tile_center(13, 10), "PickupA")


func _spawn_enemy(scene_path: String, tx: int, ty: int, node_name: String) -> void:
	var e := _instantiate(scene_path, _tile_center(tx, ty), node_name)
	e.name = node_name


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
