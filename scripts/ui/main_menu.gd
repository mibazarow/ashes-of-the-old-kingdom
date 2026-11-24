class_name MainMenu
extends Control
## Main menu (spec §16.1): the boot screen the game opens on.
##
## Built entirely in code, like every other screen here, so it carries the same
## theme, the same panel style and the same 8 px pixel-ish font as the HUD: the
## menu is one more screen of the game rather than a second UI toolkit.
##
## Input goes through `InputSource` exactly like the HUD and every panel, so the
## debug bot and a human drive the menu through one code path. Raw `Input` is read
## only for Enter, which has no InputMap action anywhere in this project.
##
## The menu is deliberately stateless about the run: it never touches the world,
## it only decides which scene to hand over and (for a load) which slot
## `Main._apply_pending_load()` should consume. That is why the handoff value
## lives on the `GameState` autoload — `change_scene_to_file` frees this control,
## so nothing stored on it could survive the trip.

const WORLD_SCENE := "res://scenes/main/main.tscn"

## `PEPEL_SCREENSHOT_UI=menu` is the one screenshot probe that belongs to this
## scene. Every other probe (and every bare `PEPEL_SCREENSHOT`) is a probe of the
## world, whose capture code lives in `main.gd`, so those must fall straight
## through to the game or the existing screenshots would show a menu.
const MENU_PROBE := "menu"

const COLOR_TITLE := Color(0.96, 0.86, 0.5)
const COLOR_SUBTITLE := Color(0.6, 0.62, 0.6)
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_ROW_SELECTED := Color(1.0, 0.97, 0.62)
const COLOR_ROW_DISABLED := Color(0.5, 0.52, 0.5)
const COLOR_HINT := Color(0.6, 0.62, 0.6)
const COLOR_STATUS := Color(0.98, 0.84, 0.42)
const COLOR_CREDITS_HEAD := Color(0.96, 0.86, 0.5)

const SCREEN_MAIN := "main"
const SCREEN_SLOTS := "slots"
const SCREEN_CREDITS := "credits"

## The six entries of spec §16.1, in display order. `menu_items()` hands this out
## as a typed copy so a caller cannot walk away with the menu's own array.
const ITEM_LABELS := ["Новая игра", "Продолжить", "Загрузка", "Настройки", "Титры", "Выход"]

## Credit lines, shared with the victory screen (`Hud.show_victory`) so the two
## places that name what made this game cannot drift apart. The disclosure is the
## one in README: models, cost, and the fact that no human ever played it.
const CREDITS_LINES := [
	"ДВИЖОК",
	"Godot 4.7.2 (GL Compatibility), GDScript",
	"Окно 480x270, integer scale",
	"",
	"АССЕТЫ",
	"Спрайты: tools/gen_sprites.py — примитивы, собранные кодом",
	"Звуки: tools/gen_audio.py — процедурная генерация, Python 3",
	"Лицензия: CC0, собственная работа, сторонних материалов нет",
	"Шрифт: системный (Helvetica Neue → Arial → DejaVu Sans)",
	"Музыки в срезе нет",
	"",
	"СДЕЛАНО ИСКУССТВЕННЫМ ИНТЕЛЛЕКТОМ",
	"Оркестратор: DeepSeek Flash 1017",
	"Исполнители: локально запущенная Qwen-3.8-Flash-IQ4_XXL",
	"Техническое задание тоже написал агент — по короткому промту",
	"Полная стоимость работы: 260 рублей",
	"Человеческого контроля не было: ни чтения ТЗ, ни ревью кода",
	"",
	"ЧЕГО МЫ НЕ ЗНАЕМ",
	"Ни один человек в эту игру не играл. Никто даже не пытался.",
	"Играбельность, баланс и смысл не проверены.",
	"Подробнее: README.md и PROCESS.md",
]

## Credit rows on screen at once. The panel is centred in a 270 px viewport, and
## the title, the subtitle, the hint and the panel margins already own the rest
## of the height, so anything past this many rows has to scroll.
const CREDITS_VISIBLE := 14

var _screen: String = SCREEN_MAIN
var _rows: Array[Label] = []
var _screen_box: VBoxContainer
var _status: Label
var _hint: Label
var _settings_panel: SettingsPanel
var _settings_open := false
var _settings_just_closed := false
var _selected := 0
var _credits_scroll := 0
var _enter_held := false
var _built := false


func _ready() -> void:
	# A run that was asked to do something else must never see this screen at all:
	# the debug bots, `PEPEL_SCREENSHOT` and `PEPEL_LOAD_SLOT` all drive the world
	# through `main.gd`, and a menu in front of them would silently turn every bot
	# and every screenshot into a picture of a title screen. Checked before any node
	# is built, so the bypassed menu never draws a single frame.
	if bypass_requested():
		set_process(false)
		get_tree().paused = false
		get_tree().change_scene_to_file.call_deferred(WORLD_SCENE)
		return
	_build_ui()
	_built = true
	_show_main()
	_start_menu_music()
	_maybe_capture_menu_screenshot()


