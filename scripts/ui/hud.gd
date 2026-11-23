class_name Hud
extends CanvasLayer
## All UI built in code: bars, quest tracker, prompts, dialogue, inventory, pause.

const BAR_W := 92.0
const BAR_H := 7.0
const QUICK_SLOT_ACTIONS := [&"quick_slot_1", &"quick_slot_2", &"quick_slot_3", &"quick_slot_4"]
## Every action the HUD answers with a one-shot press edge. `_input` latches these
## so a press that opens or closes a panel is never lost to frame timing; `_process`
## consumes the latch instead of reading the engine's one-frame `just_pressed`.
const POLLED_ACTIONS := [&"map", &"pause", &"character", &"skills", &"journal",
	&"inventory", &"interact", &"move_up", &"move_down", &"save_game", &"load_game"] \
		+ QUICK_SLOT_ACTIONS
## At most this many inventory rows are rendered at once, so the panel can never
## grow past the 480x270 viewport; the cursor scrolls a window over the rest.
const MAX_VISIBLE_ROWS := 8
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_WARNING := Color(0.98, 0.66, 0.36)
const COLOR_HINT := Color(0.6, 0.62, 0.6)
## The dark, semi-opaque surface behind the HUD status block and the controls band
## (CRITIC-P1-02 / P1-03 / P2-20). Dark enough that every HUD string clears 4.5:1
## against it even after compositing over the brightest floor, yet translucent
## enough to read as a HUD plate rather than a solid panel.
const PLATE_COLOR := Color(0.04, 0.05, 0.07, 0.86)
## The always-visible control hint colour, lifted so it clears 4.5:1 on the plate
## (the old 0.72,0.74,0.7 was 1.06:1 on grass).
const COLOR_HINT_TEXT := Color(0.82, 0.84, 0.8)
## The base theme font size in pixels. The accessibility font scale is a percent
## of this; the result is rounded to an integer so glyphs stay on the pixel grid.
const BASE_FONT_SIZE := 8

## Boss bar (spec §10.4 "полоска здоровья босса"). The boss is looked up through
## the `boss` group rather than a node path or a class reference, exactly like the
## day clock is looked up through `day_clock`, so the HUD stays out of the AI's
## compile graph. A boss counts as engaged while the player stands inside this
## radius of it and it is still alive; outside it the bar is simply not on screen,
## so the top of the viewport is not permanently claimed by an enemy the player
## is not fighting.
const BOSS_GROUP := &"boss"
const BOSS_ENGAGE_RADIUS := 200.0
const BOSS_BAR_W := 180.0
const COLOR_BOSS_BAR := Color(0.62, 0.32, 0.72)

## Russian display names for the day phases (spec §12.1), keyed by the phase id in
## data/schedules.json. An unknown id falls back to the raw id rather than blank.
const PHASE_LABELS_RU := {
	"morning": "Утро",
	"day": "День",
	"evening": "Вечер",
	"night": "Ночь",
}

## Russian display names for the rarity tiers, shown in the selected-row detail
## line (spec §14.1). The colour reinforces the tier; this text is what actually
## names it, so colour never stands in for a clear description.
const RARITY_LABELS_RU := {
	"common": "обычное",
	"uncommon": "необычное",
	"rare": "редкое",
	"epic": "эпическое",
	"legendary": "легендарное",
}

## Lowercase attribute names for the "Требуется: сила 7" detail line.
const ATTRIBUTE_LABELS_RU := {
	"strength": "сила",
	"agility": "ловкость",
	"intelligence": "интеллект",
	"endurance": "выносливость",
}

## The two answers the defeat screen offers (spec §16.1). «Возродиться» deliberately
## does not respawn anybody by itself: it only lets the tree run again, and the
## player's own `DEAD` timer then calls his own `_respawn()`. Two respawn paths
## would be two ways to disagree about where the player wakes up.
const DEFEAT_OPTIONS := ["Возродиться", "В меню"]
const MENU_SCENE := "res://scenes/main/menu.tscn"

## The three endings of spec §16.1, keyed by the id a future final boss passes to
## `show_victory()`. An unknown id falls back to the raw id rather than a blank
## screen, so a typo in a boss script shows up as a wrong title, not as nothing.
const ENDING_NAMES_RU := {
	"dawn": "Новый рассвет",
	"memory": "Память короля",
	"crown": "Пепельный венец",
}

var _root: Control
var _hp_bar: ProgressBar
var _mp_bar: ProgressBar
var _xp_bar: ProgressBar
var _hp_label: Label
var _mp_label: Label
var _xp_label: Label
var _level_label: Label
var _gold_label: Label
var _clock_label: Label
var _zone_label: Label
## The dark plate behind the top-left status block and the one behind the bottom
## controls band (CRITIC-P1-02 / P1-03 / P2-20). Kept as fields so a test can read
## their style and a bounds check can measure them without walking the tree.
var _status_plate: PanelContainer
var _hint_plate: PanelContainer
var _quest_label: Label
var _skill_label: Label
var _prompt_label: Label
var _toast_label: Label
var _dialogue_panel: PanelContainer
var _dialogue_speaker: Label
var _dialogue_text: Label
var _dialogue_options: Label
var _dialogue_hint: Label
var _inventory_panel: PanelContainer
var _inventory_list: VBoxContainer
var _inventory_stats: Label
var _inventory_detail: Label
var _inventory_requirement: Label
var _inventory_selection: int = 0
var _inventory_scroll: int = 0
var _enter_held: bool = false
var _quick_slot_list: VBoxContainer
var _journal_panel: PanelContainer
var _journal_list: VBoxContainer
var _journal_snapshot: String = ""
var _pause_panel: PanelContainer
var _hint_label: Label
var _map_panel: MapPanel
var _settings_panel: SettingsPanel
var _character_panel: CharacterPanel
var _shop_panel: ShopPanel
var _shop_manager: ShopManager
var _craft_panel: CraftPanel
var _craft_manager: CraftManager
var _skills_panel: SkillsPanel
var _toast_tween: Tween
var _dialogue_open := false
var _inventory_open := false
var _journal_open := false
var _map_open := false
var _paused := false
var _settings_open := false
var _settings_just_closed := false
var _character_open := false
var _shop_open := false
var _craft_open := false
var _skills_open := false
var _skills_l_held := false
var _tab_held: bool = false
var _day_clock: Node = null
var _clock_refresh_left := 0.0

## Defeat screen (spec §16.1). Its own two-row cursor, and the only screen here
## that pauses the tree on its own initiative: holding the death animation still is
## what keeps the existing `_dead_timer` from respawning the player underneath a
## screen that is still asking him what to do.
var _defeat_panel: PanelContainer
var _defeat_rows: Array[Label] = []
var _defeat_selected := 0
var _defeat_open := false

## Victory screen. Reached only through `show_victory()`; nothing in the world calls
## it yet because the final boss that would is not built.
var _victory_panel: PanelContainer
var _victory_title: Label
var _victory_scroll: ScrollContainer
var _victory_box: VBoxContainer
var _victory_hint: Label
var _victory_open := false

## The ending-choice panel: the real, in-game three-option screen the throne opens when
## the player presses E at it after the King has fallen (spec §16.1). It owns its own
## cursor and reads availability back from the altar (`ending_is_available`), so the
## gate that decides what can be chosen lives in one place — the altar — and this panel
## only renders it and routes the confirm back through `EndingAltar.choose()`. It blocks
## input like any modal (`ui_blocking`) but does not pause the world, and it is mutually
## exclusive with every other panel: while it is open the `_process` branch below owns
## the keys, so no other screen can stack over it.
var _ending_choice_panel: PanelContainer
var _ending_choice_rows: Array[Label] = []
var _ending_choice_descs: Array[Label] = []
var _ending_choice_selected := 0
var _ending_choice_open := false
var _ending_choice_lock_input := false
var _ending_altar: Node = null

## Edge detector for the pause menu's "В главное меню" key. Q has no InputMap action
## (nothing in the game binds it), so it is polled by hand exactly like Enter, Tab
## and Space already are.
var _menu_key_held := false

## The zone the HUD currently shows and the map panel currently draws. Travel
## replaces the `World` node outright, so this is refreshed through
## `rebind_world()` rather than resolved once at `_ready`.
var _world: Node2D = null

## Boss bar state (spec §10.4). The boss is found through the `boss` group rather
## than a node path or a class reference, exactly like the day clock is found
## through `day_clock`, so the HUD stays out of the AI's compile graph.
var _boss_panel: PanelContainer
var _boss_bar: ProgressBar
var _boss_label: Label
var _boss: Node = null
## Whether boss music is the current intent (spec §17). Edge-driven so the track
## switches once on engagement and once on disengagement, never every frame.
var _music_boss_engaged := false

## Branching-dialogue state (spec §12.2). The runner is non-null only while a
## data-driven conversation owns the panel; the legacy one-line quest dialogue
## (EventBus.dialogue_requested) leaves it null and keeps its old close-on-E
## behaviour. `_dialogue_lock_input` swallows the single input frame that opened
## the conversation, so the E press that opened it never also advances a node.
var _dialogue_runner: DialogueRunner = null
var _dialogue_option_index := 0
var _dialogue_auto_advance := true
var _dialogue_tab_held := false
var _dialogue_space_held := false
var _dialogue_lock_input := false

## Input edge latch (defect A). `Input.is_action_just_pressed` is true for exactly
## one `_process` frame, so a press whose down and up both land between two `_process`
## frames — a long frame, a stalled main thread, a fast tap, or several physics steps
## packed into one idle frame under load — is consumed before the HUD ever polls it,
## and the key is silently lost. `_input` runs for every event regardless of frame
## timing, so it records each polled press here; `_process` snapshots the latch at the
## top of the frame and consumes it, and anything left unconsumed (a press a modal
## swallowed) is dropped on the next snapshot, exactly like the one-frame edge it
## replaces. `_pending_input` is written by `_input`; `_active_input` is the snapshot
## `_process` reads and clears. The bot drives input through the `InputSource`
## override rather than real events, so `_consume_action` reads the override directly
## while one is installed and the latch stays out of the bot's way.
var _pending_input: Dictionary = {}
var _active_input: Dictionary = {}


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Merchants have no EventBus signal to knock on (the bus is not editable), so
	# they reach the HUD through this group to open the shop modal.
	add_to_group("hud")
	_build_ui()
	_connect_signals()
	# The font scale lives in the Accessibility store; re-apply it live so a change
	# made in the settings screen resizes the HUD text without reopening the world.
	# The connection dies with the HUD (Godot disconnects signals of a freed object),
	# so it needs no explicit teardown.
	var accessibility := _accessibility()
	if accessibility != null and accessibility.has_signal("changed"):
		accessibility.changed.connect(_apply_font_scale)
	_refresh_all()


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _make_theme()
	add_child(_root)

	# Everything sits inside one margin container so nothing can drift off
	# screen when the viewport changes size.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 5)
	_root.add_child(margin)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 0)
	margin.add_child(column)

	# --- top row: stats left, level/gold right, on one dark plate --------------
	# The plate (CRITIC-P1-02 / P2-20) is what makes every string in this row —
	# the zone line, the gold line, the day clock — readable on any floor: the
	# text used to sit directly on grass at 1.1–1.2:1. It is a full-width row so
	# the right-hand column stays in the top-right corner exactly where it was;
	# the plate only adds a dark surface behind the existing layout, it moves
	# nothing. The HBox fills the plate, so the expanding spacer still pushes the
	# level/gold/clock column to the right edge.
	_status_plate = PanelContainer.new()
	_status_plate.name = "StatusPlate"
	_status_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_plate.add_theme_stylebox_override("panel", _plate_style(PLATE_COLOR))
	column.add_child(_status_plate)

	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 4)
	_status_plate.add_child(top)

	var stats := VBoxContainer.new()
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats.custom_minimum_size = Vector2(BAR_W + 20, 0)
	stats.add_theme_constant_override("separation", 2)
	top.add_child(stats)

	_hp_bar = _make_bar(Color(0.78, 0.22, 0.24))
	_hp_label = _make_bar_label("HP")
	stats.add_child(_wrap_bar(_hp_bar, _hp_label))

	_mp_bar = _make_bar(Color(0.24, 0.46, 0.82))
	_mp_label = _make_bar_label("MP")
	stats.add_child(_wrap_bar(_mp_bar, _mp_label))

	# The experience bar used to be a bare 3 px strip with no caption (CRITIC-P1-03:
	# colour-only, no label, forced to 3 px against BAR_H=7). It is now a captioned
	# row like HP/MP — "XP 30/190" beside the bar — and keeps the full BAR_H height.
	_xp_bar = _make_bar(Color(0.62, 0.78, 0.32))
	_xp_label = _make_bar_label("XP")
	stats.add_child(_wrap_bar(_xp_bar, _xp_label))

	# Zone line, the fourth row of the left column, under the experience bar. It
	# lives here rather than in the right column because that one is only 58 px
	# wide and would clip a zone name to an ellipsis; the stats column is
	# BAR_W + 20 px, which fits the longest name in data/zones.json at the 8 px
	# theme font. The column grows by one row and the expanding middle spacer
	# below gives the height back, so no existing line shifts sideways or
	# overlaps another.
	_zone_label = _make_text("", Color(0.66, 0.80, 0.68))
	_zone_label.clip_text = true
	_zone_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stats.add_child(_zone_label)

	var top_spacer := Control.new()
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(top_spacer)

	var right := VBoxContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.alignment = BoxContainer.ALIGNMENT_BEGIN
	right.custom_minimum_size = Vector2(58, 0)
	right.add_theme_constant_override("separation", 1)
	top.add_child(right)

	_level_label = _make_text("Ур. 1", Color(0.92, 0.9, 0.82))
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_level_label)

	_gold_label = _make_text("0 з.", Color(0.96, 0.82, 0.38))
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_gold_label)

	# Compact day-clock line (spec §12.1), third row of the right column. It lives
	# above the expanding middle spacer, so it grows downward into empty space and
	# never shifts the bars, the prompt or the tracker.
	_clock_label = _make_text("", Color(0.78, 0.82, 0.74))
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clock_label.clip_text = true
	_clock_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	right.add_child(_clock_label)

	# --- boss bar, its own centred row under the stats row ---------------------
	_build_boss_bar(column)

	# --- toast under the top row ---
	var toast_row := CenterContainer.new()
	toast_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_row.custom_minimum_size = Vector2(0, 14)
	column.add_child(toast_row)

	_toast_label = _make_text("", Color(1.0, 0.95, 0.72))
	_toast_label.custom_minimum_size = Vector2(200, 0)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.modulate.a = 0.0
	toast_row.add_child(_toast_label)

	var middle_spacer := Control.new()
	middle_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	middle_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(middle_spacer)

	# --- interact prompt, centred above the bottom row ---
	var prompt_row := CenterContainer.new()
	prompt_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_row.custom_minimum_size = Vector2(0, 14)
	column.add_child(prompt_row)

	_prompt_label = _make_text("", Color(0.98, 0.94, 0.7))
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_row.add_child(_prompt_label)

	# --- quest tracker + skill + controls hint, all on one dark plate ----------
	# The bottom band used to float on the world too (CRITIC-P1-02: controls line
	# 1.06:1). One plate behind the tracker, the skill line and the hint puts every
	# one of them on a dark surface. The interact prompt above stays off the plate:
	# it is transient and already high-contrast.
	_hint_plate = PanelContainer.new()
	_hint_plate.name = "HintPlate"
	_hint_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_plate.add_theme_stylebox_override("panel", _plate_style(PLATE_COLOR))
	column.add_child(_hint_plate)

	var bottom := VBoxContainer.new()
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_theme_constant_override("separation", 1)
	_hint_plate.add_child(bottom)

	_quest_label = _make_text("", Color(0.86, 0.88, 0.78))
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom.add_child(_quest_label)

	# Selected skill, one compact line under the tracker. Clipped with an
	# ellipsis so a long skill name can never push past the 480 px viewport.
	_skill_label = _make_text("", Color(0.62, 0.78, 0.92))
	_skill_label.clip_text = true
	_skill_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_skill_label.max_lines_visible = 1
	bottom.add_child(_skill_label)

	# The always-visible control hint (CRITIC-P2-05): it used to omit `pause`/Esc
	# and the four quick slots even though both are rebindable and documented. They
	# go on a compact second line so the band stays inside 480x270. The colour is
	# lifted onto the plate's dark surface for a clear ≥4.5:1 (was 1.06:1 on grass).
	_hint_label = _make_text(
		"WASD · ЛКМ удар · ПКМ умение · Space рывок · E действие · I инв · J журнал · M карта · C персонаж · K навыки · F5/F9\nEsc пауза · 1–4 быстрый слот",
		COLOR_HINT_TEXT
	)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom.add_child(_hint_label)

	_build_dialogue_panel()
	_build_inventory_panel()
	_build_journal_panel()
	_build_pause_panel()
	_build_settings_panel()
	_build_map_panel()
	_build_character_panel()
	_build_shop_panel()
	_build_craft_panel()
	_build_skills_panel()
	_build_defeat_panel()
	_build_victory_panel()
	_build_ending_choice_panel()


