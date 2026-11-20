class_name SkillsPanel
extends PanelContainer
## Skills screen (spec §16.1): every school, every skill with its cost, damage and
## effect, which are known versus locked, the active skill, and learning a new one
## for a skill point.
##
## Like `CharacterPanel` this is its own Control script: it owns its layout and its
## centring, while the HUD opens, closes and gates it and feeds it the same
## `InputSource` polling every other panel uses, so the debug bot and a human drive
## it through one code path. It reads `GameState` and `SkillDB` directly and holds
## no skill data of its own, so the numbers on screen are always the ones the cast
## would actually use.
##
## Layout decision — a single flat list grouped by school with one `>` cursor, not
## four Tab-cycled school tabs. At 480x270 a tab bar plus a per-school sublist hides
## six of the eight skills behind keypresses, while §16.1 asks the player to see the
## schools, costs and effects together; the flat grouped list shows all eight and
## their lock state at a glance, and `move_up`/`move_down` walk the eight selectable
## rows directly with the school names as non-selectable separators. That keeps the
## cursor model identical to the inventory/character/shop panels (one clamped index),
## so the HUD reuses its existing navigation polling verbatim.

const COLOR_HEADER := Color(0.96, 0.86, 0.5)
const COLOR_SCHOOL := Color(0.72, 0.78, 0.66)
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_ROW_SELECTED := Color(1.0, 0.97, 0.62)
const COLOR_LOCKED := Color(0.55, 0.57, 0.55)
const COLOR_POINTS := Color(0.96, 0.86, 0.5)
const COLOR_DETAIL := Color(0.78, 0.86, 0.66)
const COLOR_DESC := Color(0.86, 0.88, 0.8)
const COLOR_HINT := Color(0.6, 0.62, 0.6)

## Russian school names, keyed by the school id in data/skills.json. An unknown id
## falls back to the raw id rather than a blank, so a data typo is visible.
const SCHOOL_LABELS_RU := {
	"fire": "Огонь",
	"ice": "Лёд",
	"lightning": "Молния",
	"nature": "Природа",
}

## One safe geometric glyph per school (same family as the item icons, so the
## project font renders it). Used as the leading marker of every skill row.
const SCHOOL_MARKERS := {
	"fire": "◆",
	"ice": "◇",
	"lightning": "▲",
	"nature": "●",
}

## Russian shape names (spec §9): what the skill actually does on cast.
const SHAPE_LABELS_RU := {
	"projectile": "снаряд",
	"aoe": "по области",
	"self": "на себя",
}

## Russian status names for the effect line. An unknown id shows its raw id rather
## than nothing, so a new status is visible in the UI instead of silently missing.
const STATUS_LABELS_RU := {
	"burn": "Горение",
	"chill": "Замедление",
	"shock": "Оцепенение",
	"root": "Обездвиживание",
	"blight": "Порча",
	"stun": "Оглушение",
}

var _ids: Array[String] = []
var _selected := 0
var _title_label: Label
var _points_label: Label
var _list: VBoxContainer
var _stats_label: Label
var _range_label: Label
var _desc_label: Label


func _ready() -> void:
	add_theme_stylebox_override("panel", _panel_style())

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	box.add_child(_make_text("Навыки  [K] закрыть", COLOR_HEADER))

	_points_label = _make_text("", COLOR_POINTS)
	box.add_child(_points_label)

	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 1)
	box.add_child(_list)

	# Detail block for the row the cursor is on, outside the list so the row count
	# stays fixed. Three short lines: the numbers, the reach, the description.
	_stats_label = _make_text("", COLOR_DETAIL)
	box.add_child(_stats_label)

	_range_label = _make_text("", COLOR_DETAIL)
	box.add_child(_range_label)

	_desc_label = _make_text("", COLOR_DESC)
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.max_lines_visible = 2
	_desc_label.custom_minimum_size = Vector2(260, 0)
	box.add_child(_desc_label)

	box.add_child(_make_text("↑↓ выбор · E выбрать · L выучить · Esc закрыть", COLOR_HINT))

	_ids = _collect_ids()
	refresh()
	_center.call_deferred()


## Called by the HUD every time the screen opens. The cursor parks on the skill the
## right mouse button currently casts, so the screen opens already showing the active
## skill rather than always the first row.
func open() -> void:
	_ids = _collect_ids()
	_selected = _ids.find(GameState.selected_skill)
	if _selected < 0:
		_selected = 0
	refresh()
	_center()


## The eight skill ids in grouped order: every school of `SkillDB.schools()` with
## its skills in declaration order. Grouping here (not in the renderer) is what lets
## the cursor index the selectable rows directly while the renderer still interleaves
## the school headers as separators.
func _collect_ids() -> Array[String]:
	var ids: Array[String] = []
	for school in SkillDB.schools():
		for id in SkillDB.skills_of_school(school):
			ids.append(String(id))
	return ids


func refresh() -> void:
	if _list == null:
		return
	_points_label.text = "Очки навыков: %d" % GameState.skill_points
	for child in _list.get_children():
		child.queue_free()
	if _ids.is_empty():
		_list.add_child(_make_text("нет навыков", COLOR_LOCKED))
		_render_detail("")
		return
	_selected = clampi(_selected, 0, _ids.size() - 1)
	var previous_school := ""
	for i in range(_ids.size()):
		var id := _ids[i]
		var school := String(SkillDB.get_skill(id).get("school", ""))
		if school != previous_school:
			previous_school = school
			_list.add_child(_make_text(
				"— %s —" % String(SCHOOL_LABELS_RU.get(school, school)), COLOR_SCHOOL))
		_list.add_child(_make_row(id, i == _selected))
	_render_detail(_ids[_selected])


