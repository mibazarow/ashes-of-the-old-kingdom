class_name MapPanel
extends Control
## Schematic zone map: explored tiles, discovered landmarks and the player.
## Built and drawn entirely in code, matching the rest of the HUD.

const PX := 4.0
const MARKER := 3.0

const COLOR_BG := Color(0.05, 0.06, 0.08, 0.96)
const COLOR_BORDER := Color(0.32, 0.34, 0.38, 0.9)
const COLOR_GRASS := Color(0.24, 0.34, 0.22)
const COLOR_DIRT := Color(0.42, 0.36, 0.24)
const COLOR_STONE := Color(0.16, 0.17, 0.19)
const COLOR_TREE := Color(0.20, 0.16, 0.12)
const COLOR_NPC := Color(0.95, 0.80, 0.35)
const COLOR_CHEST := Color(0.98, 0.84, 0.30)
const COLOR_TRAP := Color(0.85, 0.25, 0.22)
const COLOR_PLAYER := Color(0.90, 1.0, 1.0)

var _world: Node = null
var _size_tiles := Vector2i(52, 32)
var _title: Label


func setup(world: Node) -> void:
	_world = world
	if _world != null and _world.has_method("map_size"):
		_size_tiles = _world.call("map_size")
	custom_minimum_size = Vector2(_size_tiles.x * PX, _size_tiles.y * PX)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_title = Label.new()
	_title.text = "Карта  [M] закрыть"
	_title.add_theme_color_override("font_color", Color(0.96, 0.86, 0.5))
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_title.add_theme_constant_override("shadow_offset_x", 1)
	_title.add_theme_constant_override("shadow_offset_y", 1)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title)


func _ready() -> void:
	_center()
	if _title != null:
		_title.reset_size()
		_title.position = Vector2(0, -_title.size.y - 1)


func _center() -> void:
	var vp := get_viewport_rect().size
	if vp == Vector2.ZERO:
		return
	position = Vector2((vp.x - size.x) * 0.5, (vp.y - size.y) * 0.5)


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BORDER, false, 1.0)

	if _world == null or not is_instance_valid(_world):
		return
	if not _world.has_method("explored_tiles"):
		return

	var tiles: Array = _world.call("explored_tiles")
	for t in tiles:
		var tile: Vector2i = t
		var ch: String = _world.call("cell_at", tile)
		var color := Color.TRANSPARENT
		match ch:
			".":
				color = COLOR_GRASS
			",":
				color = COLOR_DIRT
			"#":
				color = COLOR_STONE
			"T":
				color = COLOR_TREE
			_:
				continue
		draw_rect(Rect2(Vector2(tile.x * PX, tile.y * PX), Vector2(PX, PX)), color)

	if _world.has_method("landmarks"):
		var lms: Array = _world.call("landmarks")
		for lm in lms:
			var entry: Dictionary = lm
			var tile: Vector2i = entry.get("tile", Vector2i(-1, -1))
			if not bool(_world.call("is_explored", tile)):
				continue
			var color := Color.TRANSPARENT
			match String(entry.get("kind", "")):
				"npc":
					color = COLOR_NPC
				"chest":
					color = COLOR_CHEST
				"trap":
					color = COLOR_TRAP
				_:
					continue
			_draw_marker(tile, color)

	if _world.has_method("player_tile"):
		_draw_marker(_world.call("player_tile"), COLOR_PLAYER)


func _draw_marker(tile: Vector2i, color: Color) -> void:
	if tile.x < 0 or tile.y < 0:
		return
	var offset := (PX - MARKER) * 0.5
	draw_rect(
		Rect2(Vector2(tile.x * PX + offset, tile.y * PX + offset), Vector2(MARKER, MARKER)),
		color
	)
