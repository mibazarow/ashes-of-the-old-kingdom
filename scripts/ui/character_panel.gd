class_name CharacterPanel
extends PanelContainer
## Character screen (spec §7.1): the four attributes, the derived stats and the
## unspent point pool, spent with the keyboard.
##
## Like SettingsPanel this is its own Control script: it owns its layout and its
## centring, while the HUD opens, closes and gates it and feeds it the same
## InputSource polling every other panel uses, so the debug bot and a human drive
## it through one code path.

const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_ROW_SELECTED := Color(1.0, 0.97, 0.62)
const COLOR_DERIVED := Color(0.78, 0.86, 0.66)
const COLOR_POINTS := Color(0.96, 0.86, 0.5)
const COLOR_HINT := Color(0.6, 0.62, 0.6)

const ATTR_LABELS := {
	"strength": "Сила",
	"agility": "Ловкость",
	"intelligence": "Интеллект",
	"endurance": "Выносливость",
}

var _attr_names: Array[String] = []
var _attr_rows: Array[Label] = []
var _points_label: Label
var _derived_labels: Array[Label] = []
var _selected := 0


func _ready() -> void:
	add_theme_stylebox_override("panel", _panel_style())

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)

	box.add_child(_make_text("Персонаж  [C] закрыть", Color(0.96, 0.86, 0.5)))

	_points_label = _make_text("", COLOR_POINTS)
	box.add_child(_points_label)

	# Two columns: attributes with the cursor on the left, derived stats on the
	# right. One column would double the height for no benefit at 480x270.
	var columns := HBoxContainer.new()
	columns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	columns.add_theme_constant_override("separation", 12)
	box.add_child(columns)

	var left := VBoxContainer.new()
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_theme_constant_override("separation", 1)
	columns.add_child(left)

	_attr_names.assign(GameState.ATTRIBUTE_NAMES)
	for attr_name in _attr_names:
		var row := _make_text("", COLOR_ROW)
		left.add_child(row)
		_attr_rows.append(row)

	var right := VBoxContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_theme_constant_override("separation", 1)
	columns.add_child(right)

	# Five lines: the four combat numbers plus the equipment summary, so the
	# player can see which of the six slots are still empty without opening the
	# inventory.
	for i in 5:
		var line := _make_text("", COLOR_DERIVED)
		right.add_child(line)
		_derived_labels.append(line)

	box.add_child(_make_text("W/S выбор · E вложить очко", COLOR_HINT))
	refresh()
	_center.call_deferred()


## Called by the HUD every time the screen opens.
func open() -> void:
	_selected = 0
	refresh()
	_center()


func refresh() -> void:
	if _points_label == null:
		return
	_points_label.text = "Уровень %d · Очки: %d" % [GameState.level, GameState.attribute_points]
	for i in _attr_rows.size():
		var attr_name := _attr_names[i]
		var selected_row := i == _selected
		var prefix := "> " if selected_row else "  "
		_attr_rows[i].text = "%s%s %d" % [prefix, String(ATTR_LABELS.get(attr_name, attr_name)), GameState.attribute(attr_name)]
		_attr_rows[i].add_theme_color_override(
			"font_color", COLOR_ROW_SELECTED if selected_row else COLOR_ROW)
	_derived_labels[0].text = "Атака %d · Защита %d" % [GameState.total_attack(), GameState.total_defense()]
	_derived_labels[1].text = "HP %d/%d · Мана %d/%d" % [GameState.hp, GameState.max_hp, GameState.mana, GameState.max_mana]
	_derived_labels[2].text = "Крит %d%% · Скорость +%d%%" % [
		int(round(GameState.crit_chance() * 100.0)),
		int(round((GameState.move_speed_multiplier() - 1.0) * 100.0)),
	]
	_derived_labels[3].text = "Сопротивление контролю %d%%" % int(round(GameState.control_resistance() * 100.0))
	# The equipment summary closes the block: how much of the defence shown above
	# is worn rather than earned, and which of the six slots are still empty.
	_derived_labels[4].text = "Экипировано %d/%d · Защита с экипировки +%d" % [
		GameState.equipped_count(),
		GameState.EQUIPMENT_SLOTS.size(),
		GameState.total_bonus("defense"),
	]


## Move the cursor by `step` rows, clamped to the attribute list.
func move_selection(step: int) -> void:
	_selected = clampi(_selected + step, 0, _attr_names.size() - 1)
	refresh()


func selected_attribute() -> String:
	return _attr_names[_selected] if _selected < _attr_names.size() else ""


## E / Enter on the selected row: one point from the pool into the attribute.
## A rejected spend changes nothing on GameState (spend_attribute_point refuses),
## here it only toasts which refusal happened.
func spend_selected_point() -> void:
	var attr_name := selected_attribute()
	if GameState.attribute(attr_name) >= GameState.max_attribute():
		EventBus.toast.emit("Предел характеристики")
		return
	if not GameState.spend_attribute_point(attr_name):
		EventBus.toast.emit("Нет очков")
		return
	refresh()


## The panel is a plain positioned Control inside the HUD root: the container
## sizes it, then it is centred in the viewport, the way SettingsPanel does.
func _center() -> void:
	reset_size()
	var vp := get_viewport_rect().size
	if vp == Vector2.ZERO or size == Vector2.ZERO:
		return
	position = Vector2((vp.x - size.x) * 0.5, (vp.y - size.y) * 0.5)


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
