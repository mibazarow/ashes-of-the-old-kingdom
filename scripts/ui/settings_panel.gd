class_name SettingsPanel
extends PanelContainer
## Settings screen (spec §6 and §17.3): key rebinding plus the three volumes.
##
## Rebinding has to see every raw key and mouse button, including inputs no
## action owns yet, so this screen reads real InputEvents. The debug bot
## drives InputSource overrides instead of real events, so it can never reach
## this screen; the HUD also keeps it closed unless the player opens it.
##
## Both sections are on screen at the same time and `Tab` only moves the cursor
## between them, so the player always sees what the arrows currently control.
## The volume half owns no audio of its own: it keeps the three levels as 0..100
## integers for display and hands every change straight to the audio autoload,
## which owns the dB conversion, the click and the settings file. That autoload
## is resolved by name through the scene root rather than as an identifier, so
## this file keeps the project rule that nothing outside `audio_manager.gd`
## names it, and the screen still loads under `godot --script`.

signal closed

const VISIBLE_ROWS := 8
## One keyboard step on a volume row, in percent.
const VOLUME_STEP := 10
## Cells in the text bar: one cell per 10 %.
const BAR_CELLS := 10
## Label column width, so the three bars start on the same character.
const LABEL_WIDTH := 10
const AUDIO_MANAGER_NAME := "AudioManager"

const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_SELECTED := Color(0.98, 0.86, 0.5)
const COLOR_SECTION_ON := Color(0.96, 0.86, 0.5)
const COLOR_SECTION_OFF := Color(0.66, 0.68, 0.64)
const COLOR_HINT := Color(0.6, 0.62, 0.6)

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

## The buses the player can change, in display order. The bus names are the
## audio layout's, so the panel never invents one, and the levels are not the
## panel's either: `sound_defaults()` reads them from the autoload at runtime, so
## `R`, the numbers on screen and the buses cannot drift apart on a fresh install.
const SOUND_BUSES: Array[String] = ["Music", "SFX", "UI"]
const SOUND_LABELS := {"Music": "Музыка", "SFX": "Звуки", "UI": "Интерфейс"}
## Shown when no audio autoload is reachable. There is nothing to read and
## nothing to write, and 100 is where the engine leaves a bus it never touched,
## so `R` still means "back to where this session started".
const SOUND_FALLBACK := 100

var _rows: Array[Label] = []
var _sound_rows: Array[Label] = []
var _controls_header: Label
var _sound_header: Label
var _status: Label
var _selected := 0
var _top := 0
var _sound_selected := 0
var _sound_open := false
var _sound: Dictionary = {}
var _audio: Node = null


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

	box.add_child(_make_text("Настройки", COLOR_SECTION_ON))

	_controls_header = _make_text("", COLOR_SECTION_ON)
	_controls_header.custom_minimum_size = Vector2(208, 10)
	box.add_child(_controls_header)

	var rows_box := VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 0)
	box.add_child(rows_box)
	for i in VISIBLE_ROWS:
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(208, 10)
		rows_box.add_child(row)
		_rows.append(row)

	_sound_header = _make_text("", COLOR_SECTION_OFF)
	_sound_header.custom_minimum_size = Vector2(208, 10)
	box.add_child(_sound_header)

	var sound_box := VBoxContainer.new()
	sound_box.add_theme_constant_override("separation", 0)
	box.add_child(sound_box)
	for bus in SOUND_BUSES:
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(208, 10)
		sound_box.add_child(row)
		_sound_rows.append(row)

	_status = _make_text("", Color(0.98, 0.84, 0.42))
	_status.custom_minimum_size = Vector2(208, 10)
	box.add_child(_status)

	box.add_child(_make_text("↑↓ выбор · Tab раздел · колесо прокрутка", COLOR_HINT))
	box.add_child(_make_text("клавиша или мышь — назначить · ←→ громкость", COLOR_HINT))
	box.add_child(_make_text("R сброс выбранного · Esc выход и сохранить", COLOR_HINT))
	# The rows hold no numbers of their own any more, so the first paint has to
	# read the buses just like `open()` does, otherwise a panel that is shown
	# without an explicit `open()` would draw an empty bar on every row.
	_sync_from_buses()
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


