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
## One keyboard step on a volume or a screen row, in percent.
const VOLUME_STEP := 10
## Cells in the text bar: one cell per 10 %.
const BAR_CELLS := 10
## Label column width, so the bars start on the same character.
const LABEL_WIDTH := 10
const AUDIO_MANAGER_NAME := "AudioManager"
const ACCESSIBILITY_NAME := "Accessibility"

const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_SELECTED := Color(0.98, 0.86, 0.5)
const COLOR_SECTION_ON := Color(0.96, 0.86, 0.5)
const COLOR_SECTION_OFF := Color(0.66, 0.68, 0.64)
## The panel interior colour, spelled out so the footer-contrast contract and the
## actual `_panel_style()` can never drift apart. CRITIC-P1-12: the footer sat at
## 2.92:1 against this surface; the test recomputes the ratio against this constant.
const PANEL_INTERIOR := Color(0.05, 0.06, 0.08)
## Footer/hint text. CRITIC-P1-12 flagged the old (0.6,0.62,0.6) at 2.92:1 against
## `PANEL_INTERIOR`; this clears 4.5:1 (≈12:1) so the footer lines are readable.
const COLOR_HINT := Color(0.80, 0.82, 0.78)

## The three sections the cursor cycles through with Tab. Controls and Sound are the
## original two; Screen (CRITIC-P1-11 / P2-22) is the display/accessibility section.
enum Section { CONTROLS, SOUND, SCREEN }
const SECTION_COUNT := 3

## The screen rows, in display order. The keys double as the Accessibility store's
## field names, so the panel reads and writes them by key and holds no second copy of
## the values. `flash_intensity` and `font_scale` are 0..100 / 100..150 percents;
## `colorblind_mode` is a boolean toggled with the same arrows.
const SCREEN_KEYS: Array[String] = ["flash_intensity", "font_scale", "colorblind_mode"]
const SCREEN_LABELS := {
	"flash_intensity": "Яркость вспышек",
	"font_scale": "Размер шрифта",
	"colorblind_mode": "Дальтонизм",
}

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
var _screen_rows: Array[Label] = []
var _controls_header: Label
var _sound_header: Label
var _screen_header: Label
var _status: Label
var _selected := 0
var _top := 0
var _sound_selected := 0
var _screen_selected := 0
var _section: int = Section.CONTROLS
var _sound: Dictionary = {}
var _audio: Node = null
var _accessibility: Node = null


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

	# The display/accessibility section (CRITIC-P1-11 / P2-22): flash intensity, font
	# scale and colour-blind mode. Same row pattern as the volumes; the values live in
	# the Accessibility store, which the panel reads and writes by key.
	_screen_header = _make_text("", COLOR_SECTION_OFF)
	_screen_header.custom_minimum_size = Vector2(208, 10)
	box.add_child(_screen_header)

	var screen_box := VBoxContainer.new()
	screen_box.add_theme_constant_override("separation", 0)
	box.add_child(screen_box)
	for _key in SCREEN_KEYS:
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(208, 10)
		screen_box.add_child(row)
		_screen_rows.append(row)

	_status = _make_text("", Color(0.98, 0.84, 0.42))
	_status.custom_minimum_size = Vector2(208, 10)
	box.add_child(_status)

	box.add_child(_make_text("↑↓ выбор · Tab раздел · колесо прокрутка", COLOR_HINT))
	box.add_child(_make_text("клавиша или мышь — назначить · ←→ значение", COLOR_HINT))
	box.add_child(_make_text("R сброс выбранного · Esc выход и сохранить", COLOR_HINT))
	# The rows hold no numbers of their own any more, so the first paint has to
	# read the buses just like `open()` does, otherwise a panel that is shown
	# without an explicit `open()` would draw an empty bar on every row.
	_sync_from_buses()
	_sync_from_store()
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
	_section = Section.CONTROLS
	_selected = 0
	_top = 0
	_sound_selected = 0
	_screen_selected = 0
	_sync_from_buses()
	_sync_from_store()
	_refresh()


# --- test / screenshot accessors ---------------------------------------------

## The 0..100 level the row for `bus` currently shows.
func sound_value(bus: String) -> int:
	return int(_sound.get(bus, 0))


## True while the cursor is in the sound section.
func sound_section() -> bool:
	return _section == Section.SOUND


## True while the cursor is in the display/accessibility section.
func screen_section() -> bool:
	return _section == Section.SCREEN


## How many sections the panel exposes (CRITIC-P1-11: it used to be exactly two).
func section_count() -> int:
	return SECTION_COUNT