## The defeat screen lives here rather than in its own script (unlike the shop or
## the bench) because all it owns is a two-row cursor and three labels: everything
## else it would need — `_panel_style`, `_make_text`, the centred-panel placement,
## the `InputSource` polling and the `ui_blocking`/pause bookkeeping — already lives
## in this file, and a separate script would carry a second copy of each. The
## victory screen is here for the same reason plus one more: it renders the menu's
## credit block, and the two must not be able to disagree about what they claim.
func _build_defeat_panel() -> void:
	_defeat_panel = PanelContainer.new()
	_defeat_panel.name = "DefeatPanel"
	_defeat_panel.set_anchors_preset(Control.PRESET_CENTER)
	_defeat_panel.position = Vector2(-70, -34)
	_defeat_panel.custom_minimum_size = Vector2(140, 0)
	_defeat_panel.visible = false
	_defeat_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.08, 0.97)))
	_root.add_child(_defeat_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	_defeat_panel.add_child(box)

	box.add_child(_make_text("Вы погибли", Color(0.86, 0.3, 0.28)))

	for option in DEFEAT_OPTIONS:
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(128, 10)
		box.add_child(row)
		_defeat_rows.append(row)

	box.add_child(_make_text("↑↓ выбор · E или Enter", COLOR_HINT))


## The victory screen: the ending name over the same credit block the menu shows,
## scrolled inside a fixed-height box so 22 lines of credits cannot push the panel
## past a 270 px viewport.
func _build_victory_panel() -> void:
	_victory_panel = PanelContainer.new()
	_victory_panel.name = "VictoryPanel"
	_victory_panel.set_anchors_preset(Control.PRESET_CENTER)
	_victory_panel.position = Vector2(-156, -96)
	_victory_panel.custom_minimum_size = Vector2(312, 0)
	_victory_panel.visible = false
	_victory_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.08, 0.97)))
	_root.add_child(_victory_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	_victory_panel.add_child(box)

	_victory_title = _make_text("", Color(0.96, 0.86, 0.5))
	_victory_title.add_theme_font_size_override("font_size", 11)
	box.add_child(_victory_title)

	_victory_scroll = ScrollContainer.new()
	_victory_scroll.name = "Credits"
	_victory_scroll.custom_minimum_size = Vector2(300, 132)
	_victory_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_victory_scroll)

	_victory_box = VBoxContainer.new()
	_victory_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_victory_box.add_theme_constant_override("separation", 0)
	_victory_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_victory_scroll.add_child(_victory_box)

	# The ending is the end of the run, so the only way off this screen is back to
	# the menu — there is no "close" that hands control back to a finished world. The
	# same keys that closed it before now leave the run; the wording says so plainly.
	_victory_hint = _make_text("↑↓ прокрутка · E или Esc — В главное меню", COLOR_HINT)
	box.add_child(_victory_hint)


## The ending-choice panel: a title, then one pair of rows per fate (name + availability,
## then its one-line description or, when locked, the reason it is shut), then the
## controls line. The rows are built once here and only their text/colour are rewritten
## on each refresh, exactly like the defeat screen's two rows — the panel never rebuilds
## its node tree while the player walks the cursor.
func _build_ending_choice_panel() -> void:
	_ending_choice_panel = PanelContainer.new()
	_ending_choice_panel.name = "EndingChoicePanel"
	_ending_choice_panel.set_anchors_preset(Control.PRESET_CENTER)
	_ending_choice_panel.position = Vector2(-120, -70)
	_ending_choice_panel.custom_minimum_size = Vector2(240, 0)
	_ending_choice_panel.visible = false
	_ending_choice_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.08, 0.97)))
	_root.add_child(_ending_choice_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 1)
	_ending_choice_panel.add_child(box)

	box.add_child(_make_text("Выбрать судьбу", Color(0.96, 0.86, 0.5)))

	for _ending in range(3):
		var row := _make_text("", COLOR_ROW)
		row.custom_minimum_size = Vector2(228, 10)
		box.add_child(row)
		_ending_choice_rows.append(row)
		var desc := _make_text("", COLOR_HINT)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(228, 0)
		box.add_child(desc)
		_ending_choice_descs.append(desc)

	box.add_child(_make_text("↑↓ выбор · E или Enter — принять · Esc — уйти", COLOR_HINT))


## The character screen lives in its own script (like SettingsPanel): it owns
## its layout and centring, and hud.gd only opens, closes and gates it.
func _build_character_panel() -> void:
	_character_panel = CharacterPanel.new()
	_character_panel.name = "CharacterPanel"
	_character_panel.visible = false
	_root.add_child(_character_panel)


## The shop screen lives in its own script (like CharacterPanel): it owns its
## layout and centring, and hud.gd only opens, closes and gates it. The panel is
## given the merchant's ShopManager when it opens, so it never builds its own.
func _build_shop_panel() -> void:
	_shop_panel = ShopPanel.new()
	_shop_panel.name = "ShopPanel"
	_shop_panel.visible = false
	_root.add_child(_shop_panel)


## The craft bench lives in its own script (like ShopPanel): it owns its layout
## and centring, and hud.gd only opens, closes and gates it. The panel is given
## the station's CraftManager when it opens, so it never builds its own and never
## learns a recipe from anywhere but data/recipes.json.
func _build_craft_panel() -> void:
	_craft_panel = CraftPanel.new()
	_craft_panel.name = "CraftPanel"
	_craft_panel.visible = false
	_root.add_child(_craft_panel)


## The skills screen lives in its own script (like CharacterPanel): it owns its
## layout and centring, and hud.gd only opens, closes and gates it. It reads
## GameState and SkillDB directly, so the HUD passes it nothing.
func _build_skills_panel() -> void:
	_skills_panel = SkillsPanel.new()
	_skills_panel.name = "SkillsPanel"
	_skills_panel.visible = false
	_root.add_child(_skills_panel)


## Rebinding lives in its own script (like MapPanel): it has its own raw-event
## capture and paging logic, and hud.gd only opens, closes and gates it.
func _build_settings_panel() -> void:
	_settings_panel = SettingsPanel.new()
	_settings_panel.name = "SettingsPanel"
	_settings_panel.visible = false
	_settings_panel.closed.connect(_close_settings)
	_root.add_child(_settings_panel)


func _build_map_panel() -> void:
	var parent := get_parent()
	var world: Node = parent.get_node_or_null("World") if parent != null else null
	_world = world as Node2D
	_map_panel = MapPanel.new()
	_map_panel.name = "MapPanel"
	_map_panel.setup(world)
	_map_panel.visible = false
	_root.add_child(_map_panel)


## Travel replaced the `World` node, so every reference the HUD holds to the old
## zone has to go in the same call — the map panel's world, the day clock it
## cached from the freed zone, and the zone line. `ZoneManager.travel` calls this
## right after the new world is in the tree and before it toasts the zone name.
func rebind_world(world: Node2D) -> void:
	_world = world
	if _map_panel != null:
		_map_panel.set_world(world)
		_map_panel.refresh()
	# The day clock is owned by its zone and found through the `day_clock` group,
	# and the zone it belonged to was freed with it, so the cached node is a freed
	# instance from here on. Dropping it lets `refresh_clock_line` resolve the new
	# zone's clock on the next tick instead of holding a dead reference.
	_day_clock = null
	refresh_zone_line()


## Rebuilds the zone line. The live world is the authority on what the player
## sees, because it is the thing travel replaces; the zone table is only the
## fallback for a scene with no world at all, where `GameState.zone` is the last
## place the run is known to have been.
func refresh_zone_line() -> void:
	if _zone_label == null:
		return
	var shown := ""
	if _world != null and is_instance_valid(_world) and _world.has_method("zone_name"):
		shown = String(_world.call("zone_name"))
	if shown == "":
		shown = ZoneManager.zone_display_name(String(GameState.zone))
	_zone_label.text = "Зона: %s" % shown


## Read-only view of the zone line, so a test or a screenshot probe can read what
## the player sees without reaching into the HUD's private node tree — the same
## contract `clock_line_text` gives.
func zone_line_text() -> String:
	return _zone_label.text if _zone_label != null else ""


## The world the map panel is bound to right now, so a test can prove a travel
## rebound it rather than trusting the toast that says so.
func map_bound_world() -> Node:
	return _map_panel.bound_world() if _map_panel != null else null


# --- read-only views for the readability/accessibility checks ------------------
# Same contract as `zone_line_text`/`clock_line_text`: a test reads what the player
# sees and what the plates are made of without reaching into the HUD's private tree.

func hp_caption_text() -> String:
	return _hp_label.text if _hp_label != null else ""


func mp_caption_text() -> String:
	return _mp_label.text if _mp_label != null else ""


func xp_caption_text() -> String:
	return _xp_label.text if _xp_label != null else ""


## The XP bar's minimum height in pixels. CRITIC-P1-03 flagged it forced to 3 px;
## it must now be at least 5 (it uses BAR_H).
func xp_bar_min_height() -> float:
	return _xp_bar.custom_minimum_size.y if _xp_bar != null else 0.0


## The dark plate styles behind the status block and the controls band. A test
## asserts each is a dark, reasonably opaque StyleBoxFlat.
func status_plate_style() -> StyleBoxFlat:
	if _status_plate == null:
		return null
	return _status_plate.get_theme_stylebox("panel") as StyleBoxFlat


func hint_plate_style() -> StyleBoxFlat:
	if _hint_plate == null:
		return null
	return _hint_plate.get_theme_stylebox("panel") as StyleBoxFlat


