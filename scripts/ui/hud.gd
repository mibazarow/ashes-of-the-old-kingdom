class_name Hud
extends CanvasLayer
## All UI built in code: bars, quest tracker, prompts, dialogue, inventory, pause.

const BAR_W := 92.0
const BAR_H := 7.0
const QUICK_SLOT_ACTIONS := [&"quick_slot_1", &"quick_slot_2", &"quick_slot_3", &"quick_slot_4"]
## At most this many inventory rows are rendered at once, so the panel can never
## grow past the 480x270 viewport; the cursor scrolls a window over the rest.
const MAX_VISIBLE_ROWS := 8
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_WARNING := Color(0.98, 0.66, 0.36)

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

var _root: Control
var _hp_bar: ProgressBar
var _mp_bar: ProgressBar
var _xp_bar: ProgressBar
var _hp_label: Label
var _mp_label: Label
var _level_label: Label
var _gold_label: Label
var _clock_label: Label
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
var _pause_panel: PanelContainer
var _hint_label: Label
var _map_panel: MapPanel
var _settings_panel: SettingsPanel
var _character_panel: CharacterPanel
var _shop_panel: ShopPanel
var _shop_manager: ShopManager
var _craft_panel: CraftPanel
var _craft_manager: CraftManager
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
var _tab_held: bool = false
var _day_clock: Node = null
var _clock_refresh_left := 0.0

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


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Merchants have no EventBus signal to knock on (the bus is not editable), so
	# they reach the HUD through this group to open the shop modal.
	add_to_group("hud")
	_build_ui()
	_connect_signals()
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

	# --- top row: stats left, level/gold right ---
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 4)
	column.add_child(top)

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

	_xp_bar = _make_bar(Color(0.62, 0.78, 0.32))
	_xp_bar.custom_minimum_size = Vector2(BAR_W + 20, 3)
	stats.add_child(_xp_bar)

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

	# --- quest tracker, then the controls hint on its own full-width row ---
	_quest_label = _make_text("", Color(0.86, 0.88, 0.78))
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_quest_label)

	# Selected skill, one compact line under the tracker. Clipped with an
	# ellipsis so a long skill name can never push past the 480 px viewport.
	_skill_label = _make_text("", Color(0.62, 0.78, 0.92))
	_skill_label.clip_text = true
	_skill_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_skill_label.max_lines_visible = 1
	column.add_child(_skill_label)

	_hint_label = _make_text(
		"WASD · ЛКМ удар · ПКМ умение · Space рывок · E действие · I инв · J журнал · M карта · C персонаж · F5/F9",
		Color(0.72, 0.74, 0.7)
	)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_hint_label)

	_build_dialogue_panel()
	_build_inventory_panel()
	_build_journal_panel()
	_build_pause_panel()
	_build_settings_panel()
	_build_map_panel()
	_build_character_panel()
	_build_shop_panel()
	_build_craft_panel()


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
	_map_panel = MapPanel.new()
	_map_panel.name = "MapPanel"
	_map_panel.setup(world)
	_map_panel.visible = false
	_root.add_child(_map_panel)


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
	_inventory_panel.position = Vector2(-90, -70)
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


func _make_theme() -> Theme:
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Helvetica Neue", "Arial Unicode MS", "Arial", "DejaVu Sans", "sans-serif"
	])
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
	label.custom_minimum_size = Vector2(16, 0)
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


func _refresh_all() -> void:
	_on_health(GameState.hp, GameState.max_hp)
	_on_mana(GameState.mana, GameState.max_mana)
	_on_xp(GameState.xp, GameState.xp_to_next, GameState.level)
	_on_gold(GameState.gold)
	_refresh_inventory()
	_refresh_quest()
	_refresh_skill()


func _on_health(current: int, maximum: int) -> void:
	_hp_bar.max_value = maxi(1, maximum)
	_hp_bar.value = current
	_hp_label.text = "%d" % current


func _on_mana(current: int, maximum: int) -> void:
	_mp_bar.max_value = maxi(1, maximum)
	_mp_bar.value = current
	_mp_label.text = "%d" % current
	_refresh_skill()


func _on_xp(current: int, needed: int, level: int) -> void:
	_xp_bar.max_value = maxi(1, needed)
	_xp_bar.value = current
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
		# Row colour is the item's rarity colour; the selected row is lightened so
		# the "> " cursor stays visible against every tier, from pale common-grey
		# to bright legendary-gold.
		var row_color := ItemDB.rarity_color(ItemDB.rarity(id))
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
	_inventory_detail.add_theme_color_override("font_color", ItemDB.rarity_color(tier))
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
	if InputSource.is_action_just_pressed(&"move_up"):
		delta -= 1
	if InputSource.is_action_just_pressed(&"move_down"):
		delta += 1
	if delta != 0:
		_move_inventory_selection(delta)
	# Enter has no InputMap action (it is a human-only alias for E), so it is
	# edge-detected by hand; the bot drives equipping through `interact`.
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if InputSource.is_action_just_pressed(&"interact") or enter_edge:
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
		# The pause menu advertises "C — Персонаж", so C can arrive while it is
		# on screen. Hide it, otherwise the two centred panels overlap.
		if _paused:
			_close_pause()
		_character_open = true
		_enter_held = false
		if _character_panel != null:
			_character_panel.visible = true
			_character_panel.open()
	GameState.ui_blocking = _character_open or _inventory_open or _dialogue_open \
			or _journal_open or _paused or _map_open or _settings_open or _shop_open or _craft_open


