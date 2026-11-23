extends SceneTree
## Read-only critic probe #7: tilemap integrity and reachability per zone.
## Flood-fills the live `_map` grid from the player's tile and reports walkable
## tiles that the player can never reach, plus unpainted cells in the tile layer.
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_reach.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)
	for i in 5:
		await process_frame
	var manager := _scene.get_node_or_null("ZoneManager")
	for zone in ["forest", "ruins", "dungeon", "fortress"]:
		manager.call("travel", String(zone))
		for i in 5:
			await process_frame
		_check(_scene.get_node_or_null("World"), String(zone))
	quit(0)


func _check(world: Node, tag: String) -> void:
	if world == null:
		return
	var map: PackedStringArray = world.get("_map")
	var w: int = int(world.get("_map_width"))
	var h: int = int(world.get("_map_height"))
	if map.size() != h:
		print("REACH[%s] SKIP map rows=%d height=%d" % [tag, map.size(), h])
		return
	var solid := {}
	var walkable := 0
	for y in range(h):
		var row := map[y]
		for x in range(w):
			var ch := row[x] if x < row.length() else "#"
			if ch == "#" or ch == "T":
				solid[Vector2i(x, y)] = true
			else:
				walkable += 1
	# unpainted cells: the tile layer must cover the whole grid
	var layer := world.get_node_or_null("Ground")
	var unpainted := 0
	if layer != null:
		for y in range(h):
			for x in range(w):
				if int(layer.get_cell_source_id(Vector2i(x, y))) < 0:
					unpainted += 1
	# start from the player's tile
	var player := get_first_node_in_group("player")
	if player == null:
		print("REACH[%s] SKIP no player" % tag)
		return
	var tile_px := 16.0
	var start := Vector2i(int(floor(player.global_position.x / tile_px)),
		int(floor(player.global_position.y / tile_px)))
	var seen := {}
	var queue: Array[Vector2i] = [start]
	seen[start] = true
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
				continue
			if seen.has(n) or solid.has(n):
				continue
			seen[n] = true
			queue.append(n)
	var unreachable := 0
	var sealed := 0
	var samples: Array[String] = []
	for y in range(h):
		for x in range(w):
			var p := Vector2i(x, y)
			if solid.has(p):
				continue
			if not seen.has(p):
				unreachable += 1
				var open_neighbours := 0
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = p + d
					if n.x >= 0 and n.y >= 0 and n.x < w and n.y < h and not solid.has(n):
						open_neighbours += 1
				if open_neighbours == 0:
					sealed += 1
				if samples.size() < 8:
					samples.append("%d,%d(open=%d)" % [x, y, open_neighbours])
	print("REACH[%s] grid=%dx%d walkable=%d reachable=%d unreachable=%d sealed_by_solids=%d unpainted=%d start=%s samples=%s" % [
		tag, w, h, walkable, seen.size(), unreachable, sealed, unpainted, str(start), str(samples)
	])