## The union of the on-screen HUD overlay bounds, so a test can prove the HUD stays
## inside the 480x270 viewport at the largest font scale. Only the always-present
## plates and the transient centred rows are measured; hidden panels contribute
## nothing. Returns an empty Rect2 when nothing is drawn.
func hud_content_bounds() -> Rect2:
	var bounds := Rect2()
	var controls: Array = [_status_plate, _hint_plate, _toast_label, _prompt_label, _boss_panel]
	for control in controls:
		if control == null or not is_instance_valid(control) or not control.visible:
			continue
		var rect := (control as Control).get_global_rect()
		if rect.size == Vector2.ZERO:
			continue
		bounds = rect if bounds.size == Vector2.ZERO else bounds.merge(rect)
	return bounds


## The current theme font size in pixels, so a test can confirm the accessibility
## font scale actually moved the HUD's `default_font_size`.
func current_font_size() -> int:
	if _root == null or _root.theme == null:
		return 0
	return _root.theme.default_font_size


## The rarity colour as actually painted in the inventory list. Normally the item's
## own tier colour; in colour-blind mode a luminance-graded variant so the tiers
## separate by lightness, not hue alone (CRITIC-P1-11 / P2-15: rarity was colour-
## only). Reading the colourblind flag through the Accessibility store keeps the
## HUD free of any autoload identifier and makes the mode do something real.
func rarity_display_color(tier: String) -> Color:
	var base := ItemDB.rarity_color(tier)
	var store := _accessibility()
	if store != null and store.has_method("colorblind_enabled") and bool(store.call("colorblind_enabled")):
		return _colorblind_rarity_color(tier, base)
	return base


## A colour-blind-safe rarity ramp: the tiers are re-ordered onto a monotonic
## luminance ladder (grey -> blue -> amber -> magenta -> white-gold) so each step
## differs in lightness, which the two common red-green colour-blindness types still
## resolve. Only used while colour-blind mode is on.
func _colorblind_rarity_color(tier: String, _base: Color) -> Color:
	match tier:
		"common":
			return Color(0.62, 0.62, 0.64)
		"uncommon":
			return Color(0.45, 0.66, 0.95)
		"rare":
			return Color(0.98, 0.78, 0.30)
		"epic":
			return Color(0.80, 0.52, 0.95)
		"legendary":
			return Color(1.0, 0.94, 0.62)
		_:
			return _base


## The boss bar is its own centred row in the top column, between the stat row and
## the toast row. It is a row rather than an absolutely placed panel for one
## reason: a row can never overlap the HP/mana column on its left or the day-clock
## column on its right, because those live in a different row and the container
## gives each of them its own band. While no boss is engaged the panel is hidden,
## and a hidden child takes no space in a BoxContainer, so the layout of every
## screen that existed before bosses is pixel-identical.
func _build_boss_bar(column: Control) -> void:
	var row := CenterContainer.new()
	row.name = "BossBarRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	_boss_panel = PanelContainer.new()
	_boss_panel.name = "BossBar"
	_boss_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_panel.visible = false
	_boss_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.06, 0.07, 0.09, 0.92)))
	row.add_child(_boss_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 1)
	_boss_panel.add_child(box)

	# One line with the name, the pool and the phase marker, then the bar itself.
	# The line is clipped rather than wrapped so a long boss name can never widen
	# the row and push the toast around.
	_boss_label = _make_text("", Color(0.96, 0.86, 0.5))
	_boss_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_label.clip_text = true
	_boss_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_boss_label.custom_minimum_size = Vector2(BOSS_BAR_W, 0)
	box.add_child(_boss_label)

	_boss_bar = _make_bar(COLOR_BOSS_BAR)
	_boss_bar.custom_minimum_size = Vector2(BOSS_BAR_W, 5)
	box.add_child(_boss_bar)


func _build_dialogue_panel() -> void:
	_dialogue_panel = PanelContainer.new()
	_dialogue_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_dialogue_panel.position = Vector2(-150, -86)
	_dialogue_panel.custom_minimum_size = Vector2(300, 62)
	_dialogue_panel.visible = false
	_dialogue_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.06, 0.07, 0.09, 0.95)))
	_root.add_child(_dialogue_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	_dialogue_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	_dialogue_speaker = _make_text("", Color(0.98, 0.84, 0.42))
	box.add_child(_dialogue_speaker)

	_dialogue_text = _make_text("", Color(0.93, 0.93, 0.88))
	_dialogue_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_text.custom_minimum_size = Vector2(286, 0)
	box.add_child(_dialogue_text)

	# Option list for branching nodes (spec §12.2). Hidden on plain lines so it
	# adds no height there; the "> " cursor marks the row the movement actions are
	# on. It lives inside the same box, so a conversation with choices simply
	# grows the bottom-anchored panel upward instead of overlapping the world.
	_dialogue_options = _make_text("", Color(0.86, 0.9, 0.78))
	_dialogue_options.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_options.custom_minimum_size = Vector2(286, 0)
	_dialogue_options.visible = false
	box.add_child(_dialogue_options)

	# Controls line. Kept as a field so the auto-advance toggle (Tab) can rewrite
	# it live; the runner refreshes it on every node.
	_dialogue_hint = _make_text("[E] продолжить", Color(0.6, 0.62, 0.6))
	_dialogue_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_dialogue_hint)


func _build_inventory_panel() -> void:
	_inventory_panel = PanelContainer.new()
	_inventory_panel.set_anchors_preset(Control.PRESET_CENTER)
	# CRITIC-P2-13: the inventory sat 6 px left of centre while every other panel is
	# exact. With PRESET_CENTER the position is an offset from the viewport centre, so
	# centring a panel of width W needs offset.x = -W/2. The minimum width is 168, so
	# the offset was -90 where it should be -84. `_center_inventory_panel` re-derives
	# it from the laid-out width on open, so it stays centred even if a long item name
	# grows the panel past its minimum.
	_inventory_panel.position = Vector2(-84, -70)
	_inventory_panel.custom_minimum_size = Vector2(168, 0)
	_inventory_panel.visible = false
	_inventory_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.06, 0.07, 0.09, 0.97)))
	_root.add_child(_inventory_panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	_inventory_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)

	box.add_child(_make_text("Инвентарь  [I] закрыть", Color(0.96, 0.86, 0.5)))

	# Live stats line: recomputed on every refresh so equipping/unequipping is
	# visible the instant it happens, without the player doing the math.
	_inventory_stats = _make_text("Атака 0 · Защита 0", Color(0.78, 0.86, 0.66))
	box.add_child(_inventory_stats)

	_inventory_list = VBoxContainer.new()
	_inventory_list.add_theme_constant_override("separation", 1)
	box.add_child(_inventory_list)

	# Selected-row detail (spec §14.1): the rarity and the source of whatever the
	# cursor is on, plus a warning line that only appears when a requirement is
	# unmet. Both wrap to at most two lines so the full text stays readable, and
	# both live OUTSIDE _inventory_list so the row count stays capped at
	# MAX_VISIBLE_ROWS and the panel stays inside 480x270 — the requirement line is
	# hidden (zero height) when there is nothing to warn about.
	_inventory_detail = _make_text("", COLOR_ROW)
	_inventory_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inventory_detail.max_lines_visible = 2
	box.add_child(_inventory_detail)

	_inventory_requirement = _make_text("", COLOR_WARNING)
	_inventory_requirement.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inventory_requirement.max_lines_visible = 2
	_inventory_requirement.visible = false
	box.add_child(_inventory_requirement)

	# Quick slots live here instead of a static hint so a re-assigned slot shows
	# up without a rebuild. Four short lines keep the panel inside 480x270.
	_quick_slot_list = VBoxContainer.new()
	_quick_slot_list.add_theme_constant_override("separation", 1)
	box.add_child(_quick_slot_list)


func _build_journal_panel() -> void:
	_journal_panel = PanelContainer.new()
	_journal_panel.set_anchors_preset(Control.PRESET_CENTER)
	_journal_panel.position = Vector2(-104, -70)
	_journal_panel.custom_minimum_size = Vector2(208, 0)
	_journal_panel.visible = false
	_journal_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.06, 0.07, 0.09, 0.97)))
	_root.add_child(_journal_panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	_journal_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)

	box.add_child(_make_text("Журнал заданий  [J] закрыть", Color(0.96, 0.86, 0.5)))

	_journal_list = VBoxContainer.new()
	_journal_list.add_theme_constant_override("separation", 1)
	box.add_child(_journal_list)


func _build_pause_panel() -> void:
	_pause_panel = PanelContainer.new()
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.position = Vector2(-70, -46)
	_pause_panel.custom_minimum_size = Vector2(140, 92)
	_pause_panel.visible = false
	_pause_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.06, 0.08, 0.97)))
	_root.add_child(_pause_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	_pause_panel.add_child(box)
	box.add_child(_make_text("Пауза", Color(0.96, 0.86, 0.5)))
	box.add_child(_make_text("Esc — продолжить", Color(0.9, 0.9, 0.86)))
	box.add_child(_make_text("F5 — сохранить", Color(0.9, 0.9, 0.86)))
	box.add_child(_make_text("F9 — загрузить", Color(0.9, 0.9, 0.86)))
	box.add_child(_make_text("E — Настройки управления", Color(0.9, 0.9, 0.86)))
	box.add_child(_make_text("C — Персонаж", Color(0.9, 0.9, 0.86)))
	box.add_child(_make_text("K — Навыки", Color(0.9, 0.9, 0.86)))
	# Saves happen on F5, so leaving needs no prompt of its own: the item simply
	# hands the run back to the menu, and whatever was saved is what «Продолжить»
	# and «Загрузка» will find there.
	box.add_child(_make_text("Q — В главное меню", Color(0.9, 0.9, 0.86)))


## The HUD theme (CRITIC-P1-04). No pixel font ships in `assets/` and downloading
## one is out of scope, so the honest fix is option (a): keep the built-in OS font
## but render it hard-edged and pixel-snapped. `antialiasing = NONE` and
## `subpixel_positioning = DISABLED` (both 0 in Godot 4.7) stop the text server
## from blurring and sub-pixel-shifting the glyphs, so at the native 480x270 buffer
## each glyph lands on whole pixels and the project's integer 3x nearest upscale
## (`window/stretch/scale_mode="integer"`, `default_texture_filter=0`) keeps it
## crisp instead of smearing an anti-aliased bitmap. The size is an integer
## multiple of the pixel grid (see `_hud_font_size`). The limitation is recorded in
## `docs/ARCHITECTURE.md`: this is still a proportional OS font, so glyph metrics
## remain platform-dependent — a shipped bitmap font is the only full fix, and that
## needs an asset we deliberately do not download here.
func _make_theme() -> Theme:
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Helvetica Neue", "Arial Unicode MS", "Arial", "DejaVu Sans", "sans-serif"
	])
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = _hud_font_size()
	return theme


## The theme font size in pixels: the base 8 px scaled by the accessibility font
## scale, rounded to an integer and clamped to 8..12 (100..150 %). The clamp is
## what keeps the HUD inside 480x270 at the largest setting; the integer rounding is
## what keeps the glyphs on the pixel grid.
func _hud_font_size() -> int:
	var factor := 1.0
	var store := _accessibility()
	if store != null and store.has_method("font_scale_factor"):
		factor = float(store.call("font_scale_factor"))
	return clampi(int(round(float(BASE_FONT_SIZE) * factor)), BASE_FONT_SIZE, 12)


## Re-applies the current accessibility font scale to the live theme. Called on the
## `Accessibility.changed` signal so a change made in the settings screen takes
## effect without reopening the world.
func _apply_font_scale() -> void:
	if _root != null and _root.theme != null:
		_root.theme.default_font_size = _hud_font_size()


## The Accessibility autoload by name through the scene root (the project rule that
## nothing names an autoload as an identifier, and what keeps the HUD loading under
## `godot --script`). Null when absent, in which case every reader falls back to the
## shipped default.
func _accessibility() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("Accessibility")


## The dark plate behind a HUD band: a flat, borderless, slightly rounded box in
## `PLATE_COLOR`. Unlike `_panel_style` it carries no border (a border would draw a
## hard frame around the overlay) and it adds a small content margin so text never
## sits flush against the plate edge.
func _plate_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	return sb


func _panel_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = Color(0.32, 0.34, 0.38, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	return sb


func _make_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar.show_percentage = false
	bar.max_value = 100
	bar.value = 100
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.13, 0.15, 0.85)
	bg.set_corner_radius_all(1)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(1)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


func _make_bar_label(prefix: String) -> Label:
	return _make_text(prefix, Color(0.95, 0.95, 0.9))


func _wrap_bar(bar: ProgressBar, label: Label) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	# The caption now carries the whole "HP 84/100" text (CRITIC-P1-03), so it needs
	# room for the widest value ("MP 100/100"); a fixed minimum keeps all three bars
	# starting on the same column instead of sliding as the numbers change width.
	label.custom_minimum_size = Vector2(46, 0)
	row.add_child(label)
	row.add_child(bar)
	return row