## One close path for the character screen, so every sibling modal (inventory,
## journal, map, Esc) leaves both the flag and the node in the same state.
func _close_character() -> void:
	if not _character_open:
		return
	_character_open = false
	_enter_held = false
	if _character_panel != null:
		_character_panel.visible = false
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open \
			or _paused or _map_open or _settings_open or _shop_open or _craft_open


## The character screen owns the input while it is open: the cursor walks the
## four attributes with the movement actions, and E / Enter spends a point on
## the selected one. Enter has no InputMap action (a human-only alias for E), so
## it is edge-detected by hand, exactly like in the inventory.
func _process_character_navigation() -> void:
	var delta := 0
	if InputSource.is_action_just_pressed(&"move_up"):
		delta -= 1
	if InputSource.is_action_just_pressed(&"move_down"):
		delta += 1
	if delta != 0 and _character_panel != null:
		_character_panel.move_selection(delta)
	var enter_now := Input.is_key_pressed(KEY_ENTER)
	var enter_edge := enter_now and not _enter_held
	_enter_held = enter_now
	if (InputSource.is_action_just_pressed(&"interact") or enter_edge) and _character_panel != null:
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
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open \
			or _paused or _map_open or _settings_open or _character_open or _craft_open


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
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open \
			or _paused or _map_open or _settings_open or _character_open or _shop_open


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
	GameState.ui_blocking = _inventory_open or _journal_open or _paused or _map_open or _character_open or _shop_open or _craft_open
	EventBus.dialogue_closed.emit()


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
			rows.append("> %d. %s" % [i + 1, label] if i == _dialogue_option_index else "  %d. %s" % [i + 1, label])
		_dialogue_options.text = "\n".join(rows)
		_dialogue_options.visible = true
	_refresh_dialogue_hint(not options.is_empty())


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
	if InputSource.is_action_just_pressed(&"pause"):
		close_dialogue()
		return
	var tab_now := Input.is_key_pressed(KEY_TAB)
	if tab_now and not _dialogue_tab_held:
		_dialogue_auto_advance = not _dialogue_auto_advance
		_refresh_dialogue_hint(not _dialogue_runner.current_options().is_empty())
	_dialogue_tab_held = tab_now
	var options := _dialogue_runner.current_options()
	var delta := 0
	if InputSource.is_action_just_pressed(&"move_up"):
		delta -= 1
	if InputSource.is_action_just_pressed(&"move_down"):
		delta += 1
	if delta != 0 and not options.is_empty():
		_dialogue_option_index = clampi(_dialogue_option_index + delta, 0, options.size() - 1)
		_render_dialogue_node()
	var space_now := Input.is_key_pressed(KEY_SPACE)
	var space_edge := space_now and not _dialogue_space_held
	_dialogue_space_held = space_now
	if InputSource.is_action_just_pressed(&"interact") or space_edge:
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
	else:
		_enter_held = false
	_inventory_panel.visible = _inventory_open
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open or _paused or _map_open or _character_open or _shop_open or _craft_open


func _toggle_journal() -> void:
	_journal_open = not _journal_open
	if _journal_open:
		_inventory_open = false
		_inventory_panel.visible = false
		if not _paused:
			_close_character()
		_refresh_journal()
	_journal_panel.visible = _journal_open
	GameState.ui_blocking = _journal_open or _dialogue_open or _inventory_open or _paused or _map_open or _character_open or _shop_open or _craft_open


func _refresh_journal() -> void:
	if _journal_list == null:
		return
	for child in _journal_list.get_children():
		child.queue_free()
	var shown := 0
	for quest_id: String in QuestManager.quests.keys():
		var q: Variant = QuestManager.quests[quest_id]
		if not (q is Dictionary):
			continue
		var title := String((q as Dictionary).get("title", quest_id))
		var state: String = QuestManager.state_of(quest_id)
		if state == QuestManager.STATE_ACTIVE:
			var line := "• %s — %d/%d" % [title, QuestManager.progress_of(quest_id), QuestManager.target_count(quest_id)]
			_journal_list.add_child(_make_text(line, Color(0.9, 0.92, 0.86)))
			shown += 1
		elif state == QuestManager.STATE_READY:
			_journal_list.add_child(_make_text("✔ %s — сдать" % title, Color(0.96, 0.86, 0.5)))
			shown += 1
		elif state == QuestManager.STATE_DONE:
			_journal_list.add_child(_make_text("✓ %s — выполнено" % title, Color(0.55, 0.57, 0.55)))
			shown += 1
	if shown == 0:
		_journal_list.add_child(_make_text("пока пусто", Color(0.6, 0.6, 0.58)))


