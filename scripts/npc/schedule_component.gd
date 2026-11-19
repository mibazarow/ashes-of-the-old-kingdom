class_name ScheduleComponent
extends Node
## Drives one villager's day schedule (spec §12.1): the NPC stands at the spot
## its `data/schedules.json` entry names for the current `DayClock` phase.
##
## Attached in code by `Forest` to each scheduled NPC (Edrik, Yorek, Bran), so no
## .tscn changes and the base NPC types stay exactly as they are.
##
## Movement is a real walk, not a teleport: the NPC follows a breadth-first path
## over walkable tiles (grass/dirt) recomputed for every phase change, so it can
## never cut across a wall or a tree. The base NPCs are `Area2D` (the quest-giver
## scene and the code-built merchant/smith), and converting all three to
## `CharacterBody2D` would mean editing `edrik.tscn` and both NPC scripts — more
## invasive than the task allows — so instead of relying on `move_and_slide`
## collision we move the body tile-by-tile along a path whose every tile is
## validated with `Forest.cell_at` before it is ever stepped on. The result is the
## same guarantee: the NPC is never inside a solid tile.

const TILE := 16  # matches Forest.TILE; used to convert position <-> tile.
const WALK_SPEED := 40.0  # px/s; a village-crossing walk finishes in a couple of seconds.
const ARRIVE_PX := 3.0  # how close counts as "reached this waypoint".
const WALK_TIMEOUT := 12.0  # seconds before a stalled walk snaps to safe ground.

var _npc: Node2D
var _world: Node
var _clock: Node
var _schedule: Dictionary = {}
var _home := Vector2i.ZERO
var _current_phase := ""
var _current_spot := Vector2i.ZERO

var _path: Array[Vector2i] = []
var _target_tile := Vector2i.ZERO
var _last_walkable_tile := Vector2i.ZERO
var _walk_left := 0.0
var _walking := false


func _ready() -> void:
	set_physics_process(false)
	if _npc == null or _world == null or _clock == null:
		return
	var all: Variant = _clock.call("schedules").get("npcs", {})
	if not (all is Dictionary):
		return
	var entry: Variant = (all as Dictionary).get(_npc.name, null)
	if not (entry is Dictionary):
		return
	_schedule = entry as Dictionary
	_home = _read_tile(_schedule.get("home", null))
	_current_phase = String(_clock.call("phase"))
	# Start the day at the morning spot. The morning spot is the tile `Forest`
	# already spawned the NPC on, so this snap is a no-op in practice; it is here
	# so "starts at the morning spot" holds even if the spawn and data drift.
	var morning := _spot_for("morning")
	if morning != Vector2i.ZERO or _schedule.get("spots", {}).get("morning", null) != null:
		# A solid morning spot must not teleport the NPC inside a wall: keep it on
		# the tile the world spawned it on and report the bad data instead.
		if _is_walkable(morning):
			_current_spot = morning
			_snap_to(morning)
		else:
			push_warning("ScheduleComponent: %s morning spot %s is solid, staying put" % [_npc.name, str(morning)])
	if _clock.has_signal("phase_changed"):
		_clock.phase_changed.connect(_on_phase_changed)


## Wires the component to its NPC, the world (for `cell_at`) and the day clock.
## Called by `Forest` right after creating the component, before it enters the tree.
func setup(npc: Node2D, world: Node, clock: Node) -> void:
	_npc = npc
	_world = world
	_clock = clock


## The tile this NPC is scheduled to occupy for the current phase. Matches the
## data the moment a phase is forced, independent of how far the walk still has to
## go, so a test can assert the assignment without waiting for arrival.
func current_spot() -> Vector2i:
	return _current_spot


func current_phase() -> String:
	return _current_phase


func _on_phase_changed(phase: String) -> void:
	_current_phase = phase
	_current_spot = _spot_for(phase)
	_go_to(_current_spot)