## The menu's own bed. Resolved through the runtime autoload rather than a
## compile-time identifier, exactly like `settings_panel.gd`: a missing audio
## layer is a silent no-op, and a run that bypassed this screen (a bot, a probe)
## never reaches here at all, so it never hears menu music.
func _start_menu_music() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return
	var audio := loop.root.get_node_or_null("AudioManager")
	if audio != null and audio.has_method("play_music"):
		audio.call("play_music", "music_menu")


## Whether this process was launched at a bot or at a headless probe rather than
## at a player. Read from both argument lists because `bot.gd` reads both: user
## args carry `-- --bot=…`, and a launcher that forgets the `--` leaves the same
## flag in the full command line.
static func bypass_requested() -> bool:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg: String in args:
		if String(arg).begins_with("--bot="):
			return true
	if OS.get_environment("PEPEL_LOAD_SLOT") != "":
		return true
	if OS.get_environment("PEPEL_SCREENSHOT") != "" \
			and OS.get_environment("PEPEL_SCREENSHOT_UI") != MENU_PROBE:
		return true
	return false


## The menu capture probe: same contract as `main.gd`, wait a few frames, grab the
## viewport, write the PNG and quit. Lives here because the scene being captured is
## this one, and `main.gd` is never instantiated on this path.
func _maybe_capture_menu_screenshot() -> void:
	var path := OS.get_environment("PEPEL_SCREENSHOT")
	if path == "" or OS.get_environment("PEPEL_SCREENSHOT_UI") != MENU_PROBE:
		return
	for _i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[screenshot] saved=%s err=%d size=%s" % [path, err, str(image.get_size())])
	get_tree().quit(0)


# --- construction -------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _make_theme()

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.08, 0.97)))
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	var title := _make_text(ProjectSettings.get_setting("application/config/name", "Пепел"), COLOR_TITLE)
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := _make_text("сборка %s" % String(ProjectSettings.get_setting("application/config/version", "000")), COLOR_SUBTITLE)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)

	box.add_child(_spacer(6))

	_screen_box = VBoxContainer.new()
	_screen_box.name = "Screen"
	_screen_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_box.add_theme_constant_override("separation", 1)
	box.add_child(_screen_box)

	box.add_child(_spacer(4))

	_status = _make_text("", COLOR_STATUS)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.custom_minimum_size = Vector2(240, 0)
	_status.visible = false
	box.add_child(_status)

	_hint = _make_text("", COLOR_HINT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_hint)

	_settings_panel = SettingsPanel.new()
	_settings_panel.name = "SettingsPanel"
	_settings_panel.visible = false
	_settings_panel.closed.connect(_on_settings_closed)
	add_child(_settings_panel)


func _spacer(height: float) -> Control:
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


## The menu theme. The menu builds its own `Theme` rather than inheriting the HUD's,
## so the raster settings have to be repeated here or the two screens drift: the
## boot screen is the first text a player reads, and it is also the one with the
## largest type on it. Both themes now ask for gray anti-aliasing and automatic
## subpixel positioning, because the sharpness comes from rasterising at the real
## window density (`window/stretch/mode="canvas_items"` makes the base 8 px a 24 px
## glyph at the shipped 1440x810 window), not from disabling the text server's
## smoothing — disabling it was the earlier fix and it only produced a magnified
## binary bitmap, since this is a proportional OS face and not a pixel font. Gray
## rather than LCD, so no colour fringing over the pixel art behind the panel.
## Kept in lockstep with `hud.gd::_make_theme()` by the `main_menu` test group,
## which reads the live theme of both.
func _make_theme() -> Theme:
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Helvetica Neue", "Arial Unicode MS", "Arial", "DejaVu Sans", "sans-serif"
	])
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 8
	return theme


func _panel_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
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


func _clear_screen() -> void:
	for child in _screen_box.get_children():
		_screen_box.remove_child(child)
		child.queue_free()
	_rows = []


func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


# --- screens ------------------------------------------------------------------

func _show_main() -> void:
	_screen = SCREEN_MAIN
	_selected = 0
	_clear_screen()
	for label_text in ITEM_LABELS:
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(240, 10)
		_screen_box.add_child(row)
		_rows.append(row)
	_hint.text = "↑↓ выбор · E или Enter — выбрать"
	_set_status("")
	_refresh()