## The current value of one screen setting, read straight from the Accessibility
## store so the panel never holds a second copy. Booleans come back as 0/100 so a
## caller can treat every row uniformly; `screen_flag` reads the boolean directly.
func screen_value(key: String) -> int:
	var store := _accessibility_manager()
	if store == null:
		return 0
	match key:
		"flash_intensity":
			return int(store.get("flash_intensity"))
		"font_scale":
			return int(store.get("font_scale"))
		"colorblind_mode":
			return 100 if bool(store.get("colorblind_mode")) else 0
		_:
			return 0


## The boolean behind `colorblind_mode`, for a caller that wants the flag not a bar.
func screen_flag(key: String) -> bool:
	var store := _accessibility_manager()
	if store == null:
		return false
	return bool(store.get(key))


## The screen key the cursor is on, "" when the cursor is in another section.
func selected_screen_key() -> String:
	if _section != Section.SCREEN or _screen_selected >= SCREEN_KEYS.size():
		return ""
	return SCREEN_KEYS[_screen_selected]


## Bus the volume cursor is on, "" when the cursor is in another section.
func selected_bus() -> String:
	if _section != Section.SOUND or _sound_selected >= SOUND_BUSES.size():
		return ""
	return SOUND_BUSES[_sound_selected]


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
	_section = Section.SOUND
	_sound_selected = index
	_refresh()


## Parks the cursor on one screen row without simulating keys.
func select_screen(key: String) -> void:
	var index := SCREEN_KEYS.find(key)
	if index < 0:
		return
	_section = Section.SCREEN
	_screen_selected = index
	_refresh()


# --- input -------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if not mouse.pressed:
			return
		# Only the controls section reads the mouse: a volume or a screen value is a
		# keyboard step, and a stray click must never assign a mouse button to an
		# action. The wheel pages the rebind list, which only the controls section has.
		if _section == Section.CONTROLS:
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
			# Enter confirms a rebind where a rebind is what is being edited and does
			# nothing in the sound or screen sections, where there is nothing to pick.
			if _section == Section.CONTROLS:
				_try_bind(key)
		_:
			if _section == Section.CONTROLS:
				_try_bind(key)


func _adjust_or_bind(key: InputEventKey, step: int) -> void:
	match _section:
		Section.SOUND:
			_nudge_sound(step)
		Section.SCREEN:
			_nudge_screen(step)
		_:
			_try_bind(key)


## Tab cycles Controls -> Sound -> Screen -> Controls. The cursor lands on the first
## row of the section it just entered, so no section can hold a stale cursor that
## disagrees with what is on screen.
func _switch_section() -> void:
	_section = (_section + 1) % SECTION_COUNT
	_selected = 0
	_top = 0
	_sound_selected = 0
	_screen_selected = 0
	_refresh()


func _move_selection(step: int) -> void:
	match _section:
		Section.SOUND:
			_sound_selected = clampi(_sound_selected + step, 0, SOUND_BUSES.size() - 1)
			_refresh()
			return
		Section.SCREEN:
			_screen_selected = clampi(_screen_selected + step, 0, SCREEN_KEYS.size() - 1)
			_refresh()
			return
		_:
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
	match _section:
		Section.SOUND:
			_reset_selected_sound()
			return
		Section.SCREEN:
			_reset_selected_screen()
			return
		_:
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


## One write on the way out, not one per key press: both files are atomic, and a
## failure is reported on the status line instead of being swallowed. The volumes go
## to the audio store and the screen settings to the accessibility store — two files,
## two owners, so neither writer can clobber the other's keys.
func _close() -> void:
	var manager := _audio_manager()
	if manager != null:
		var result: Dictionary = manager.call("save_settings")
		if not bool(result.get("ok", false)):
			_status.text = "Не сохранено: %s" % String(result.get("error", ""))
	var accessibility := _accessibility_manager()
	if accessibility != null:
		var acc_result: Dictionary = accessibility.call("save_settings")
		if not bool(acc_result.get("ok", false)) and _status.text == "":
			_status.text = "Не сохранено: %s" % String(acc_result.get("error", ""))
	closed.emit()


# --- rendering ---------------------------------------------------------------

func _refresh() -> void:
	_refresh_sections()
	_refresh_controls()
	_refresh_sound()
	_refresh_screen()