func _make_text(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _connect_signals() -> void:
	EventBus.player_health_changed.connect(_on_health)
	EventBus.player_mana_changed.connect(_on_mana)
	EventBus.player_xp_changed.connect(_on_xp)
	EventBus.player_gold_changed.connect(_on_gold)
	EventBus.inventory_changed.connect(_refresh_inventory)
	EventBus.interact_prompt.connect(_on_prompt)
	EventBus.toast.connect(_on_toast)
	EventBus.dialogue_requested.connect(_on_dialogue)
	EventBus.quest_started.connect(func(_id): _refresh_quest())
	EventBus.quest_progress.connect(func(_id, _c, _t): _refresh_quest())
	EventBus.quest_completed.connect(func(_id): _refresh_quest())
	EventBus.skill_selected.connect(func(_id): _refresh_skill())
	# The defeat screen listens to the same death signal the player does rather than
	# watching HP: `GameState.take_damage()` is the one place that decides a run has
	# ended, and reading its verdict is what keeps this screen from ever disagreeing
	# with the player about whether he is dead.
	EventBus.player_died.connect(_open_defeat)
	EventBus.player_respawned.connect(_close_defeat)


## The HUD is the only node in this project that pauses the tree, so leaving it —
## a scene change back to the menu, or a test freeing the scene — must never hand
## whatever comes next a paused tree with no screen left on it to unpause.
func _exit_tree() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.paused:
		loop.paused = false


func _refresh_all() -> void:
	_on_health(GameState.hp, GameState.max_hp)
	_on_mana(GameState.mana, GameState.max_mana)
	_on_xp(GameState.xp, GameState.xp_to_next, GameState.level)
	_on_gold(GameState.gold)
	_refresh_inventory()
	_refresh_quest()
	_refresh_skill()
	refresh_zone_line()


## The bar captions now read "HP 84/100" (CRITIC-P1-03): the number used to
## overwrite the "HP" caption, so the bar was colour-only. The caption names the
## resource and shows current/max as text; the bar still shows the same value
## graphically. The format is asserted by a test, so it is a contract, not a detail.
func _on_health(current: int, maximum: int) -> void:
	_hp_bar.max_value = maxi(1, maximum)
	_hp_bar.value = current
	_hp_label.text = "HP %d/%d" % [current, maximum]


func _on_mana(current: int, maximum: int) -> void:
	_mp_bar.max_value = maxi(1, maximum)
	_mp_bar.value = current
	_mp_label.text = "MP %d/%d" % [current, maximum]
	_refresh_skill()


func _on_xp(current: int, needed: int, level: int) -> void:
	_xp_bar.max_value = maxi(1, needed)
	_xp_bar.value = current
	_xp_label.text = "XP %d/%d" % [current, needed]
	_level_label.text = "Ур. %d" % level


func _on_gold(amount: int) -> void:
	_gold_label.text = "%d з." % amount


func _refresh_inventory() -> void:
	if _inventory_list == null:
		return
	_refresh_quick_slots()
	_refresh_stats()
	for child in _inventory_list.get_children():
		child.queue_free()
	var size := GameState.inventory.size()
	if size == 0:
		_inventory_selection = 0
		_inventory_scroll = 0
		_inventory_list.add_child(_make_text("пусто", Color(0.6, 0.6, 0.58)))
		_set_inventory_detail("")
		return
	# Clamp the cursor when the list shrank below it (an item was consumed).
	_inventory_selection = clampi(_inventory_selection, 0, size - 1)
	# Keep the cursor inside the visible window so the panel never overflows.
	if _inventory_selection < _inventory_scroll:
		_inventory_scroll = _inventory_selection
	elif _inventory_selection >= _inventory_scroll + MAX_VISIBLE_ROWS:
		_inventory_scroll = _inventory_selection - (MAX_VISIBLE_ROWS - 1)
	_inventory_scroll = clampi(_inventory_scroll, 0, maxi(0, size - MAX_VISIBLE_ROWS))
	var first := _inventory_scroll
	var last := mini(size, first + MAX_VISIBLE_ROWS)
	for i in range(first, last):
		var slot: Dictionary = GameState.inventory[i]
		var id := String(slot["id"])
		var amount := int(slot["amount"])
		# Icon first, then name, then count, then the worn marker (spec §14.1).
		var label := "%s %s x%d" % [ItemDB.icon(id), ItemDB.display_name(id), amount]
		# One lookup against all six slots rather than a hardcoded pair, so an
		# accessory or a shield is tagged the moment it is worn.
		var equipped: bool = GameState.equipped_slot_of(id) != ""
		if equipped:
			label += "  [надето]"
		var selected: bool = i == _inventory_selection
		if selected:
			label = "> " + label
		# Row colour is the item's rarity colour (or its colour-blind-safe variant
		# while that mode is on); the selected row is lightened so the "> " cursor
		# stays visible against every tier, from pale common-grey to bright
		# legendary-gold.
		var row_color := rarity_display_color(ItemDB.rarity(id))
		if selected:
			row_color = row_color.lightened(0.35)
		_inventory_list.add_child(_make_text(label, row_color))
	# The detail line always describes the row the cursor is on, whatever rarity.
	_set_inventory_detail(String(GameState.inventory[_inventory_selection]["id"]))


## Fills the selected-row detail line (rarity + source) and the requirement
## warning. An empty id (empty inventory) clears both. The requirement line shows
## only when the item names a requirement the player has not yet met, so it adds
## height only when there is something to warn about — the panel stays bounded.
func _set_inventory_detail(item_id: String) -> void:
	if _inventory_detail == null:
		return
	if item_id == "":
		_inventory_detail.text = ""
		_inventory_requirement.visible = false
		return
	var tier := ItemDB.rarity(item_id)
	var detail := "Редкость: %s" % String(RARITY_LABELS_RU.get(tier, tier))
	var source := ItemDB.source(item_id)
	if source != "":
		detail += " · Источник: %s" % source
	_inventory_detail.text = detail
	_inventory_detail.add_theme_color_override("font_color", rarity_display_color(tier))
	var unmet: PackedStringArray = []
	var requirements := ItemDB.requirements(item_id)
	for attr_name: String in requirements:
		var raw: Variant = requirements[attr_name]
		var required := int(raw) if (raw is int or raw is float) else 0
		if GameState.attribute(attr_name) < required:
			unmet.append("%s %d" % [String(ATTRIBUTE_LABELS_RU.get(attr_name, attr_name)), required])
	if unmet.is_empty():
		_inventory_requirement.visible = false
	else:
		_inventory_requirement.text = "Требуется: %s" % ", ".join(unmet)
		_inventory_requirement.visible = true


## One compact line with the player's current combat stats, so the effect of an
## equip/unequip is visible without leaving the panel. The speed term only shows
## when the equipment actually grants some, so the common line stays short.
func _refresh_stats() -> void:
	if _inventory_stats == null:
		return
	var line := "Атака %d · Защита %d" % [GameState.total_attack(), GameState.total_defense()]
	var speed_bonus := GameState.total_bonus("speed_bonus")
	if speed_bonus > 0:
		line += " · Скорость +%d%%" % speed_bonus
	_inventory_stats.text = line


## Move the selection cursor by `delta` rows, clamped to the inventory bounds.
func _move_inventory_selection(delta: int) -> void:
	var size := GameState.inventory.size()
	if size == 0:
		_inventory_selection = 0
		return
	_inventory_selection = clampi(_inventory_selection + delta, 0, size - 1)
	_refresh_inventory()


## E / Enter on the selected row: equip it if it is equipment and not yet worn,
## unequip it if it is the item currently in a slot. Anything that is not
## equipment only toasts and leaves the equipment untouched.
func _activate_inventory_selection() -> void:
	var size := GameState.inventory.size()
	if size == 0:
		return
	_inventory_selection = clampi(_inventory_selection, 0, size - 1)
	var id := String(GameState.inventory[_inventory_selection]["id"])
	if not ItemDB.is_equipment(id):
		EventBus.toast.emit("Нельзя надеть")
		return
	# The slot comes from the state rather than from the slot name in the item's
	# data, because that name is `accessory` while the real slot is one of the two
	# accessory slots: asking the state is the only way to clear the right one.
	var worn_slot := GameState.equipped_slot_of(id)
	if worn_slot != "":
		GameState.unequip(worn_slot)
	else:
		# Ask the state why it would refuse before trying, so an unmet attribute
		# requirement toasts the exact reason ("Нужна сила 7 (у вас 5)") rather
		# than a generic failure. An empty blocker means equip() will succeed.
		var blocker := GameState.equip_blocker(id)
		if blocker != "":
			EventBus.toast.emit(blocker)
		else:
			GameState.equip(id)
	_refresh_inventory()


## Inventory owns the input while it is open: navigation rows and the equip key
## are handled here, and the player stays blocked by GameState.ui_blocking, so
## the same arrows never move the character.
func _process_inventory_navigation() -> void:
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 1
	if _consume_action(&"move_down"):
		delta += 1
	if delta != 0:
		_move_inventory_selection(delta)
	# Enter has no InputMap action (it is a human-only alias for E), so it is
	# edge-detected by hand; the bot drives equipping through `interact`.
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if _consume_action(&"interact") or enter_edge:
		_activate_inventory_selection()


func is_inventory_open() -> bool:
	return _inventory_open


func inventory_selection() -> int:
	return _inventory_selection


func visible_inventory_row_count() -> int:
	if _inventory_list == null:
		return 0
	return _inventory_list.get_child_count()


## Text of the currently visible inventory rows, in order, so a test (or a
## screenshot probe) can read the cursor marker and the [надето] tag without
## reaching into the panel's private node tree.
func inventory_row_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	if _inventory_list == null:
		return out
	for child in _inventory_list.get_children():
		if child is Label:
			out.append((child as Label).text)
	return out


## C opens the character screen over everything else: the modal panels it could
## visually collide with are closed first, the same way the map open does it.
func _toggle_character() -> void:
	if _character_open:
		_close_character()
	else:
		if _dialogue_open:
			close_dialogue()
		if _inventory_open:
			_toggle_inventory()
		if _journal_open:
			_toggle_journal()
		if _map_open:
			_close_map()
		if _settings_open:
			_close_settings()
		# The craft bench is a sibling modal too: it owns the screen and must not
		# stay open under the character panel.
		if _craft_open:
			close_craft()
		# The skills screen is a sibling modal as well; C switches to the character
		# panel from it the same way it does from the bench.
		if _skills_open:
			_close_skills()
		# The pause menu advertises "C — Персонаж", so C can arrive while it is
		# on screen. Hide it, otherwise the two centred panels overlap.
		if _paused:
			_close_pause()
		_character_open = true
		_enter_held = false
		if _character_panel != null:
			_character_panel.visible = true
			_character_panel.open()
	_recompute_ui_blocking()


## One close path for the character screen, so every sibling modal (inventory,
## journal, map, Esc) leaves both the flag and the node in the same state.
func _close_character() -> void:
	if not _character_open:
		return
	_character_open = false
	_enter_held = false
	if _character_panel != null:
		_character_panel.visible = false
	_recompute_ui_blocking()


## The character screen owns the input while it is open: the cursor walks the
## four attributes with the movement actions, and E / Enter spends a point on
## the selected one. Enter has no InputMap action (a human-only alias for E), so
## it is edge-detected by hand, exactly like in the inventory.
func _process_character_navigation() -> void:
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 1
	if _consume_action(&"move_down"):
		delta += 1
	if delta != 0 and _character_panel != null:
		_character_panel.move_selection(delta)
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if (_consume_action(&"interact") or enter_edge) and _character_panel != null:
		_character_panel.spend_selected_point()


func is_character_open() -> bool:
	return _character_open


func open_character_for_shot() -> void:
	if not _character_open:
		_toggle_character()


## Opens the shop modal with the merchant's own manager. Like the map it closes
## every panel it could visually overlap first, then takes the screen. The manager
## is owned by the merchant, so the stock shown is that merchant's live stock.
func open_shop(shop_manager: ShopManager) -> void:
	if shop_manager == null:
		return
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _craft_open:
		close_craft()
	_close_character()
	_close_skills()
	if _paused:
		_close_pause()
	_shop_manager = shop_manager
	_shop_open = true
	_tab_held = false
	if _shop_panel != null:
		_shop_panel.visible = true
		_shop_panel.open(shop_manager)
	GameState.ui_blocking = true


func close_shop() -> void:
	if not _shop_open:
		return
	_shop_open = false
	_tab_held = false
	if _shop_panel != null:
		_shop_panel.visible = false
	_recompute_ui_blocking()


func is_shop_open() -> bool:
	return _shop_open


## Screenshot hook: builds a throwaway manager from the live state so the shop can
## be captured without a merchant in the frame. The real merchant path is
## `open_shop`, which passes the merchant's own manager instead.
func open_shop_for_shot() -> void:
	if _shop_open:
		return
	open_shop(ShopManager.new(GameState))


## Opens the craft bench with the station's own manager. Like the shop it closes
## every panel it could visually overlap first, then takes the screen. Opening
## crafts nothing: the manager is only handed to the panel, which acts on E.
func open_craft(craft_manager: CraftManager) -> void:
	if craft_manager == null:
		return
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _shop_open:
		close_shop()
	_close_character()
	_close_skills()
	if _paused:
		_close_pause()
	_craft_manager = craft_manager
	_craft_open = true
	if _craft_panel != null:
		_craft_panel.visible = true
		_craft_panel.open(craft_manager)
	GameState.ui_blocking = true


func close_craft() -> void:
	if not _craft_open:
		return
	_craft_open = false
	if _craft_panel != null:
		_craft_panel.visible = false
	_recompute_ui_blocking()


func is_craft_open() -> bool:
	return _craft_open


## Screenshot hook: builds a throwaway manager bound to the smith's bench from the
## live state so the forge can be captured without the NPC in frame. The real path
## is `open_craft`, which takes the manager the smith itself created.
func open_craft_for_shot() -> void:
	if _craft_open:
		return
	open_craft(CraftManager.new(GameState, "smith"))


# Read-only views of the craft panel, so a test or a screenshot probe can read
# the recipe list, the promised result and the refusal line without reaching into
# the panel's private node tree — the same contract `inventory_row_texts` gives.

func craft_row_texts() -> PackedStringArray:
	return _craft_panel.row_texts() if _craft_panel != null else PackedStringArray()


func craft_material_texts() -> PackedStringArray:
	return _craft_panel.material_texts() if _craft_panel != null else PackedStringArray()


func craft_detail_text() -> String:
	return _craft_panel.detail_text() if _craft_panel != null else ""


func craft_reason_text() -> String:
	return _craft_panel.reason_text() if _craft_panel != null else ""


## Parks the craft cursor on one row without simulating keys (test/screenshot).
func craft_select_row(index: int) -> void:
	if _craft_panel != null:
		_craft_panel.select_row(index)


# --- skills screen (spec §16.1) -----------------------------------------------

## The single source of truth for the modal input gate. Every open/close path routes
## through here so the flag can never disagree with the set of panels that are
## actually open: a panel that forgot to list one sibling would clear the block while
## that sibling still owned the screen. `_skills_open` is one term among equals here,
## exactly like the shop and the bench.
func _recompute_ui_blocking() -> void:
	GameState.ui_blocking = _skills_open or _inventory_open or _dialogue_open or _journal_open \
			or _paused or _map_open or _settings_open or _shop_open or _craft_open or _character_open \
			or _ending_choice_open


## K opens the skills screen over everything else: every modal it could visually
## collide with is closed first (the same way the character screen does it), then it
## takes the screen. The pause menu advertises "K — Навыки", so K can arrive while the
## game is paused; the pause is dropped on the way in so the world is not left frozen
## under a panel that does not pause anything itself.
func _toggle_skills() -> void:
	if _skills_open:
		_close_skills()
		return
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _settings_open:
		_close_settings()
	if _shop_open:
		close_shop()
	if _craft_open:
		close_craft()
	_close_character()
	if _paused:
		_close_pause()
	_skills_open = true
	_enter_held = false
	_skills_l_held = false
	if _skills_panel != null:
		_skills_panel.visible = true
		_skills_panel.open()
	_recompute_ui_blocking()


## One close path for the skills screen, so every sibling modal and Esc leave both the
## flag and the node in the same state.
func _close_skills() -> void:
	if not _skills_open:
		return
	_skills_open = false
	_enter_held = false
	_skills_l_held = false
	if _skills_panel != null:
		_skills_panel.visible = false
	_recompute_ui_blocking()


## The skills screen owns the input while it is open, exactly like the shop and the
## bench: Esc or K closes it (never pausing underneath), the movement actions walk the
## list, E selects a known skill, and L learns the locked one. Enter and L have no
## InputMap action, so both are edge-detected by hand the way Enter is in the
## inventory; the bot drives selection through `interact` alone.
func _process_skills_navigation() -> void:
	if _consume_action(&"pause") or _consume_action(&"skills"):
		_close_skills()
		return
	if _skills_panel != null:
		var delta := 0
		if _consume_action(&"move_up"):
			delta -= 1
		if _consume_action(&"move_down"):
			delta += 1
		if delta != 0:
			_skills_panel.move_selection(delta)
		var enter_now := Input.is_key_pressed(KEY_ENTER)
		var enter_edge := enter_now and not _enter_held
		_enter_held = enter_now
		if _consume_action(&"interact") or enter_edge:
			_skills_panel.activate()
		var l_now := Input.is_key_pressed(KEY_L)
		if l_now and not _skills_l_held:
			_skills_panel.learn_selected()
		_skills_l_held = l_now


func is_skills_open() -> bool:
	return _skills_open


## Screenshot hook: opens the panel showing the current state without learning or
## selecting anything, so the capture reflects whatever the player actually owns.
func open_skills_for_shot() -> void:
	if _skills_open:
		return
	_toggle_skills()


# Read-only views of the skills panel, so a test or a screenshot probe can read the
# list, the detail block and the points line without reaching into the panel's private
# node tree — the same contract `craft_row_texts` gives.

func skills_row_texts() -> PackedStringArray:
	return _skills_panel.row_texts() if _skills_panel != null else PackedStringArray()


func skills_detail_text() -> String:
	return _skills_panel.detail_text() if _skills_panel != null else ""


func skills_points_text() -> String:
	return _skills_panel.points_text() if _skills_panel != null else ""


func skills_selected_id() -> String:
	return _skills_panel.selected_skill_id() if _skills_panel != null else ""


## Parks the skills cursor on one row without simulating keys (test/screenshot).
func skills_select_row(index: int) -> void:
	if _skills_panel != null:
		_skills_panel.select_row(index)


## One line per quick slot: "1: Настой здоровья", empty slots show "—".
func _refresh_quick_slots() -> void:
	if _quick_slot_list == null:
		return
	for child in _quick_slot_list.get_children():
		child.queue_free()
	for index in GameState.QUICK_SLOT_COUNT:
		var item_id := GameState.quick_slot_item(index)
		var shown := ItemDB.display_name(item_id) if item_id != "" else "—"
		_quick_slot_list.add_child(
			_make_text("%d: %s" % [index + 1, shown], Color(0.62, 0.64, 0.6))
		)


func _refresh_quest() -> void:
	var parts: PackedStringArray = []
	for quest_id: String in QuestManager.states.keys():
		var q: Dictionary = QuestManager.get_quest(quest_id)
		var state: String = QuestManager.state_of(quest_id)
		if state == QuestManager.STATE_DONE:
			continue
		var title := String(q.get("title", quest_id))
		if state == QuestManager.STATE_READY:
			parts.append("✔ %s — сдать" % title)
		else:
			parts.append("%s: %d/%d" % [title, QuestManager.progress_of(quest_id), QuestManager.target_count(quest_id)])
	_quest_label.text = "\n".join(parts)


## One compact line for the skill the right mouse button casts. Refreshed on
## selection change and on every mana change (so a cast refreshes it too).
func _refresh_skill() -> void:
	if _skill_label == null:
		return
	var skill := SkillDB.get_skill(GameState.selected_skill)
	if skill.is_empty():
		_skill_label.text = ""
		return
	_skill_label.text = "Умение: %s · %d маны · %s" % [
		String(skill.get("name", GameState.selected_skill)),
		int(skill.get("mana", 0)),
		String(skill.get("school", "")),
	]


func _on_prompt(text: String) -> void:
	if _dialogue_open:
		return
	_prompt_label.text = "" if text == "" else "[E] " + text


func _on_toast(message: String) -> void:
	_toast_label.text = message
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_label.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.6)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)