func _show_slots() -> void:
	_screen = SCREEN_SLOTS
	_selected = 0
	_clear_screen()
	for slot in range(1, SaveManager.SLOT_COUNT + 1):
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(300, 10)
		_screen_box.add_child(row)
		_rows.append(row)
	_hint.text = "↑↓ выбор · E или Enter — загрузить · Esc назад"
	_set_status("")
	_refresh()


func _show_credits() -> void:
	_screen = SCREEN_CREDITS
	_selected = 0
	_credits_scroll = 0
	_clear_screen()
	for _i in range(CREDITS_VISIBLE):
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(320, 10)
		_screen_box.add_child(row)
		_rows.append(row)
	_hint.text = "↑↓ прокрутка · Esc назад"
	_set_status("")
	_refresh()


func _refresh() -> void:
	match _screen:
		SCREEN_MAIN:
			_refresh_main()
		SCREEN_SLOTS:
			_refresh_slots()
		SCREEN_CREDITS:
			_refresh_credits()


func _refresh_main() -> void:
	for i in _rows.size():
		var enabled := _item_enabled(i)
		var is_on := i == _selected
		_rows[i].text = "%s %s%s" % [
			"> " if is_on else "  ",
			String(ITEM_LABELS[i]),
			"" if enabled else "  — нет сохранений",
		]
		if not enabled:
			_rows[i].add_theme_color_override("font_color", COLOR_ROW_DISABLED)
		else:
			_rows[i].add_theme_color_override(
				"font_color", COLOR_ROW_SELECTED if is_on else COLOR_ROW)


func _refresh_slots() -> void:
	for i in _rows.size():
		var slot := i + 1
		var is_on := i == _selected
		_rows[i].text = "%s %s" % ["> " if is_on else "  ", slot_summary(slot)]
		_rows[i].add_theme_color_override(
			"font_color", COLOR_ROW_SELECTED if is_on else COLOR_ROW)


func _refresh_credits() -> void:
	var total := CREDITS_LINES.size()
	_credits_scroll = clampi(_credits_scroll, 0, maxi(0, total - CREDITS_VISIBLE))
	for i in _rows.size():
		var index := _credits_scroll + i
		if index >= total:
			_rows[i].text = ""
			continue
		var line := String(CREDITS_LINES[index])
		_rows[i].text = line
		# A line with no spaces around it is a section head, not body text.
		_rows[i].add_theme_color_override(
			"font_color", COLOR_CREDITS_HEAD if line == line.to_upper() and line != "" else COLOR_ROW)


# --- input --------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _built:
		return
	# The settings screen reads raw InputEvents itself; while it is open no menu
	# polling may answer the same keys, exactly like the HUD gates its own polling.
	if _settings_open:
		return
	if _settings_just_closed:
		_settings_just_closed = false
		if InputSource.is_action_just_pressed(&"pause"):
			return
	var delta := 0
	if InputSource.is_action_just_pressed(&"move_up"):
		delta -= 1
	if InputSource.is_action_just_pressed(&"move_down"):
		delta += 1
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	var confirm := InputSource.is_action_just_pressed(&"interact") or enter_edge

	if _screen == SCREEN_CREDITS:
		if delta != 0:
			_credits_scroll = clampi(_credits_scroll + delta, 0, maxi(0, CREDITS_LINES.size() - CREDITS_VISIBLE))
			_refresh()
		if InputSource.is_action_just_pressed(&"pause") or confirm:
			_show_main()
		return

	if InputSource.is_action_just_pressed(&"pause"):
		_on_back()
		return
	if delta != 0 and not _rows.is_empty():
		_selected = clampi(_selected + delta, 0, _rows.size() - 1)
		_refresh()
	if confirm:
		_activate()


## Esc. On the root menu it does nothing on purpose: quitting a game nobody asked
## to quit with one accidental keypress is worse than a dead key. On a sub-screen
## it goes back.
func _on_back() -> void:
	match _screen:
		SCREEN_SLOTS, SCREEN_CREDITS:
			_show_main()
		_:
			pass


func _activate() -> void:
	match _screen:
		SCREEN_MAIN:
			_activate_item(_selected)
		SCREEN_SLOTS:
			_activate_slot(_selected + 1)


func _activate_item(index: int) -> void:
	if index < 0 or index >= ITEM_LABELS.size():
		return
	if not _item_enabled(index):
		_set_status("Сохранений пока нет — начните новую игру")
		return
	match index:
		0:
			start_new_game()
		1:
			continue_most_recent()
		2:
			_show_slots()
		3:
			_open_settings()
		4:
			_show_credits()
		5:
			get_tree().quit()


func _activate_slot(slot: int) -> void:
	if not request_slot(slot):
		_set_status("Слот %d пуст" % slot)
		return
	_set_status("Загрузка слота %d" % slot)
	get_tree().paused = false
	get_tree().change_scene_to_file(WORLD_SCENE)