func _toggle_pause() -> void:
	_paused = not _paused
	_pause_panel.visible = _paused
	get_tree().paused = _paused
	GameState.ui_blocking = _paused or _inventory_open or _dialogue_open or _journal_open or _map_open or _character_open or _shop_open or _craft_open
	EventBus.game_paused.emit(_paused)


## Leaving the pause menu without opening it again: used when another modal takes
## over the screen (the pause menu itself offers "C — Персонаж").
func _close_pause() -> void:
	if not _paused:
		return
	_paused = false
	_pause_panel.visible = false
	get_tree().paused = false
	EventBus.game_paused.emit(false)


## UI polls the same InputSource the player uses, so a human and the debug bot
## drive menus through one code path. Real InputEvents would be invisible to the
## bot, which is exactly the privileged/unequal access the spec forbids.
func _process(_delta: float) -> void:
	# The clock line refreshes on its own one-second cadence, ahead of every
	# modal early-return below, so it stays readable over the map, shop and bench.
	_tick_clock(_delta)
	# The settings screen captures raw events itself; while it is open no
	# action polling may reach the gameplay paths below.
	if _settings_open:
		return
	# The very Esc edge that closed the settings screen must not also unpause
	# the game in the same frame: it belongs to the settings screen alone.
	if _settings_just_closed:
		_settings_just_closed = false
		if InputSource.is_action_just_pressed(&"pause"):
			return
	if _map_open:
		if InputSource.is_action_just_pressed(&"pause") or InputSource.is_action_just_pressed(&"map"):
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
		if InputSource.is_action_just_pressed(&"pause"):
			close_shop()
			return
		if _shop_panel != null:
			var tab_now := Input.is_key_pressed(KEY_TAB)
			if tab_now and not _tab_held:
				_shop_panel.toggle_mode()
			_tab_held = tab_now
			var shop_delta := 0
			if InputSource.is_action_just_pressed(&"move_up"):
				shop_delta -= 1
			if InputSource.is_action_just_pressed(&"move_down"):
				shop_delta += 1
			if shop_delta != 0:
				_shop_panel.move_selection(shop_delta)
			if InputSource.is_action_just_pressed(&"interact"):
				_shop_panel.activate()
		return
	# The craft bench owns the input while it is open, exactly like the shop: Esc
	# closes it (never pausing the game underneath), the movement actions walk the
	# recipe list and E crafts one item. Every other key is swallowed, so a player
	# at the forge cannot open the inventory or the map over the bench, and the
	# panel — not the HUD — decides what E is worth through the CraftManager.
	if _craft_open:
		if InputSource.is_action_just_pressed(&"pause"):
			close_craft()
			return
		if _craft_panel != null:
			var craft_delta := 0
			if InputSource.is_action_just_pressed(&"move_up"):
				craft_delta -= 1
			if InputSource.is_action_just_pressed(&"move_down"):
				craft_delta += 1
			if craft_delta != 0:
				_craft_panel.move_selection(craft_delta)
			if InputSource.is_action_just_pressed(&"interact"):
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
		if InputSource.is_action_just_pressed(&"pause"):
			_toggle_character()
			return
	if InputSource.is_action_just_pressed(&"map"):
		_open_map()
		return
	if InputSource.is_action_just_pressed(&"pause"):
		if _dialogue_open:
			close_dialogue()
		elif _journal_open:
			_toggle_journal()
		else:
			_toggle_pause()
		return
	if InputSource.is_action_just_pressed(&"character"):
		_toggle_character()
		return
	if _paused:
		if InputSource.is_action_just_pressed(&"interact"):
			_open_settings()
		return
	if InputSource.is_action_just_pressed(&"journal"):
		_toggle_journal()
		return
	if InputSource.is_action_just_pressed(&"inventory"):
		_toggle_inventory()
		return
	if _inventory_open:
		_process_inventory_navigation()
		return
	if _character_open:
		_process_character_navigation()
		return
	if InputSource.is_action_just_pressed(&"interact") and _dialogue_open:
		close_dialogue()
		return
	if _dialogue_open or _inventory_open or _journal_open:
		return
	for index in QUICK_SLOT_ACTIONS.size():
		var action: StringName = QUICK_SLOT_ACTIONS[index]
		if InputSource.is_action_just_pressed(action):
			_use_quick_slot(index)
			return
	if InputSource.is_action_just_pressed(&"save_game"):
		var res: Dictionary = SaveManager.save_game(1)
		EventBus.toast.emit("Сохранено" if bool(res.get("ok", false)) else "Ошибка сохранения")
		return
	if InputSource.is_action_just_pressed(&"load_game"):
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
	_map_open = true
	if _map_panel != null:
		_map_panel.visible = true
		_map_panel.refresh()
	GameState.ui_blocking = true


func _close_map() -> void:
	_map_open = false
	if _map_panel != null:
		_map_panel.visible = false
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open or _paused or _character_open or _shop_open or _craft_open


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
	GameState.ui_blocking = _paused or _inventory_open or _dialogue_open or _journal_open or _map_open or _character_open or _shop_open or _craft_open


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