func _on_dialogue(lines: Array) -> void:
	if lines.is_empty():
		return
	# Legacy single-line dialogue (the quest fallback): it owns no runner, so the
	# navigation branch stays inert and E/Esc simply close it, as before.
	_dialogue_runner = null
	var first: Dictionary = lines[0]
	_dialogue_speaker.text = String(first.get("speaker", ""))
	_dialogue_text.text = String(first.get("text", ""))
	if _dialogue_options != null:
		_dialogue_options.visible = false
		_dialogue_options.text = ""
	if _dialogue_hint != null:
		_dialogue_hint.text = "[E] продолжить"
	_dialogue_panel.visible = true
	_dialogue_open = true
	GameState.ui_blocking = true
	EventBus.interact_prompt.emit("")


func close_dialogue() -> void:
	if not _dialogue_open:
		return
	_dialogue_panel.visible = false
	_dialogue_open = false
	_dialogue_runner = null
	_dialogue_option_index = 0
	_dialogue_lock_input = false
	_dialogue_tab_held = false
	_dialogue_space_held = false
	_recompute_ui_blocking()
	EventBus.dialogue_closed.emit()


## The conversation currently on screen, or null when none is open. A read-only
## view in the same shape as `craft_row_texts()`: a test that drives an NPC's
## interaction needs the runner the NPC actually handed over, because the effects
## of the chosen option land on the live GameState/QuestManager through that
## object. Nothing here renders or advances anything — the caller only reads.
func dialogue_runner() -> DialogueRunner:
	return _dialogue_runner


## Opens a data-driven conversation handed over by an NPC (spec §12.2). Mirrors
## open_shop's contract: the caller owns the runner, the HUD only renders and
## drives it, and every modal it could visually overlap is closed first. The
## opening E press is locked out for one frame so it cannot also advance a node.
func open_dialogue_runner(runner: DialogueRunner) -> void:
	if runner == null:
		return
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _shop_open:
		close_shop()
	if _craft_open:
		close_craft()
	_close_character()
	_close_skills()
	if _paused:
		_close_pause()
	_dialogue_runner = runner
	_dialogue_option_index = 0
	_dialogue_auto_advance = true
	_dialogue_tab_held = false
	_dialogue_space_held = false
	_dialogue_lock_input = true
	_dialogue_open = true
	_dialogue_panel.visible = true
	GameState.ui_blocking = true
	EventBus.interact_prompt.emit("")
	_present_dialogue_node()


## Renders the node the runner is on, fast-skipping plain lines the player has
## already seen while auto-advance is on (spec §12.2). A conversation can chain
## several already-read lines in a row, so this walks them without waiting for
## input; the loop is bounded so a malformed cycle of read nodes can never hang a
## frame — on overflow it simply closes rather than spinning.
func _present_dialogue_node() -> void:
	for _guard in range(64):
		if _dialogue_runner == null or _dialogue_runner.is_finished():
			close_dialogue()
			return
		var node_id := _dialogue_runner.current_node_id()
		var was_read := _dialogue_runner.is_read(node_id)
		_dialogue_runner.mark_read(node_id)
		var node: Dictionary = _dialogue_runner.current_node()
		var options: Array = node.get("options", [])
		if options.is_empty() and _dialogue_auto_advance and was_read:
			_dialogue_runner.skip_remaining()
			if _dialogue_runner.advance() == "":
				close_dialogue()
				return
			continue
		_dialogue_option_index = 0
		_render_dialogue_node()
		return
	close_dialogue()


## Paints the current node: speaker, body, and — when the node offers choices —
## the numbered option list with a cursor on the selected row.
func _render_dialogue_node() -> void:
	if _dialogue_runner == null:
		return
	var node: Dictionary = _dialogue_runner.current_node()
	_dialogue_speaker.text = _dialogue_runner.current_speaker()
	_dialogue_text.text = String(node.get("text", ""))
	var options: Array = node.get("options", [])
	if options.is_empty():
		_dialogue_options.visible = false
		_dialogue_options.text = ""
	else:
		var rows: PackedStringArray = []
		for i in range(options.size()):
			var option: Variant = options[i]
			var label := String((option as Dictionary).get("text", "")) if option is Dictionary else String(option)
			# A cosmetic choice changes nothing in the world — no quest, no flag, no
			# reward — so it is marked as consequence-free right on its row. Without
			# the mark a player reads every option as a commitment and never picks the
			# one that is only there to let him answer in character.
			if option is Dictionary and bool((option as Dictionary).get("cosmetic", false)):
				label += " (без последствий)"
			rows.append("> %d. %s" % [i + 1, label] if i == _dialogue_option_index else "  %d. %s" % [i + 1, label])
		_dialogue_options.text = "\n".join(rows)
		_dialogue_options.visible = true
	_refresh_dialogue_hint(not options.is_empty())


## The exact text currently shown in the option list, for tests and any caller that
## needs to read what the player sees without reaching into the label. Empty when no
## conversation with choices is open.
func dialogue_options_text() -> String:
	return _dialogue_options.text if _dialogue_options != null else ""


## One compact controls line that reflects the live auto-advance state, so the
## Tab toggle is visible without a toast. Kept short and clipped so a 480-wide
## viewport never overflows.
func _refresh_dialogue_hint(has_options: bool) -> void:
	if _dialogue_hint == null:
		return
	var auto := "вкл" if _dialogue_auto_advance else "выкл"
	if has_options:
		_dialogue_hint.text = "[E] выбрать · ↑↓ выбор · Tab авто:%s · Space пропуск" % auto
	else:
		_dialogue_hint.text = "[E] далее · Tab авто:%s · Space пропуск" % auto


## The conversation owns the input while it is open, exactly like the shop and
## the craft bench: Esc closes it (never pausing underneath), the movement actions
## walk the option list, E confirms the choice or advances the line, Space
## fast-forwards, and Tab toggles auto-advance of already-read lines. Every other
## key is swallowed, so a conversation cannot be overlaid by another modal.
## Tab and Space have no InputMap action, so both are edge-detected by hand the
## way Enter is in the inventory; the bot drives the conversation through E alone.
func _process_dialogue_navigation() -> void:
	if _dialogue_lock_input:
		_dialogue_lock_input = false
		return
	if _consume_action(&"pause"):
		close_dialogue()
		return
	var tab_now := Input.is_key_pressed(KEY_TAB)
	if tab_now and not _dialogue_tab_held:
		_dialogue_auto_advance = not _dialogue_auto_advance
		_refresh_dialogue_hint(not _dialogue_runner.current_options().is_empty())
	_dialogue_tab_held = tab_now
	var options := _dialogue_runner.current_options()
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 1
	if _consume_action(&"move_down"):
		delta += 1
	if delta != 0 and not options.is_empty():
		_dialogue_option_index = clampi(_dialogue_option_index + delta, 0, options.size() - 1)
		_render_dialogue_node()
	var space_now := Input.is_key_pressed(KEY_SPACE)
	var space_edge := space_now and not _dialogue_space_held
	_dialogue_space_held = space_now
	if _consume_action(&"interact") or space_edge:
		_advance_dialogue()


