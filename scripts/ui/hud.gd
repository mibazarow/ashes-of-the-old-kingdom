class_name Hud
extends CanvasLayer
## All UI built in code: bars, quest tracker, prompts, dialogue, inventory, pause.

const BAR_W := 92.0
const BAR_H := 7.0
const QUICK_SLOT_ACTIONS := [&"quick_slot_1", &"quick_slot_2", &"quick_slot_3", &"quick_slot_4"]

var _root: Control
var _hp_bar: ProgressBar
var _mp_bar: ProgressBar
var _xp_bar: ProgressBar
var _hp_label: Label
var _mp_label: Label
var _level_label: Label
var _gold_label: Label
var _quest_label: Label
var _skill_label: Label
var _prompt_label: Label
var _toast_label: Label
var _dialogue_panel: PanelContainer
var _dialogue_speaker: Label
var _dialogue_text: Label
var _inventory_panel: PanelContainer
var _inventory_list: VBoxContainer
var _quick_slot_list: VBoxContainer
var _journal_panel: PanelContainer
var _journal_list: VBoxContainer
var _pause_panel: PanelContainer
var _hint_label: Label
var _map_panel: MapPanel
var _settings_panel: SettingsPanel
var _toast_tween: Tween
var _dialogue_open := false
var _inventory_open := false
var _journal_open := false
var _map_open := false
var _paused := false
var _settings_open := false
var _settings_just_closed := false


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
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
		"WASD · ЛКМ удар · ПКМ умение · Space рывок · E действие · I инв · J журнал · M карта · F5/F9",
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

	var hint := _make_text("[E] продолжить", Color(0.6, 0.62, 0.6))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(hint)


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

	_inventory_list = VBoxContainer.new()
	_inventory_list.add_theme_constant_override("separation", 1)
	box.add_child(_inventory_list)

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
	for child in _inventory_list.get_children():
		child.queue_free()
	if GameState.inventory.is_empty():
		_inventory_list.add_child(_make_text("пусто", Color(0.6, 0.6, 0.58)))
		return
	for slot in GameState.inventory:
		var id := String(slot["id"])
		var amount := int(slot["amount"])
		var label := "%s x%d" % [ItemDB.display_name(id), amount]
		var weapon_id: String = String(GameState.equipment.get("weapon", ""))
		var armor_id: String = String(GameState.equipment.get("armor", ""))
		var equipped: bool = weapon_id == id or armor_id == id
		if equipped:
			label += "  [надето]"
		var row := _make_text(label, Color(0.9, 0.92, 0.86))
		_inventory_list.add_child(row)


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
	var first: Dictionary = lines[0]
	_dialogue_speaker.text = String(first.get("speaker", ""))
	_dialogue_text.text = String(first.get("text", ""))
	_dialogue_panel.visible = true
	_dialogue_open = true
	GameState.ui_blocking = true
	EventBus.interact_prompt.emit("")


func close_dialogue() -> void:
	if not _dialogue_open:
		return
	_dialogue_panel.visible = false
	_dialogue_open = false
	GameState.ui_blocking = _inventory_open or _journal_open or _paused or _map_open
	EventBus.dialogue_closed.emit()


func _toggle_inventory() -> void:
	_inventory_open = not _inventory_open
	if _inventory_open:
		_journal_open = false
		_journal_panel.visible = false
		_refresh_inventory()
	_inventory_panel.visible = _inventory_open
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open or _paused or _map_open


func _toggle_journal() -> void:
	_journal_open = not _journal_open
	if _journal_open:
		_inventory_open = false
		_inventory_panel.visible = false
		_refresh_journal()
	_journal_panel.visible = _journal_open
	GameState.ui_blocking = _journal_open or _dialogue_open or _inventory_open or _paused or _map_open


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
	GameState.ui_blocking = _paused or _inventory_open or _dialogue_open or _journal_open or _map_open
	EventBus.game_paused.emit(_paused)


## UI polls the same InputSource the player uses, so a human and the debug bot
## drive menus through one code path. Real InputEvents would be invisible to the
## bot, which is exactly the privileged/unequal access the spec forbids.
func _process(_delta: float) -> void:
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
	_map_open = true
	if _map_panel != null:
		_map_panel.visible = true
		_map_panel.refresh()
	GameState.ui_blocking = true


func _close_map() -> void:
	_map_open = false
	if _map_panel != null:
		_map_panel.visible = false
	GameState.ui_blocking = _inventory_open or _dialogue_open or _journal_open or _paused


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
	GameState.ui_blocking = _paused or _inventory_open or _dialogue_open or _journal_open or _map_open


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