func _item_enabled(index: int) -> bool:
	# Only «Продолжить» can be unavailable: everything else either always works or
	# refuses on its own screen (an empty slot in «Загрузка»).
	return index != 1 or any_slot_exists()


func _open_settings() -> void:
	_settings_open = true
	_settings_panel.visible = true
	_settings_panel.open()


func _on_settings_closed() -> void:
	_settings_open = false
	_settings_just_closed = true
	_settings_panel.visible = false


# --- handoffs -----------------------------------------------------------------

## Everything «Новая игра» does to the run, without the scene change. Split out so
## a test can prove the reset is complete without tearing down its own tree;
## `start_new_game()` is this plus the handover.
func prepare_new_game() -> void:
	GameState.reset()
	QuestManager.reset()
	GameState.set_zone(GameState.DEFAULT_ZONE)
	GameState.pending_load_slot = 0
	GameState.ui_blocking = false


func start_new_game() -> void:
	prepare_new_game()
	get_tree().paused = false
	get_tree().change_scene_to_file(WORLD_SCENE)


## Records a slot for `Main._apply_pending_load()` to consume. Returns false,
## writing nothing, when the slot is missing or unreadable, so an empty row in
## «Загрузка» is refused rather than silently starting a default run.
func request_slot(slot: int) -> bool:
	if slot < 1 or slot > SaveManager.SLOT_COUNT:
		return false
	var info: Dictionary = SaveManager.slot_info(slot)
	if not bool(info.get("exists", false)) or bool(info.get("corrupt", false)):
		return false
	GameState.pending_load_slot = slot
	GameState.ui_blocking = false
	return true


## «Продолжить»: the newest of the three slots, decided by the `saved_at` stamp the
## save manager writes in UTC, which is ISO-ordered and therefore sorts as text.
func most_recent_slot() -> int:
	var best := 0
	var best_stamp := ""
	for slot in range(1, SaveManager.SLOT_COUNT + 1):
		var info: Dictionary = SaveManager.slot_info(slot)
		if not bool(info.get("exists", false)) or bool(info.get("corrupt", false)):
			continue
		var stamp := String(info.get("saved_at", ""))
		if stamp >= best_stamp:
			best_stamp = stamp
			best = slot
	return best


func continue_most_recent() -> void:
	var slot := most_recent_slot()
	if slot <= 0:
		_set_status("Сохранений пока нет — начните новую игру")
		return
	if not request_slot(slot):
		_set_status("Слот %d не читается" % slot)
		return
	_set_status("Продолжение слота %d" % slot)
	get_tree().paused = false
	get_tree().change_scene_to_file(WORLD_SCENE)


# --- read-only views (tests, screenshot probes) -------------------------------

## The six entries of spec §16.1, in display order.
func menu_items() -> Array[String]:
	var out: Array[String] = []
	for label_text in ITEM_LABELS:
		out.append(String(label_text))
	return out


func any_slot_exists() -> bool:
	for slot in range(1, SaveManager.SLOT_COUNT + 1):
		var info: Dictionary = SaveManager.slot_info(slot)
		if bool(info.get("exists", false)) and not bool(info.get("corrupt", false)):
			return true
	return false


func continue_enabled() -> bool:
	return _item_enabled(1)


## One line describing a slot: `Слот 2 — Лесной край · ур. 3 · 2026-11-20T14:52:51`,
## or `пусто`. Reads only the header fields through `SaveManager`, so listing the
## slots never loads a run, and takes the zone name from the same table the HUD's
## zone line uses rather than printing the raw id.
func slot_summary(slot: int) -> String:
	var info: Dictionary = SaveManager.slot_info(slot)
	if not bool(info.get("exists", false)):
		return "Слот %d — пусто" % slot
	if bool(info.get("corrupt", false)):
		return "Слот %d — повреждён" % slot
	var zone_name := ZoneManager.zone_display_name(SaveManager.slot_zone(slot))
	if zone_name == "":
		zone_name = "неизвестная зона"
	return "Слот %d — %s · ур. %d · %s" % [
		slot, zone_name, int(info.get("level", 1)), String(info.get("saved_at", "")),
	]


## The slot rows exactly as drawn, so a caller can see `пусто` and the cursor
## without reaching into the panel's node tree.
func slot_row_texts() -> Array[String]:
	var out: Array[String] = []
	for row in _rows:
		out.append(row.text)
	return out


func current_screen() -> String:
	if _settings_open:
		return "settings"
	return _screen


func is_built() -> bool:
	return _built


## The credit block, so the victory screen renders the same words instead of a
## second copy of them.
static func credits_lines() -> Array[String]:
	var out: Array[String] = []
	for line in CREDITS_LINES:
		out.append(String(line))
	return out