## E / Space on the current node: pick the highlighted option when the node offers
## choices, otherwise advance the plain line. When the runner reports the end of
## the conversation the panel closes and input is handed back to the world.
func _advance_dialogue() -> void:
	if _dialogue_runner == null:
		return
	var options := _dialogue_runner.current_options()
	if options.is_empty():
		if _dialogue_runner.advance() == "":
			close_dialogue()
			return
		_present_dialogue_node()
		return
	var result: Dictionary = _dialogue_runner.choose(_dialogue_option_index)
	if not bool(result.get("ok", false)):
		return
	if _dialogue_runner.is_finished():
		close_dialogue()
		return
	_present_dialogue_node()


func _toggle_inventory() -> void:
	_inventory_open = not _inventory_open
	if _inventory_open:
		_journal_open = false
		_journal_panel.visible = false
		# The character screen is a sibling modal: it must not stay open under
		# the inventory (only while unpaused, so the pause-menu E can still reach
		# the settings screen).
		if not _paused:
			_close_character()
		_inventory_selection = 0
		_inventory_scroll = 0
		_enter_held = false
		_refresh_inventory()
		_center_inventory_panel.call_deferred()
	else:
		_enter_held = false
	_inventory_panel.visible = _inventory_open
	_recompute_ui_blocking()


func _toggle_journal() -> void:
	_journal_open = not _journal_open
	if _journal_open:
		_inventory_open = false
		_inventory_panel.visible = false
		if not _paused:
			_close_character()
		_refresh_journal()
	_journal_panel.visible = _journal_open
	_recompute_ui_blocking()


func _refresh_journal() -> void:
	if _journal_list == null:
		return
	for child in _journal_list.get_children():
		child.queue_free()
	# Rebuilt from scratch every open, so the snapshot the tests and any reader use
	# is reset here rather than left holding last open's lines.
	_journal_snapshot = ""
	var shown := 0
	for quest_id: String in QuestManager.quests.keys():
		var q: Variant = QuestManager.quests[quest_id]
		if not (q is Dictionary):
			continue
		var title := String((q as Dictionary).get("title", quest_id))
		var state: String = QuestManager.state_of(quest_id)
		if state == QuestManager.STATE_ACTIVE:
			var line := "• %s — %d/%d" % [title, QuestManager.progress_of(quest_id), QuestManager.target_count(quest_id)]
			_journal_add(line, Color(0.9, 0.92, 0.86))
			shown += 1
		elif state == QuestManager.STATE_READY:
			_journal_add("✔ %s — сдать" % title, Color(0.96, 0.86, 0.5))
			shown += 1
		elif state == QuestManager.STATE_DONE:
			_journal_add("✓ %s — выполнено" % title, Color(0.55, 0.57, 0.55))
			shown += 1
	# The pilgrim's fragments are not a quest, so the loop above can never show them —
	# yet they are the one thread of the main story the player pieces together himself,
	# and a fragment heard and then nowhere written down is a clue lost to the run. They
	# get their own block: how many of the four he has sat through and where, and whether
	# the last one has told him the truth about the king. It appears only once there is
	# something to report, so a player who has never met the stranger sees no empty
	# heading hinting at content he has not unlocked.
	var heard: Array[String] = []
	for zone_place in [["forest", "в лесу"], ["ruins", "в руинах"], ["dungeon", "в подземелье"], ["fortress", "в крепости"]]:
		if GameState.get_flag("pilgrim_met_" + String(zone_place[0]), false):
			heard.append(String(zone_place[1]))
	var truth_known: bool = GameState.get_flag("pilgrim_truth_known", false)
	if not heard.is_empty() or truth_known:
		_journal_add("— Паломник —", Color(0.72, 0.66, 0.5))
		if not heard.is_empty():
			_journal_add("Услышано %d из 4: %s" % [heard.size(), ", ".join(heard)], Color(0.82, 0.8, 0.72))
		if truth_known:
			_journal_add("Правда о короле открыта", Color(0.9, 0.82, 0.6))
	if shown == 0 and heard.is_empty() and not truth_known:
		_journal_add("пока пусто", Color(0.6, 0.6, 0.58))


## Adds one journal row and records its text in the snapshot, so the visible list and
## the string `get_journal_text()` returns can never drift apart.
func _journal_add(text: String, color: Color) -> void:
	_journal_list.add_child(_make_text(text, color))
	_journal_snapshot += text + "\n"


## The plain text of the journal as last built, one line per row. For tests and any
## caller that needs to read the journal without walking the label nodes (the old rows
## are freed on a deferred frame, so reading the children right after a rebuild would
## still see the previous open's lines).
func get_journal_text() -> String:
	return _journal_snapshot


func _toggle_pause() -> void:
	_paused = not _paused
	_menu_key_held = false
	_pause_panel.visible = _paused
	get_tree().paused = _paused
	_recompute_ui_blocking()
	EventBus.game_paused.emit(_paused)


## Leaving the pause menu without opening it again: used when another modal takes
## over the screen (the pause menu itself offers "C — Персонаж").
func _close_pause() -> void:
	if not _paused:
		return
	_paused = false
	_menu_key_held = false
	_pause_panel.visible = false
	get_tree().paused = false
	EventBus.game_paused.emit(false)


## Edge latch for the HUD's polled actions (defect A). `_input` is the first hook in
## the frame and runs for every event regardless of how many physics steps get packed
## into one idle frame, so it is the only place a press can be caught before the
## engine's one-frame `just_pressed` window closes. It observes without consuming: it
## never calls `set_input_as_handled`, so the player, the GUI and the settings panel
## still receive every event exactly as before. The debug bot installs an `InputSource`
## override instead of pushing real events, so its presses never reach here; they are
## read straight from the override in `_consume_action`, leaving bot behaviour
## identical. Key echo (auto-repeat) is ignored so holding a panel key is one press,
## matching the engine's own `just_pressed`.
func _input(event: InputEvent) -> void:
	var pressed := false
	var echo := false
	if event is InputEventKey:
		var key := event as InputEventKey
		pressed = key.pressed
		echo = key.is_echo()
	elif event is InputEventMouseButton:
		pressed = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		pressed = (event as InputEventJoypadButton).pressed
	elif event is InputEventAction:
		var act := event as InputEventAction
		pressed = act.is_pressed()
		echo = act.is_echo()
	else:
		return
	if not pressed or echo:
		return
	for action in POLLED_ACTIONS:
		if event.is_action_pressed(action):
			_pending_input[action] = true


## Consume one press of `action` for this `_process` frame. While the debug bot owns
## input it answers from the override (which serves each edge once per physics tick),
## so the bot path is byte-for-byte the old engine `just_pressed`. For
## a human it consumes the latch `_input` captured, clearing it so one press is one
## action and never repeats.
func _consume_action(action: StringName) -> bool:
	if InputSource.has_override():
		return InputSource.is_action_just_pressed(action)
	if bool(_active_input.get(action, false)):
		_active_input[action] = false
		return true
	return false


## Read a latched press without consuming it. Used only by the settings-just-closed
## guard, which must leave the Esc edge for the branch that owns it rather than eat it.
func _peek_action(action: StringName) -> bool:
	if InputSource.has_override():
		return InputSource.is_action_just_pressed(action)
	return bool(_active_input.get(action, false))


## UI polls the same InputSource the player uses, so a human and the debug bot
## drive menus through one code path. Real InputEvents would be invisible to the
## bot, which is exactly the privileged/unequal access the spec forbids.
func _process(_delta: float) -> void:
	# Snapshot the edges `_input` captured since the last frame and start the next
	# frame's latch empty. Anything a modal swallows this frame is dropped here on the
	# following snapshot, so a latch lives exactly as long as the one-frame engine edge
	# it replaces and never leaks into a later frame.
	_active_input = _pending_input
	_pending_input = {}
	# The clock line refreshes on its own one-second cadence, ahead of every
	# modal early-return below, so it stays readable over the map, shop and bench.
	_tick_clock(_delta)
	# The boss bar is polled here for the same reason the clock is: a fight does
	# not stop because a panel is open, and the bar must not freeze mid-swing
	# behind the map or the shop.
	_tick_boss_bar(_delta)
	# The defeat and victory screens own the screen the way a modal does, and ahead
	# of every other branch: both pause the tree, and the HUD polls with
	# PROCESS_MODE_ALWAYS, so this is the only code that runs while the world is
	# held still. Nothing else may answer the keys underneath them.
	if _defeat_open:
		_process_defeat_navigation()
		return
	if _victory_open:
		_process_victory_navigation()
		return
	# The ending-choice panel owns the screen the way a modal does, ahead of every
	# gameplay and panel branch below, so ↑↓/E/Esc reach only it and no other screen can
	# stack over the throne. It does not pause the world (only blocks input), so unlike
	# victory it sits here rather than beside the two screens that freeze the tree.
	if _ending_choice_open:
		_process_ending_choice_navigation()
		return
	# The settings screen captures raw events itself; while it is open no
	# action polling may reach the gameplay paths below.
	if _settings_open:
		return
	# The very Esc edge that closed the settings screen must not also unpause
	# the game in the same frame: it belongs to the settings screen alone.
	if _settings_just_closed:
		_settings_just_closed = false
		if _peek_action(&"pause"):
			return
	if _map_open:
		if _consume_action(&"pause") or _consume_action(&"map"):
			_close_map()
			return
		if _map_panel != null:
			_map_panel.refresh()
		return
	# The shop owns the input while it is open, exactly like the map: Esc closes it
	# (never pauses underneath), Tab flips buy/sell, the movement actions walk the
	# list and E trades one unit. Tab has no InputMap action, so it is edge-detected
	# by hand the way Enter is in the inventory; the bot never presses Tab, so it
	# stays on the buy list and can never reach a sell it was not meant to do.
	if _shop_open:
		if _consume_action(&"pause"):
			close_shop()
			return
		if _shop_panel != null:
			var tab_now := Input.is_key_pressed(KEY_TAB)
			if tab_now and not _tab_held:
				_shop_panel.toggle_mode()
			_tab_held = tab_now
			var shop_delta := 0
			if _consume_action(&"move_up"):
				shop_delta -= 1
			if _consume_action(&"move_down"):
				shop_delta += 1
			if shop_delta != 0:
				_shop_panel.move_selection(shop_delta)
			if _consume_action(&"interact"):
				_shop_panel.activate()
		return
	# The craft bench owns the input while it is open, exactly like the shop: Esc
	# closes it (never pausing the game underneath), the movement actions walk the
	# recipe list and E crafts one item. Every other key is swallowed, so a player
	# at the forge cannot open the inventory or the map over the bench, and the
	# panel — not the HUD — decides what E is worth through the CraftManager.
	if _craft_open:
		if _consume_action(&"pause"):
			close_craft()
			return
		if _craft_panel != null:
			var craft_delta := 0
			if _consume_action(&"move_up"):
				craft_delta -= 1
			if _consume_action(&"move_down"):
				craft_delta += 1
			if craft_delta != 0:
				_craft_panel.move_selection(craft_delta)
			if _consume_action(&"interact"):
				_craft_panel.activate()
		return
	# A data-driven conversation owns the input while it is open, ahead of every
	# gameplay and modal branch below, so Esc/E/↑↓/Tab/Space reach only it. The
	# legacy one-line dialogue leaves the runner null and falls through to the
	# close-on-E path further down, exactly as before.
	if _dialogue_open and _dialogue_runner != null:
		_process_dialogue_navigation()
		return
	# Esc belongs to the character screen while it is open: it closes the panel
	# instead of pausing the game underneath.
	if _character_open:
		if _consume_action(&"pause"):
			_toggle_character()
			return
	# The skills screen owns the input while it is open, exactly like the shop and
	# the bench: Esc or K closes it (never pausing underneath), the movement actions
	# walk the list, E selects, L learns. Every other key is swallowed, so a player
	# in the skills screen cannot open the inventory or the map over it.
	if _skills_open:
		_process_skills_navigation()
		return
	if _consume_action(&"map"):
		_open_map()
		return
	if _consume_action(&"pause"):
		if _dialogue_open:
			close_dialogue()
		elif _journal_open:
			_toggle_journal()
		else:
			_toggle_pause()
		return
	if _consume_action(&"character"):
		_toggle_character()
		return
	# K opens the skills screen. It sits here, alongside the other panel keys and
	# ahead of the pause block, so the pause menu's advertised "K — Навыки" works.
	# It is refused while the inventory, journal or a dialogue owns the screen (the
	# map, shop, bench and settings already returned above), so K never stacks a
	# second modal over one that is open.
	if _consume_action(&"skills"):
		if not _inventory_open and not _journal_open and not _dialogue_open:
			_toggle_skills()
		return
	if _paused:
		# Q leaves to the menu. It owns no InputMap action, so it is edge-detected by
		# hand like Enter and Tab; the bot never pauses, so it can never reach it.
		var menu_key_now := Input.is_key_pressed(KEY_Q)
		var menu_key_edge := menu_key_now and not _menu_key_held
		_menu_key_held = menu_key_now
		if menu_key_edge:
			return_to_menu()
			return
		if _consume_action(&"interact"):
			_open_settings()
		return
	if _consume_action(&"journal"):
		_toggle_journal()
		return
	if _consume_action(&"inventory"):
		_toggle_inventory()
		return
	if _inventory_open:
		_process_inventory_navigation()
		return
	if _character_open:
		_process_character_navigation()
		return
	if _consume_action(&"interact") and _dialogue_open:
		close_dialogue()
		return
	if _dialogue_open or _inventory_open or _journal_open:
		return
	for index in QUICK_SLOT_ACTIONS.size():
		var action: StringName = QUICK_SLOT_ACTIONS[index]
		if _consume_action(action):
			_use_quick_slot(index)
			return
	if _consume_action(&"save_game"):
		var res: Dictionary = SaveManager.save_game(1)
		EventBus.toast.emit("Сохранено" if bool(res.get("ok", false)) else "Ошибка сохранения")
		return
	if _consume_action(&"load_game"):
		# Travel first, load second. `load_game` hands the saved position to the
		# player standing in the tree at that moment, and travelling afterwards
		# would free that player along with the zone it lives in, dropping the run
		# on the new zone's entry tile instead of where the save left the player.
		# Going the other way round, the position lands on a player that already
		# belongs to the saved zone. `travel` refuses the zone already stood in, so
		# a same-zone load costs nothing.
		var saved_zone := SaveManager.slot_zone(1)
		var zone_manager := get_tree().get_first_node_in_group(ZoneManager.GROUP)
		if saved_zone != "" and zone_manager != null and zone_manager.has_method("travel"):
			zone_manager.call("travel", saved_zone)
		var res2: Dictionary = SaveManager.load_game(1)
		EventBus.toast.emit("Загружено" if bool(res2.get("ok", false)) else "Слот пуст")
		_refresh_all()