func _make_row(id: String, selected_row: bool) -> Label:
	var skill := SkillDB.get_skill(id)
	var school := String(skill.get("school", ""))
	var marker := String(SCHOOL_MARKERS.get(school, "·"))
	var known := GameState.known_skills.has(id)
	var active := known and id == GameState.selected_skill
	var line := "%s %s  %d маны · КД %s с" % [
		marker,
		String(skill.get("name", id)),
		int(skill.get("mana", 0)),
		_num(float(skill.get("cooldown", 0.0))),
	]
	var color := COLOR_ROW
	if active:
		line += "  [выбрано]"
	elif known:
		line += "  [изучено]"
	else:
		line += "  [закрыто]"
		color = COLOR_LOCKED
	if selected_row:
		line = "> " + line
		color = COLOR_ROW_SELECTED if known else color.lightened(0.2)
	return _make_text(line, color)


## The detail block for one skill: school and shape, the numbers (damage / heal /
## barrier and any status), the reach, and the description. An empty id (no rows)
## clears the whole block.
func _render_detail(id: String) -> void:
	if id == "":
		_stats_label.text = ""
		_range_label.text = ""
		_desc_label.text = ""
		return
	var skill := SkillDB.get_skill(id)
	var school := String(skill.get("school", ""))
	var shape := String(skill.get("shape", ""))
	var head := "Школа: %s · %s" % [
		String(SCHOOL_LABELS_RU.get(school, school)),
		String(SHAPE_LABELS_RU.get(shape, shape)),
	]
	var parts: PackedStringArray = []
	var damage := int(skill.get("damage", 0))
	var heal := int(skill.get("heal", 0))
	var barrier := int(skill.get("barrier", 0))
	if damage > 0:
		parts.append("Урон %d" % damage)
	if heal > 0:
		parts.append("Лечение %d" % heal)
	if barrier > 0:
		parts.append("Барьер %d%%" % barrier)
	var status := String(skill.get("status", ""))
	if status != "":
		parts.append("Эффект: %s %s с" % [
			String(STATUS_LABELS_RU.get(status, status)),
			_num(float(skill.get("status_duration", 0.0))),
		])
	_stats_label.text = head if parts.is_empty() else "%s  ·  %s" % [head, " · ".join(parts)]

	var reach: PackedStringArray = []
	var skill_range := int(skill.get("range", 0))
	var radius := int(skill.get("radius", 0))
	if skill_range > 0:
		reach.append("Дальность %d" % skill_range)
	if radius > 0:
		reach.append("Радиус %d" % radius)
	_range_label.text = " · ".join(reach)
	_range_label.visible = not reach.is_empty()

	_desc_label.text = String(skill.get("description", ""))


func move_selection(step: int) -> void:
	if _ids.is_empty():
		_selected = 0
		return
	_selected = clampi(_selected + step, 0, _ids.size() - 1)
	refresh()


## Test/screenshot hook: parks the cursor on one row without simulating keys.
func select_row(index: int) -> void:
	_selected = clampi(index, 0, maxi(0, _ids.size() - 1))
	refresh()


func selected_index() -> int:
	return _selected


func selected_skill_id() -> String:
	return _ids[_selected] if _selected >= 0 and _selected < _ids.size() else ""


## E / Enter on the selected row. A known skill becomes the one the right mouse
## button casts (`GameState.select_skill`, which emits `skill_selected` so the HUD
## line refreshes); a locked skill only toasts that it is not learned and changes
## nothing.
func activate() -> void:
	var id := selected_skill_id()
	if id == "":
		return
	var skill_name := String(SkillDB.get_skill(id).get("name", id))
	if GameState.known_skills.has(id):
		if GameState.select_skill(id):
			EventBus.toast.emit("Умение: %s" % skill_name)
		refresh()
	else:
		EventBus.toast.emit("%s — не изучено" % skill_name)


## L on the selected row: spend one skill point to learn a locked skill. A skill
## already known is a no-op (it must not burn a point); a refused learn — which here
## can only mean an empty pool — toasts the reason. `learn_skill` is the single place
## that decides whether a point is available and spends it, so the panel never
## double-counts.
func learn_selected() -> void:
	var id := selected_skill_id()
	if id == "":
		return
	if GameState.known_skills.has(id):
		EventBus.toast.emit("Уже изучено")
		return
	var skill_name := String(SkillDB.get_skill(id).get("name", id))
	if not GameState.learn_skill(id):
		EventBus.toast.emit("Нет очков навыков")
		return
	EventBus.toast.emit("Изучено: %s" % skill_name)
	refresh()


# --- read-only views for tests and the screenshot probe ----------------------

func row_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	if _list == null:
		return out
	for child in _list.get_children():
		if child is Label:
			out.append((child as Label).text)
	return out


func detail_text() -> String:
	var parts: PackedStringArray = []
	if _stats_label != null and _stats_label.text != "":
		parts.append(_stats_label.text)
	if _range_label != null and _range_label.visible and _range_label.text != "":
		parts.append(_range_label.text)
	if _desc_label != null and _desc_label.text != "":
		parts.append(_desc_label.text)
	return "\n".join(parts)


func points_text() -> String:
	return _points_label.text if _points_label != null else ""


func _center() -> void:
	reset_size()
	var vp := get_viewport_rect().size
	if vp == Vector2.ZERO or size == Vector2.ZERO:
		return
	position = Vector2((vp.x - size.x) * 0.5, (vp.y - size.y) * 0.5)


## Trims a trailing `.0` so a whole cooldown reads "8" not "8.0", while a fractional
## one keeps its decimal ("0.9"). JSON yields float for every number, so this is what
## keeps the row compact without losing the real value.
func _num(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return String.num(value)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.97)
	sb.border_color = Color(0.32, 0.34, 0.38, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	return sb


func _make_text(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