## Called by the HUD every time the screen opens. The volume rows are re-read
## from the buses rather than trusted from the last visit, so the numbers on
## screen are the numbers the player is about to hear.
func open() -> void:
	_status.text = ""
	_sound_open = false
	_selected = 0
	_top = 0
	_sound_selected = 0
	_sync_from_buses()
	_refresh()


# --- test / screenshot accessors ---------------------------------------------

## The 0..100 level the row for `bus` currently shows.
func sound_value(bus: String) -> int:
	return int(_sound.get(bus, 0))


## True while the cursor is in the sound section.
func sound_section() -> bool:
	return _sound_open


## Bus the volume cursor is on, "" when the cursor is in the other section.
func selected_bus() -> String:
	return SOUND_BUSES[_sound_selected] if _sound_selected < SOUND_BUSES.size() else ""


## Action the rebind cursor is on.
func selected_action() -> String:
	return _current_action()


## Last status line, so a caller can read a save failure without reaching into
## the label.
func status_text() -> String:
	return _status.text if _status != null else ""


## Parks the cursor on one volume row without simulating keys, the same contract
## `select_row` gives the craft panel.
func select_sound(bus: String) -> void:
	var index := SOUND_BUSES.find(bus)
	if index < 0:
		return
	_sound_open = true
	_sound_selected = index
	_refresh()


# --- input -------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if not mouse.pressed:
			return
		# The sound section is keyboard-only: a volume is a 10 % step, and a
		# stray click must never assign a mouse button to an action.
		if not _sound_open:
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
			_close()
		KEY_TAB:
			_switch_section()
		KEY_UP:
			_move_selection(-1)
		KEY_DOWN:
			_move_selection(1)
		KEY_LEFT:
			_adjust_or_bind(key, -VOLUME_STEP)
		KEY_RIGHT:
			_adjust_or_bind(key, VOLUME_STEP)
		KEY_R:
			_reset_selected()
		KEY_ENTER, KEY_KP_ENTER:
			# Enter confirms a rebind where a rebind is what is being edited and
			# does nothing in the sound section, where there is nothing to pick.
			if not _sound_open:
				_try_bind(key)
		_:
			if not _sound_open:
				_try_bind(key)


func _adjust_or_bind(key: InputEventKey, step: int) -> void:
	if _sound_open:
		_nudge_sound(step)
	else:
		_try_bind(key)


func _switch_section() -> void:
	_sound_open = not _sound_open
	# The cursor always lands on the first row of the section it just entered,
	# so the two sections cannot hold stale cursors that disagree on screen.
	_selected = 0
	_top = 0
	_sound_selected = 0
	_refresh()


func _move_selection(step: int) -> void:
	if _sound_open:
		_sound_selected = clampi(_sound_selected + step, 0, SOUND_BUSES.size() - 1)
		_refresh()
		return
	_selected = clampi(_selected + step, 0, InputBindings.REBINDABLE.size() - 1)
	if _selected < _top:
		_top = _selected
	elif _selected >= _top + VISIBLE_ROWS:
		_top = _selected - VISIBLE_ROWS + 1
	_refresh()


## One step on the row the cursor is on. A row already at 0 or 100 stays put and
## stays silent, so holding a key at the end of the bar does not machine-gun the
## UI bus.
func _nudge_sound(step: int) -> void:
	var bus := selected_bus()
	var next := clampi(sound_value(bus) + step, 0, 100)
	if next == sound_value(bus):
		return
	_sound[bus] = next
	_commit(bus)
	_refresh()


func _reset_selected() -> void:
	if _sound_open:
		_reset_selected_sound()
		return
	var action := _current_action()
	InputBindings.reset_action(action)
	_status.text = "Сброшено: %s" % _label(action)
	_refresh()


## `R` restores one bus only: the player who trimmed the music down should not
## lose the sound effects they turned up with it.
func _reset_selected_sound() -> void:
	var bus := selected_bus()
	_sound[bus] = int(sound_defaults().get(bus, SOUND_FALLBACK))
	_commit(bus)
	_status.text = "Сброшено: %s %d" % [_sound_label(bus), sound_value(bus)]
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


func _sound_label(bus: String) -> String:
	return String(SOUND_LABELS.get(bus, bus))


# --- volume plumbing ---------------------------------------------------------

## The audio autoload, looked up by name through the scene root. The project rule
## is that no script outside `audio_manager.gd` holds it as an identifier, and a
## runtime lookup is also what lets this script load under `godot --script`.
## Null means no audio layer: the screen still opens and edits nothing.
func _audio_manager() -> Node:
	if _audio != null and is_instance_valid(_audio):
		return _audio
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	_audio = loop.root.get_node_or_null(AUDIO_MANAGER_NAME)
	return _audio