func open_inventory_for_shot() -> void:
	_inventory_open = true
	_inventory_selection = 0
	_inventory_scroll = 0
	_enter_held = false
	_inventory_panel.visible = true
	_refresh_inventory()
	_center_inventory_panel.call_deferred()


## Re-centres the inventory panel horizontally from its laid-out width. The panel is
## anchored to the viewport centre, but `position` on an anchored Control is the
## absolute left in the parent, not an offset from the anchor — so centring a panel of
## width W in a viewport of width Vp is `(Vp - W) / 2`, never `-W / 2`. (The build-time
## `-84` only looks centred because it is authored while `_root` is still zero-sized and
## then anchor-resizes into place; re-deriving here, after the container has sized the
## panel to its rows, is what keeps it centred when a long item name grows it past the
## 168 px minimum — CRITIC-P2-13.) Vertical placement is left as authored to match the
## rest of the centred-panel family; only the horizontal off-centre is corrected.
func _center_inventory_panel() -> void:
	if _inventory_panel == null or not _inventory_panel.visible:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var vp := viewport.get_visible_rect().size
	if vp == Vector2.ZERO or _inventory_panel.size.x <= 0.0:
		return
	_inventory_panel.position.x = (vp.x - _inventory_panel.size.x) * 0.5


func is_journal_open() -> bool:
	return _journal_open


func open_journal_for_shot() -> void:
	_journal_open = true
	_journal_panel.visible = true
	_refresh_journal()


func _open_map() -> void:
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _craft_open:
		close_craft()
	_close_character()
	_close_skills()
	_map_open = true
	if _map_panel != null:
		_map_panel.visible = true
		_map_panel.refresh()
	GameState.ui_blocking = true


func _close_map() -> void:
	_map_open = false
	if _map_panel != null:
		_map_panel.visible = false
	_recompute_ui_blocking()


func is_map_open() -> bool:
	return _map_open


func open_map_for_shot() -> void:
	_open_map()


## Settings replaces the pause panel visually; the game stays paused underneath.
## Only reachable from the pause panel, and the bot never pauses, so it can
## never open this screen.
func _open_settings() -> void:
	_settings_open = true
	_pause_panel.visible = false
	_settings_panel.visible = true
	_settings_panel.open()
	GameState.ui_blocking = true


func _close_settings() -> void:
	_settings_open = false
	_settings_just_closed = true
	_settings_panel.visible = false
	_pause_panel.visible = _paused
	_recompute_ui_blocking()


func is_settings_open() -> bool:
	return _settings_open


func open_settings_for_shot() -> void:
	_open_settings()


## Quick slot index is 0-based; the toast shows the 1-based key number.
func _use_quick_slot(index: int) -> void:
	var item_id := GameState.quick_slot_item(index)
	if item_id == "":
		EventBus.toast.emit("Слот %d пуст" % (index + 1))
		return
	_use_item(item_id)


func _use_item(item_id: String) -> void:
	if GameState.count_item(item_id) <= 0:
		EventBus.toast.emit("Нет предмета")
		return
	var def := ItemDB.get_item(item_id)
	if GameState.remove_item(item_id, 1):
		if def.has("heal"):
			_heal_player(int(def["heal"]))
		if def.has("mana"):
			GameState.restore_mana(int(def["mana"]))
		EventBus.toast.emit("Использовано: %s" % String(def.get("name", item_id)))
		_refresh_inventory()


## Healing goes through the player so a BLIGHT status can halve the amount
## without the HUD knowing about statuses. Falls back to GameState when no
## player is in the tree (e.g. a menu-only scene).
func _heal_player(amount: int) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("heal_with_status"):
		player.call("heal_with_status", amount)
	else:
		GameState.heal(amount)


## Refreshes the compact day-clock line at most once a second (spec §12.1). The
## clock node is found through the `day_clock` group rather than a node path, and
## a missing clock (a menu-only scene with no world) simply leaves the line blank.
## The HUD runs with PROCESS_MODE_ALWAYS, but the clock fraction itself is frozen
## while paused or UI-blocked, so the displayed time never ages off-screen.
func _tick_clock(delta: float) -> void:
	if _clock_label == null:
		return
	_clock_refresh_left -= delta
	if _clock_refresh_left > 0.0:
		return
	_clock_refresh_left = 1.0
	refresh_clock_line()


## Rebuilds the day-clock line from the current clock state. Split out from the
## one-second throttle in `_tick_clock` so a test or a screenshot probe can force
## an immediate, deterministic refresh.
func refresh_clock_line() -> void:
	if _clock_label == null:
		return
	if _day_clock == null or not is_instance_valid(_day_clock):
		_day_clock = get_tree().get_first_node_in_group("day_clock")
	if _day_clock == null:
		_clock_label.text = ""
		return
	var phase := String(_day_clock.call("phase"))
	var fraction := float(_day_clock.get("time_fraction"))
	# The in-game day starts at dawn, not midnight: fraction 0.0 is 06:00, so the
	# phase labels land on the hours a player expects (morning 06:00, day 12:00,
	# evening 19:12, night 01:12). The +6h offset is display-only; the schedule
	# data and the phase logic still key off the raw fraction.
	var display_hours := fmod(6.0 + fmod(fraction, 1.0) * 24.0, 24.0)
	var total_minutes := roundi(display_hours * 60.0) % 1440
	var hour := int(total_minutes / 60.0)
	var minute := total_minutes % 60
	var label := String(PHASE_LABELS_RU.get(phase, phase))
	_clock_label.text = "%s · %02d:%02d" % [label, hour, minute]


## Read-only view of the day-clock line, so a test or a screenshot probe can read
## what the player sees without reaching into the HUD's private node tree.
func clock_line_text() -> String:
	return _clock_label.text if _clock_label != null else ""


## Repaints the boss bar from the live boss, or hides it. Polled rather than
## signal-driven on purpose: the bar has to disappear the moment the player walks
## out of range as well as the moment the boss dies, and only a distance check
## covers both without a signal for every way a fight can end.
func _tick_boss_bar(_delta: float) -> void:
	if _boss_panel == null or _boss_bar == null or _boss_label == null:
		return
	var player := get_tree().get_first_node_in_group("player") as Node2D
	var boss := _resolve_boss(player)
	# Music follows the same engagement the bar does: boss music while a boss is
	# stood up to, the zone's own track the moment the fight ends or the player
	# walks out of range. Done here rather than on a signal because only this
	# per-frame resolve sees every way a fight can end (death, walk-away, travel).
	_sync_boss_music(boss)
	if boss == null:
		_boss_panel.visible = false
		return
	var pool := boss.get_node_or_null("HealthComponent")
	if pool == null:
		_boss = null
		_boss_panel.visible = false
		return
	var maximum := maxi(1, int(pool.get("max_health")))
	_boss_bar.max_value = maximum
	_boss_bar.value = clampi(int(pool.get("current_health")), 0, maximum)
	var phase := int(boss.call("current_phase")) if boss.has_method("current_phase") else 1
	_boss_label.text = "%s  %d/%d  ·  Фаза %d" % [
		String(boss.get("display_name")),
		int(pool.get("current_health")),
		maximum,
		phase,
	]
	_boss_panel.visible = true


## The boss whose bar this is: the nearest LIVING boss within the engage radius of the
## player. A zone can now hold more than one boss (the forest keeps both the warden and
## the Root Mother), so the bar has to follow whichever boss the player actually stands
## up to rather than whichever node the group happens to return first. A boss outside
## the radius, or a corpse still fading out, is not a candidate; with none in range the
## bar is off screen. Re-resolved every frame, which is what lets the bar hand over from
## one boss to the next as the player walks between them, and what keeps the warden's
## bar from being shadowed by a second boss standing across the map.
func _resolve_boss(player: Node2D) -> Node:
	_boss = null
	if player == null:
		return null
	var nearest: Node = null
	var best := INF
	for node in get_tree().get_nodes_in_group(BOSS_GROUP):
		if node == null or not is_instance_valid(node):
			continue
		if _boss_is_dead(node):
			continue
		var body := node as Node2D
		if body == null:
			continue
		var distance := player.global_position.distance_to(body.global_position)
		if distance <= BOSS_ENGAGE_RADIUS and distance < best:
			best = distance
			nearest = node
	_boss = nearest
	return nearest


## Dead answer for the bar. Read through the pool and the owner rather than
## through a class, so the HUD compiles without the AI scripts: a boss that is
## dying still owns a fading corpse for ~0.45 s, and a bar over a corpse reads as
## a fight that never ended.
func _boss_is_dead(boss: Node) -> bool:
	var pool := boss.get_node_or_null("HealthComponent")
	if pool != null and bool(pool.get("is_dead")):
		return true
	return boss.has_method("is_status_owner_dead") and bool(boss.call("is_status_owner_dead"))


# --- music routing (spec §17) --------------------------------------------------

## The audio autoload, resolved at runtime rather than as a compile-time
## identifier (the same rule `settings_panel.gd` follows): the HUD must not name
## `AudioManager` in its compile graph, and a missing audio layer is a no-op.
func _audio_manager() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("AudioManager")


## The live zone's own track, read through the world node's `music_track` hook so
## the HUD never hardcodes which zone plays what.
func _zone_music_track() -> String:
	if _world != null and is_instance_valid(_world) and _world.has_method("music_track"):
		return String(_world.call("music_track"))
	return ""


## Switches to boss music when a boss is engaged and back to the zone track when
## the fight ends, on edges only. Silent while a death or ending screen is open:
## those screens own the audio (the sting is separate), and the bar keeps polling
## underneath them without fighting that decision.
func _sync_boss_music(boss: Node) -> void:
	if _defeat_open or _victory_open:
		return
	var audio := _audio_manager()
	if audio == null or not audio.has_method("play_music"):
		return
	if boss != null:
		if not _music_boss_engaged:
			_music_boss_engaged = true
			audio.call("play_music", "music_boss")
	elif _music_boss_engaged:
		_music_boss_engaged = false
		var track := _zone_music_track()
		if track != "":
			audio.call("play_music", track)
		elif audio.has_method("stop_music"):
			audio.call("stop_music")


## Brings the zone's own track back after a death (respawn). Clears the boss
## intent first so a boss still standing re-engages cleanly on the next poll.
func _restore_zone_music() -> void:
	_music_boss_engaged = false
	var audio := _audio_manager()
	if audio == null or not audio.has_method("play_music"):
		return
	var track := _zone_music_track()
	if track != "":
		audio.call("play_music", track)


# Read-only views of the boss bar, so a test or a screenshot probe can tell
# whether the bar is on screen, what it says and where it sits without reaching
# into the HUD's private node tree — the same contract `clock_line_text` gives.
# The rects are empty while the corresponding control is hidden, which is what
# lets an overlap check compare only the controls that are actually drawn.

func boss_bar_visible() -> bool:
	return _boss_panel != null and _boss_panel.visible


func boss_bar_text() -> String:
	return _boss_label.text if _boss_label != null else ""


func boss_bar_global_rect() -> Rect2:
	if _boss_panel == null or not _boss_panel.visible:
		return Rect2()
	return _boss_panel.get_global_rect()


func player_hp_bar_global_rect() -> Rect2:
	return _hp_bar.get_global_rect() if _hp_bar != null else Rect2()


func clock_label_global_rect() -> Rect2:
	return _clock_label.get_global_rect() if _clock_label != null else Rect2()


# --- defeat screen (spec §16.1) ------------------------------------------------