## The three headers double as the section switch: the one that owns the cursor
## carries the marker, so the screen always shows all three sections and which of
## them the keys belong to.
func _refresh_sections() -> void:
	_controls_header.text = "> Управление" if _section == Section.CONTROLS else "  Управление"
	_controls_header.add_theme_color_override(
		"font_color", COLOR_SECTION_ON if _section == Section.CONTROLS else COLOR_SECTION_OFF
	)
	_sound_header.text = "> Звук" if _section == Section.SOUND else "  Звук"
	_sound_header.add_theme_color_override(
		"font_color", COLOR_SECTION_ON if _section == Section.SOUND else COLOR_SECTION_OFF
	)
	_screen_header.text = "> Экран" if _section == Section.SCREEN else "  Экран"
	_screen_header.add_theme_color_override(
		"font_color", COLOR_SECTION_ON if _section == Section.SCREEN else COLOR_SECTION_OFF
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
		var is_on: bool = _section == Section.CONTROLS and i + _top == _selected
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
		var is_on := _section == Section.SOUND and i == _sound_selected
		_sound_rows[i].text = "%s%s [%s] %3d" % [
			"> " if is_on else "  ",
			_pad(_sound_label(bus), LABEL_WIDTH),
			volume_bar(value),
			value,
		]
		_sound_rows[i].add_theme_color_override("font_color", COLOR_SELECTED if is_on else COLOR_ROW)


## The screen rows. The two percents render as a bar plus a number like the volumes;
## the colour-blind row renders as a text state, because a boolean has no bar. The
## values are read live from the Accessibility store, so the panel never disagrees
## with what the HUD and the player/enemy flash actually apply.
func _refresh_screen() -> void:
	for i in _screen_rows.size():
		if i >= SCREEN_KEYS.size():
			_screen_rows[i].text = ""
			continue
		var key := SCREEN_KEYS[i]
		var is_on := _section == Section.SCREEN and i == _screen_selected
		var value := screen_value(key)
		var body := ""
		if key == "colorblind_mode":
			body = "%s — %s" % [_pad(_screen_label(key), LABEL_WIDTH), "вкл" if value >= 100 else "выкл"]
		elif key == "font_scale":
			# 100..150 % mapped onto the same 10-cell bar as the 0..100 volumes.
			body = "%s [%s] %3d" % [
				_pad(_screen_label(key), LABEL_WIDTH),
				volume_bar(int(round((value - 100) / 50.0 * 100.0))),
				value,
			]
		else:
			body = "%s [%s] %3d" % [
				_pad(_screen_label(key), LABEL_WIDTH),
				volume_bar(value),
				value,
			]
		_screen_rows[i].text = "%s%s" % ["> " if is_on else "  ", body]
		_screen_rows[i].add_theme_color_override("font_color", COLOR_SELECTED if is_on else COLOR_ROW)


## One step on the screen row the cursor is on. The two percents move by `step` and
## clamp inside the store; the boolean toggles (the step sign is irrelevant — a
## boolean has one action). Every write goes through the store's clamped setters, so
## the panel cannot push a value the HUD or the flash would not accept.
func _nudge_screen(step: int) -> void:
	var store := _accessibility_manager()
	if store == null:
		return
	var key := selected_screen_key()
	match key:
		"flash_intensity":
			store.call("set_flash_intensity", int(store.get("flash_intensity")) + step)
		"font_scale":
			store.call("set_font_scale", int(store.get("font_scale")) + step)
		"colorblind_mode":
			store.call("set_colorblind_mode", not bool(store.get("colorblind_mode")))
		_:
			return
	_refresh()


## `R` on a screen row restores just that row to its shipped default.
func _reset_selected_screen() -> void:
	var store := _accessibility_manager()
	if store == null:
		return
	var key := selected_screen_key()
	var defaults: Dictionary = store.call("settings_defaults") if store.has_method("settings_defaults") else {}
	match key:
		"flash_intensity":
			store.call("set_flash_intensity", int(defaults.get("flash_intensity", 100)))
		"font_scale":
			store.call("set_font_scale", int(defaults.get("font_scale", 100)))
		"colorblind_mode":
			store.call("set_colorblind_mode", bool(defaults.get("colorblind_mode", false)))
		_:
			return
	_status.text = "Сброшено: %s" % _screen_label(key)
	_refresh()


## Pulls the three screen values from the Accessibility store into nothing — the rows
## read the store directly via `screen_value`, so this only exists to mirror
## `_sync_from_buses` and to force a repaint of the rows on open.
func _sync_from_store() -> void:
	# No cached copy is kept; the store is the single source of truth. Present so the
	# open/ready paths read symmetrically with the volume sync.
	pass


## The accessibility autoload, looked up by name through the scene root (the same
## runtime-lookup rule as the audio manager, and what keeps this script loading under
## `godot --script`). Null means no accessibility layer: the screen rows show 0 and
## write nothing.
func _accessibility_manager() -> Node:
	if _accessibility != null and is_instance_valid(_accessibility):
		return _accessibility
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	_accessibility = loop.root.get_node_or_null(ACCESSIBILITY_NAME)
	return _accessibility


func _screen_label(key: String) -> String:
	return String(SCREEN_LABELS.get(key, key))


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
	sb.bg_color = Color(PANEL_INTERIOR, 0.97)
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