## Walks the NPC to `tile`. A solid (or off-map) target is refused: the NPC stays
## put and a warning is logged, rather than being placed inside a wall.
func _go_to(tile: Vector2i) -> void:
	if _npc == null or _world == null:
		return
	if not _is_walkable(tile):
		push_warning("ScheduleComponent: %s target %s is solid, staying at %s" % [_npc.name, str(tile), str(_home)])
		return
	var from := _tile_of(_npc.global_position)
	if from == tile:
		_snap_to(tile)
		return
	var found := _bfs_path(from, tile)
	if found.is_empty():
		var safe := _nearest_walkable(tile)
		# `_nearest_walkable` returns a solid tile only when nothing walkable exists
		# anywhere near; in that case stay put rather than stand the NPC in a wall.
		if not _is_walkable(safe):
			push_warning("ScheduleComponent: %s cannot path %s -> %s and no walkable tile is near, staying at %s" % [_npc.name, str(from), str(tile), str(from)])
			return
		push_warning("ScheduleComponent: %s cannot path %s -> %s, snapping to %s" % [_npc.name, str(from), str(tile), str(safe)])
		_snap_to(safe)
		return
	_path = found
	_target_tile = tile
	_last_walkable_tile = from
	_walk_left = WALK_TIMEOUT
	_walking = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	# A modal UI or a pause must freeze the villagers just like it freezes the
	# clock; the walk resumes where it stopped.
	if GameState.ui_blocking:
		return
	if not _walking or _path.is_empty():
		_end_walk()
		return
	_walk_left -= delta
	if _walk_left <= 0.0:
		push_warning("ScheduleComponent: %s walk to %s timed out, snapping to %s" % [_npc.name, str(_target_tile), str(_last_walkable_tile)])
		_snap_to(_last_walkable_tile)
		_end_walk()
		return
	var next_center := _tile_center(_path[0])
	var to_next := next_center - _npc.global_position
	var step := WALK_SPEED * delta
	if to_next.length() <= maxf(step, ARRIVE_PX):
		_npc.global_position = next_center
		_last_walkable_tile = _path[0]
		_path.remove_at(0)
		if _path.is_empty():
			_npc.global_position = _tile_center(_target_tile)
			_end_walk()
	else:
		_npc.global_position = _npc.global_position + to_next.normalized() * step


func _end_walk() -> void:
	_walking = false
	_path = []
	set_physics_process(false)


## Breadth-first search over 4-connected walkable tiles. Returns the path from
## `from` (exclusive) to `to` (inclusive), or an empty array when unreachable.
## Deterministic: the neighbour order is fixed.
func _bfs_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not _is_walkable(from) or not _is_walkable(to):
		return empty
	if from == to:
		return [to]
	var came_from: Dictionary = {}
	var frontier: Array[Vector2i] = [from]
	var visited: Dictionary = {from: true}
	var head := 0
	while head < frontier.size():
		var cur: Vector2i = frontier[head]
		head += 1
		for dir: Vector2i in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			var nxt: Vector2i = cur + dir
			if visited.has(nxt) or not _is_walkable(nxt):
				continue
			visited[nxt] = true
			came_from[nxt] = cur
			if nxt == to:
				return _reconstruct(came_from, from, to)
			frontier.append(nxt)
	return empty


func _reconstruct(came_from: Dictionary, from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var reversed: Array[Vector2i] = []
	var cur := to
	while cur != from:
		reversed.append(cur)
		cur = came_from[cur]
	reversed.reverse()
	return reversed


func _snap_to(tile: Vector2i) -> void:
	if _npc == null:
		return
	_npc.global_position = _tile_center(tile)
	_last_walkable_tile = tile


## Returns a tile the NPC can safely stand on, in priority order: its `home`
## tile, the tile it currently occupies, then `tile` itself, then the nearest
## walkable tile around `tile`. It returns `tile` (possibly solid) only as a last
## resort when nothing walkable exists at all — callers must re-check
## `_is_walkable` and stay put rather than snap onto that sentinel.
func _nearest_walkable(tile: Vector2i) -> Vector2i:
	if _is_walkable(_home):
		return _home
	if _npc != null:
		var current := _tile_of(_npc.global_position)
		if _is_walkable(current):
			return current
	if _is_walkable(tile):
		return tile
	for radius in range(1, 6):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var t := Vector2i(tile.x + dx, tile.y + dy)
				if _is_walkable(t):
					return t
	return tile


func _spot_for(phase: String) -> Vector2i:
	var spots: Variant = _schedule.get("spots", null)
	if spots is Dictionary and (spots as Dictionary).has(phase):
		return _read_tile((spots as Dictionary).get(phase, null))
	return _home


func _read_tile(raw: Variant) -> Vector2i:
	if raw is Array:
		var arr: Array = raw as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	return Vector2i.ZERO


func _tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / float(TILE)), floori(pos.y / float(TILE)))


func _tile_center(tile: Vector2i) -> Vector2:
	return Vector2(tile.x * TILE + TILE / 2.0, tile.y * TILE + TILE / 2.0)


func _is_walkable(tile: Vector2i) -> bool:
	if _world == null or not _world.has_method("cell_at"):
		return false
	var cell: String = String(_world.call("cell_at", tile))
	return cell == "." or cell == ","