## Opens the defeat screen over a world that keeps running.
##
## Deliberately not a pause. The player already owns death: `_on_player_died` starts
## the death animation and the `_dead_timer` that ends it, and `BOT-010` proves the
## run is expected to survive a death and carry on. Freezing the tree here would put
## a second owner on that timer — the screen would hold the world until someone
## answers it, and anything that cannot answer it (a soak bot, a scripted revive)
## would stay dead forever instead of respawning. So the screen only covers the
## window the player is already unusable in, and it needs no `ui_blocking` of its
## own: a player in `State.DEAD` reads no input at all, and this screen takes the
## HUD's own `_process` before any panel branch can open over it. Setting the flag
## here would have stopped the day clock and every NPC schedule for the length of the
## death animation, which is a change to the world, not to the screen. «Возродиться»
## is then exactly what the spec asks for and nothing more — it steps out of the way
## and lets the player's own timer fire his own `_respawn()`. One respawn path, in one
## file, as before.
func _open_defeat() -> void:
	if _defeat_open:
		return
	# Every modal the defeat panel could visually sit on top of goes first, the same
	# way the shop and the bench clear the screen: a dialogue left open under «Вы
	# погибли» would keep its own input branch alive behind a paused world.
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _shop_open:
		close_shop()
	if _craft_open:
		close_craft()
	_close_character()
	_close_skills()
	_close_ending_choice()
	if _settings_open:
		_close_settings()
	_close_pause()
	_defeat_open = true
	_defeat_selected = 0
	_enter_held = false
	_refresh_defeat()
	_defeat_panel.visible = true
	# Death is silent: the music and the ambience bed stop here, and the only cue
	# the player hears is the `hurt` that `_on_player_died` already plays at 0.6
	# pitch — no second death sound is added. The boss intent is cleared so a
	# respawn resumes the zone track rather than staying stuck on boss music.
	_music_boss_engaged = false
	var audio := _audio_manager()
	if audio != null:
		if audio.has_method("stop_music"):
			audio.call("stop_music")
		if audio.has_method("stop_ambience"):
			audio.call("stop_ambience")
	Telemetry.event(&"defeat_shown", {"hp": GameState.hp})


## Leaves the defeat screen without deciding anything: the player's death timer
## completes on its own, and the existing respawn puts him back on his spawn point.
## Called both by «Возродиться» and by `player_respawned`, so a revive from anywhere
## else can never leave the screen hanging over a live player.
func _close_defeat() -> void:
	if not _defeat_open:
		return
	_defeat_open = false
	_defeat_panel.visible = false
	_enter_held = false
	# The run carries on, so the world's own bed comes back. A boss still stood up
	# to re-engages boss music on the next boss-bar poll.
	_restore_zone_music()


func _refresh_defeat() -> void:
	for i in _defeat_rows.size():
		var is_on := i == _defeat_selected
		_defeat_rows[i].text = "%s %s" % ["> " if is_on else "  ", String(DEFEAT_OPTIONS[i])]
		_defeat_rows[i].add_theme_color_override(
			"font_color", Color(1.0, 0.97, 0.62) if is_on else COLOR_ROW)


func _process_defeat_navigation() -> void:
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 1
	if _consume_action(&"move_down"):
		delta += 1
	if delta != 0:
		_defeat_selected = clampi(_defeat_selected + delta, 0, DEFEAT_OPTIONS.size() - 1)
		_refresh_defeat()
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if _consume_action(&"interact") or enter_edge:
		if _defeat_selected == 0:
			_close_defeat()
		else:
			return_to_menu()


## Hands the run back to the main menu. Every flag this file owns is cleared on the
## way out and the tree is unpaused before the scene changes: a new scene whose
## nodes inherit the pause process mode would arrive frozen, with no HUD left in the
## tree to thaw it.
func return_to_menu() -> void:
	_close_defeat()
	close_victory()
	_close_pause()
	_close_skills()
	_close_ending_choice()
	GameState.ui_blocking = false
	var loop := get_tree()
	loop.paused = false
	loop.change_scene_to_file(MENU_SCENE)


# --- victory screen (spec §16.1) -----------------------------------------------

## The ending screen. Public because the final boss that has not been built yet is
## what will call it; nothing in the world does today. `ending_id` is one of
## `dawn`, `memory`, `crown`; anything else is shown verbatim rather than blanked.
func show_victory(ending_id: String) -> void:
	if _victory_box == null:
		return
	_victory_title.text = "Финал: %s" % String(ENDING_NAMES_RU.get(ending_id, ending_id))
	for child in _victory_box.get_children():
		_victory_box.remove_child(child)
		child.queue_free()
	for line in MainMenu.credits_lines():
		var label := _make_text(String(line), Color(0.88, 0.9, 0.85))
		label.custom_minimum_size = Vector2(296, 10)
		_victory_box.add_child(label)
	_victory_open = true
	_enter_held = false
	_victory_panel.visible = true
	# The scroll box is laid out on the next frame, so the reset has to wait for it
	# too; otherwise a second `show_victory()` would start where the last one left
	# off because there was no scroll range to clamp against yet.
	_reset_victory_scroll.call_deferred()
	GameState.ui_blocking = true
	get_tree().paused = true
	# The ending replaces the world's bed with a single rising sting: stop the
	# music and the ambience, then play `sting_victory` once on the SFX bus (the
	# one-shot pool — never the music pair, which the crossfade owns).
	_music_boss_engaged = false
	var audio := _audio_manager()
	if audio != null:
		if audio.has_method("stop_music"):
			audio.call("stop_music")
		if audio.has_method("stop_ambience"):
			audio.call("stop_ambience")
		if audio.has_method("play_sfx"):
			audio.call("play_sfx", "sting_victory", "SFX", 0.0)
	Telemetry.event(&"victory_shown", {"ending": ending_id})


func _reset_victory_scroll() -> void:
	if _victory_scroll != null:
		_victory_scroll.scroll_vertical = 0


func close_victory() -> void:
	if not _victory_open:
		return
	_victory_open = false
	_victory_panel.visible = false
	_enter_held = false
	GameState.ui_blocking = false
	get_tree().paused = false


func _process_victory_navigation() -> void:
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 15
	if _consume_action(&"move_down"):
		delta += 15
	if delta != 0 and _victory_scroll != null:
		_victory_scroll.scroll_vertical = \
				maxi(0, int(_victory_scroll.scroll_vertical) + delta)
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if _consume_action(&"interact") or enter_edge \
			or _consume_action(&"pause"):
		# The ending is terminal: there is no world to step back into, so the confirm
		# key leaves the run rather than merely hiding the panel. `return_to_menu`
		# closes the victory screen (clearing `ui_blocking` and the pause) on its way
		# out, so the flag and the tree are left in the same clean state either way.
		return_to_menu()


# --- read-only views of the two screens ---------------------------------------

func is_defeat_open() -> bool:
	return _defeat_open


func defeat_row_texts() -> Array[String]:
	var out: Array[String] = []
	for row in _defeat_rows:
		out.append(row.text)
	return out


func select_defeat_row(index: int) -> void:
	if not _defeat_open:
		return
	_defeat_selected = clampi(index, 0, DEFEAT_OPTIONS.size() - 1)
	_refresh_defeat()


func is_victory_open() -> bool:
	return _victory_open


func victory_title_text() -> String:
	return _victory_title.text if _victory_title != null else ""


func victory_text() -> String:
	if _victory_box == null:
		return ""
	var parts: PackedStringArray = []
	for child in _victory_box.get_children():
		if child is Label:
			parts.append((child as Label).text)
	return "\n".join(parts)


## The line under the credits that names the way off the ending screen. Exposed so a
## test can prove the victory panel offers the route back to the menu without driving
## a real scene change.
func victory_hint_text() -> String:
	return _victory_hint.text if _victory_hint != null else ""


# --- ending-choice panel (spec §16.1, the reachable ending) ---------------------

## Opens the three-fate choice over the world. Called by `EndingAltar.interact()` when
## the player presses E at the throne after the King has fallen. Mirrors `open_shop`'s
## contract: the caller (the altar) owns the truth about which fates are unlocked and
## what committing one means; this panel only renders that truth and routes the confirm
## back through `EndingAltar.choose()`, so the gate stays in one place. Every modal it
## could visually overlap is cleared first, then it takes the screen and blocks input.
## The opening E press is locked out for one frame so it cannot also confirm a fate.
func open_ending_choice(altar: Node) -> void:
	if altar == null:
		return
	if _dialogue_open:
		close_dialogue()
	if _inventory_open:
		_toggle_inventory()
	if _journal_open:
		_toggle_journal()
	if _map_open:
		_close_map()
	if _shop_open:
		close_shop()
	if _craft_open:
		close_craft()
	_close_character()
	_close_skills()
	if _paused:
		_close_pause()
	_ending_altar = altar
	_ending_choice_selected = 0
	_ending_choice_lock_input = true
	_enter_held = false
	_ending_choice_open = true
	_refresh_ending_choice()
	_ending_choice_panel.visible = true
	GameState.ui_blocking = true


## Leaves the choice screen without committing anything (Esc, or a sibling taking over).
## Routes through `_recompute_ui_blocking` so the block clears exactly when no other
## modal is left open.
func _close_ending_choice() -> void:
	if not _ending_choice_open:
		return
	_ending_choice_open = false
	_ending_choice_lock_input = false
	_ending_altar = null
	_enter_held = false
	if _ending_choice_panel != null:
		_ending_choice_panel.visible = false
	_recompute_ui_blocking()


## Repaints the three fate rows from the altar: name + доступ/закрыт marker on the first
## line, the one-line description (available) or the lock reason (locked) on the second.
## Availability is read live from `EndingAltar.ending_is_available`, never cached here.
func _refresh_ending_choice() -> void:
	if _ending_altar == null or not is_instance_valid(_ending_altar):
		return
	var ids: Array = _ending_altar.call("ending_ids")
	for i in _ending_choice_rows.size():
		var row := _ending_choice_rows[i]
		var desc := _ending_choice_descs[i]
		if i >= ids.size():
			row.text = ""
			desc.text = ""
			continue
		var id := String(ids[i])
		var available := bool(_ending_altar.call("ending_is_available", id))
		var cursor := "> " if i == _ending_choice_selected else "  "
		var name_ru := String(ENDING_NAMES_RU.get(id, id))
		row.text = "%s%s — %s" % [cursor, name_ru, "доступно" if available else "закрыто"]
		if i == _ending_choice_selected:
			row.add_theme_color_override("font_color", Color(1.0, 0.97, 0.62))
		else:
			row.add_theme_color_override("font_color", COLOR_ROW if available else COLOR_WARNING)
		if available:
			desc.text = String(_ending_altar.call("ending_description", id))
			desc.add_theme_color_override("font_color", Color(0.7, 0.78, 0.66))
		else:
			desc.text = String(_ending_altar.call("ending_lock_reason", id))
			desc.add_theme_color_override("font_color", COLOR_WARNING)


## The choice screen owns the input while it is open, exactly like the shop and the
## bench: Esc closes it without committing, the movement actions walk the three fates,
## E / Enter confirms the highlighted one. Enter has no InputMap action, so it is
## edge-detected by hand the way it is in the inventory; the bot drives selection through
## `interact` alone.
func _process_ending_choice_navigation() -> void:
	if _ending_choice_lock_input:
		_ending_choice_lock_input = false
		return
	if _consume_action(&"pause"):
		_close_ending_choice()
		return
	var delta := 0
	if _consume_action(&"move_up"):
		delta -= 1
	if _consume_action(&"move_down"):
		delta += 1
	if delta != 0:
		_ending_choice_selected = clampi(_ending_choice_selected + delta, 0, _ending_choice_rows.size() - 1)
		_refresh_ending_choice()
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if _consume_action(&"interact") or enter_edge:
		_confirm_ending_choice()


## Confirms the highlighted fate by handing the id straight to the altar — the single
## source of truth. A locked fate is refused there (the altar toasts the reason) and the
## panel stays open so the player can pick another; an accepted one opens the victory
## screen, which takes over `ui_blocking` and the pause itself, so the choice panel steps
## aside WITHOUT recomputing the block (that would clear the victory screen's own block).
func _confirm_ending_choice() -> void:
	if _ending_altar == null or not is_instance_valid(_ending_altar):
		return
	var ids: Array = _ending_altar.call("ending_ids")
	if _ending_choice_selected < 0 or _ending_choice_selected >= ids.size():
		return
	var id := String(ids[_ending_choice_selected])
	if bool(_ending_altar.call("choose", id)):
		_ending_choice_open = false
		_ending_choice_lock_input = false
		_ending_altar = null
		_enter_held = false
		if _ending_choice_panel != null:
			_ending_choice_panel.visible = false


# Read-only views of the choice panel, so a test or a screenshot probe can read the
# three rows and the cursor without reaching into the panel's private node tree — the
# same contract `defeat_row_texts` gives. `ending_choice_text` joins rows and descriptions
# so a test can prove the lock reason is on screen, not only in a toast.

func is_ending_choice_open() -> bool:
	return _ending_choice_open


func ending_choice_selection() -> int:
	return _ending_choice_selected


func ending_choice_row_texts() -> Array[String]:
	var out: Array[String] = []
	for row in _ending_choice_rows:
		out.append(row.text)
	return out


func ending_choice_text() -> String:
	var parts: PackedStringArray = []
	for row in _ending_choice_rows:
		parts.append(row.text)
	for desc in _ending_choice_descs:
		parts.append(desc.text)
	return "\n".join(parts)
