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


func _ready() -> void:
	_generate_map()
	_build_tileset_and_layer()
	_spawn_actors()
	_configure_camera()


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

	var chest := _instantiate(CHEST_SCENE, _tile_center(MAP_W - 4, 5), "Chest")
	chest.name = "Chest"

	var trap := _instantiate(TRAP_SCENE, _tile_center(24, 9), "Trap")
	trap.name = "Trap"

	_spawn_enemy(WOLF_SCENE, 18, 14, "WolfA")
	_spawn_enemy(WOLF_SCENE, 21, 16, "WolfB")
	_spawn_enemy(WOLF_SCENE, 25, 13, "WolfC")
	_spawn_enemy(WOLF_SCENE, 30, 18, "WolfD")
	_spawn_enemy(WOLF_SCENE, 34, 20, "WolfE")
	_spawn_enemy(WOLF_SCENE, MAP_W - 6, 6, "ArcherA")

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
