class_name SettingsPanel
extends PanelContainer
## Key rebinding screen (spec §6), opened from the pause panel only.
##
## Rebinding has to see every raw key and mouse button, including inputs no
## action owns yet, so this screen reads real InputEvents. The debug bot
## drives InputSource overrides instead of real events, so it can never reach
## this screen; the HUD also keeps it closed unless the player opens it.

signal closed

const VISIBLE_ROWS := 8

const ACTION_LABELS := {
	"move_up": "Движение вверх",
	"move_down": "Движение вниз",
	"move_left": "Движение влево",
	"move_right": "Движение вправо",
	"attack": "Атака",
	"dash": "Рывок",
	"interact": "Действие",
	"inventory": "Инвентарь",
	"journal": "Журнал",
	"map": "Карта",
	"pause": "Пауза",
	"ability": "Умение",
	"quick_slot_1": "Слот 1",
	"quick_slot_2": "Слот 2",
	"quick_slot_3": "Слот 3",
	"quick_slot_4": "Слот 4",
}

var _rows: Array[Label] = []
var _status: Label
var _selected := 0
var _top := 0


func _ready() -> void:
	custom_minimum_size = Vector2(224, 0)
	add_theme_stylebox_override("panel", _panel_style())

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	box.add_child(_make_text("Настройки управления", Color(0.96, 0.86, 0.5)))

	var rows_box := VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 0)
	box.add_child(rows_box)
	for i in VISIBLE_ROWS:
		var row := _make_text("", Color(0.9, 0.92, 0.86))
		row.custom_minimum_size = Vector2(208, 10)
		rows_box.add_child(row)
		_rows.append(row)

	_status = _make_text("", Color(0.98, 0.84, 0.42))
	_status.custom_minimum_size = Vector2(208, 10)
	box.add_child(_status)

	box.add_child(_make_text("стрелки выбор · колесо прокрутка", Color(0.6, 0.62, 0.6)))
	box.add_child(_make_text("клавиша или кнопка мыши — назначить", Color(0.6, 0.62, 0.6)))
	box.add_child(_make_text("R сброс выбранного · Esc выход", Color(0.6, 0.62, 0.6)))
	_refresh()
	_center.call_deferred()


## The panel is a plain positioned Control: the container sizes it, then it is
## centred in the viewport, the same way MapPanel places itself.
func _center() -> void:
	reset_size()
	var vp := get_viewport_rect().size
	if vp == Vector2.ZERO or size == Vector2.ZERO:
		return
	position = Vector2((vp.x - size.x) * 0.5, (vp.y - size.y) * 0.5)


## Called by the HUD every time the screen opens.
func open() -> void:
	_status.text = ""
	_refresh()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if not mouse.pressed:
			return
		if mouse.button_index == MOUSE_BUTTON_WHEEL_UP or mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var step := 1 if mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			_top = clampi(_top + step, 0, maxi(0, InputBindings.REBINDABLE.size() - VISIBLE_ROWS))
			_refresh()
		else:
			_try_bind(mouse)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		_on_key(event as InputEventKey)
		get_viewport().set_input_as_handled()


func _on_key(key: InputEventKey) -> void:
	match key.physical_keycode:
		KEY_ESCAPE, KEY_BACKSPACE:
			closed.emit()
		KEY_UP:
			_move_selection(-1)
		KEY_DOWN:
			_move_selection(1)
		KEY_R:
			var action := _current_action()
			InputBindings.reset_action(action)
			_status.text = "Сброшено: %s" % _label(action)
			_refresh()
		_:
			_try_bind(key)


func _move_selection(step: int) -> void:
	_selected = clampi(_selected + step, 0, InputBindings.REBINDABLE.size() - 1)
	if _selected < _top:
		_top = _selected
	elif _selected >= _top + VISIBLE_ROWS:
		_top = _selected - VISIBLE_ROWS + 1
	_refresh()


func _try_bind(event: InputEvent) -> void:
	var action := _current_action()
	if not (event is InputEventKey or event is InputEventMouseButton):
		_status.text = "Назначить можно клавишу или мышь"
		return
	if InputBindings.rebind(action, event):
		_status.text = "%s → %s" % [_label(action), describe_event(event)]
	else:
		_status.text = "Занято другим действием"
	_refresh()


func _current_action() -> String:
	return InputBindings.REBINDABLE[_selected]


func _label(action: String) -> String:
	return String(ACTION_LABELS.get(action, action))


func _refresh() -> void:
	var total := InputBindings.REBINDABLE.size()
	_top = clampi(_top, 0, maxi(0, total - VISIBLE_ROWS))
	for i in _rows.size():
		var index := _top + i
		if index >= total:
			_rows[i].text = ""
			continue
		var action := InputBindings.REBINDABLE[index]
		var binding := "—"
		var events := InputMap.action_get_events(action)
		if not events.is_empty():
			binding = describe_event(events[0])
		_rows[i].text = "%s %s — %s" % ["> " if i + _top == _selected else "  ", _label(action), binding]
		_rows[i].add_theme_color_override(
			"font_color", Color(0.98, 0.86, 0.5) if i + _top == _selected else Color(0.88, 0.9, 0.85)
		)


static func describe_event(event: InputEvent) -> String:
	if event is InputEventKey:
		return describe_key(int((event as InputEventKey).physical_keycode))
	if event is InputEventMouseButton:
		var button := int((event as InputEventMouseButton).button_index)
		match button:
			MOUSE_BUTTON_LEFT:
				return "ЛКМ"
			MOUSE_BUTTON_RIGHT:
				return "ПКМ"
			MOUSE_BUTTON_MIDDLE:
				return "СКМ"
			_:
				return "Мш.%d" % button
	return "—"


static func describe_key(code: int) -> String:
	match code:
		KEY_ESCAPE:
			return "Esc"
		KEY_SPACE:
			return "Space"
		KEY_SHIFT:
			return "Shift"
		KEY_CTRL:
			return "Ctrl"
		KEY_ALT:
			return "Alt"
		KEY_META:
			return "Cmd"
		KEY_TAB:
			return "Tab"
		KEY_ENTER:
			return "Enter"
		KEY_KP_ENTER:
			return "Num Enter"
		KEY_BACKSPACE:
			return "Bksp"
		KEY_DELETE:
			return "Del"
		KEY_INSERT:
			return "Ins"
		KEY_HOME:
			return "Home"
		KEY_END:
			return "End"
		KEY_PAGEUP:
			return "PgUp"
		KEY_PAGEDOWN:
			return "PgDn"
		KEY_UP:
			return "Up"
		KEY_DOWN:
			return "Down"
		KEY_LEFT:
			return "Left"
		KEY_RIGHT:
			return "Right"
	if code >= KEY_A and code <= KEY_Z:
		return char(code)
	if code >= KEY_0 and code <= KEY_9:
		return char(code)
	if code >= KEY_F1 and code <= KEY_F24:
		return "F%d" % (code - int(KEY_F1) + 1)
	# The label is returned as a Key; only printable ones are useful as text.
	var label := int(DisplayServer.keyboard_get_label_from_physical(code))
	if label > 0 and label < int(KEY_SPECIAL):
		return char(label)
	return "key %d" % code


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.97)
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