## What `R` restores, and what a row falls back to before the buses are read:
## the shipped levels, taken from the audio autoload rather than copied into this
## file, so the panel cannot hold a second set of numbers that disagrees with the
## buses it writes. Returned as 0..100 integers, the units the rows display.
func sound_defaults() -> Dictionary:
	var out: Dictionary = {}
	var stored: Dictionary = {}
	var manager := _audio_manager()
	if manager != null and manager.has_method("settings_defaults"):
		stored = manager.call("settings_defaults")
	for bus in SOUND_BUSES:
		var value: Variant = stored.get(bus, null)
		if value is float or value is int:
			out[bus] = int(round(clampf(float(value), 0.0, 1.0) * 100.0))
		else:
			out[bus] = SOUND_FALLBACK
	return out


func _sync_from_buses() -> void:
	var manager := _audio_manager()
	var defaults := sound_defaults()
	for bus in SOUND_BUSES:
		var value := int(defaults[bus])
		if manager != null:
			value = int(round(float(manager.call("volume", bus)) * 100.0))
		_sound[bus] = value


## Applies the new level first and clicks only afterwards, so on the UI row the
## click itself is heard at the level that was just set — that is the point of
## the row, and why the order here is not interchangeable.
func _commit(bus: String) -> void:
	var manager := _audio_manager()
	if manager == null:
		return
	manager.call("set_volume", bus, sound_value(bus) / 100.0)
	manager.call("play_sfx", "ui_click", "UI", 0.0)


## One write on the way out, not one per key press: the file is atomic, and a
## failure is reported on the status line instead of being swallowed.
func _close() -> void:
	var manager := _audio_manager()
	if manager != null:
		var result: Dictionary = manager.call("save_settings")
		if not bool(result.get("ok", false)):
			_status.text = "Не сохранено: %s" % String(result.get("error", ""))
	closed.emit()


# --- rendering ---------------------------------------------------------------

func _refresh() -> void:
	_refresh_sections()
	_refresh_controls()
	_refresh_sound()


## The two headers double as the section switch: the one that owns the cursor
## carries the marker, so the screen always shows both sections and which of
## them the keys belong to.
func _refresh_sections() -> void:
	_controls_header.text = "  Управление" if _sound_open else "> Управление"
	_controls_header.add_theme_color_override(
		"font_color", COLOR_SECTION_OFF if _sound_open else COLOR_SECTION_ON
	)
	_sound_header.text = "> Звук" if _sound_open else "  Звук"
	_sound_header.add_theme_color_override(
		"font_color", COLOR_SECTION_ON if _sound_open else COLOR_SECTION_OFF
	)


func _refresh_controls() -> void:
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
		var is_on: bool = not _sound_open and i + _top == _selected
		_rows[i].text = "%s %s — %s" % ["> " if is_on else "  ", _label(action), binding]
		_rows[i].add_theme_color_override(
			"font_color", COLOR_SELECTED if is_on else Color(0.88, 0.9, 0.85)
		)


func _refresh_sound() -> void:
	for i in _sound_rows.size():
		if i >= SOUND_BUSES.size():
			_sound_rows[i].text = ""
			continue
		var bus := SOUND_BUSES[i]
		var value := sound_value(bus)
		var is_on := _sound_open and i == _sound_selected
		_sound_rows[i].text = "%s%s [%s] %3d" % [
			"> " if is_on else "  ",
			_pad(_sound_label(bus), LABEL_WIDTH),
			volume_bar(value),
			value,
		]
		_sound_rows[i].add_theme_color_override("font_color", COLOR_SELECTED if is_on else COLOR_ROW)


## Text bar, one cell per 10 %: `[#######---]` is 70.
static func volume_bar(value: int) -> String:
	var filled := clampi(int(round(value / 100.0 * BAR_CELLS)), 0, BAR_CELLS)
	return "#".repeat(filled) + "-".repeat(BAR_CELLS - filled)


## Manual pad rather than a `%-10s` spec: the labels are Cyrillic, and spelling
## the padding out keeps the bar column aligned on every host.
static func _pad(text: String, width: int) -> String:
	var out := text
	while out.length() < width:
		out += " "
	return out


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
