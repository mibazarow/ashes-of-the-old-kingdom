class_name CraftPanel
extends PanelContainer
## Crafting screen for one station (spec §14.4).
##
## The sibling of `ShopPanel`: it owns its layout and centring, the HUD opens,
## closes and gates it, and every rule lives in the injected `CraftManager` — the
## panel holds no recipe, no price and no material of its own. It only renders
## what `preview()` says and surfaces the reason a craft was refused, so the
## number on screen and the action E would take cannot disagree.
##
## Spec §14.4 asks for the result and the cost to be visible before the player
## confirms, so the selected row drives three lines: the fee, one line per
## material as `need/have` (red when the inventory is short), and the produced
## item with its permanent bonus spelled out ("Атака +2") for an upgrade.

const MAX_VISIBLE_ROWS := 8

const COLOR_HEADER := Color(0.96, 0.86, 0.5)
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_GOLD := Color(0.96, 0.82, 0.38)
const COLOR_DETAIL := Color(0.78, 0.86, 0.66)
const COLOR_HINT := Color(0.6, 0.62, 0.6)
const COLOR_REASON := Color(0.98, 0.66, 0.36)
const COLOR_ENOUGH := Color(0.7, 0.78, 0.66)
const COLOR_SHORT := Color(0.93, 0.4, 0.34)

## Russian title per station, so the header names the bench the player is standing
## at. An unknown station falls back to its raw id, which is a data typo worth
## seeing rather than a silent "Ремесло".
const STATION_TITLES_RU := {
	"smith": "Кузнечный горн",
	"herbalist": "Травяная лавка",
}

## Russian name per upgradeable stat, used for the bonus the panel promises
## before the craft. `speed_bonus` and `resist_bonus` are percentages in the item
## data, so they carry the sign and the percent; the flat combat stats do not.
const UPGRADE_LABELS_RU := {
	"attack": "Атака",
	"defense": "Защита",
	"speed_bonus": "Скорость",
	"resist_bonus": "Сопротивление",
}

## Human-readable refusal for each reason code the CraftManager returns, so the
## player reads why nothing happened instead of watching a dead key. A reason with
## no entry here would show its raw code, which is a bug we would rather see.
const REASONS_RU := {
	"unknown_recipe": "Рецепт не найден",
	"locked": "Рецепт ещё не известен",
	"already_upgraded": "Это уже улучшено",
	"not_enough_gold": "Не хватает золота",
	"missing_material": "Не хватает материалов",
	"no_space": "Нет места в сумке",
}

var _craft: CraftManager
var _selected := 0
var _scroll := 0
var _reason := ""
var _row_ids: Array[String] = []
var _title_label: Label
var _gold_label: Label
var _list: VBoxContainer
var _detail_label: Label
var _materials: VBoxContainer
var _reason_label: Label


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

	_title_label = _make_text("Ремесло", COLOR_HEADER)
	box.add_child(_title_label)

	_gold_label = _make_text("", COLOR_GOLD)
	box.add_child(_gold_label)

	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 1)
	box.add_child(_list)

	_detail_label = _make_text("", COLOR_DETAIL)
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_label.max_lines_visible = 2
	box.add_child(_detail_label)

	# One line per material, outside the recipe list, so the row count stays capped
	# at MAX_VISIBLE_ROWS and the panel stays inside 480x270 whatever a recipe asks
	# for. Hidden (zero height) when the recipe needs nothing.
	_materials = VBoxContainer.new()
	_materials.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_materials.add_theme_constant_override("separation", 1)
	box.add_child(_materials)

	_reason_label = _make_text("", COLOR_REASON)
	_reason_label.visible = false
	box.add_child(_reason_label)

	box.add_child(_make_text("↑/↓ выбор · E создать · Esc закрыть", COLOR_HINT))
	refresh()
	_center.call_deferred()


## Called by the HUD every time the station opens. The panel keeps the manager the
## NPC handed over; it never builds its own, so the unlock flags and the prices it
## shows are the ones the player actually owns.
func open(craft: CraftManager) -> void:
	_craft = craft
	_selected = 0
	_scroll = 0
	_reason = ""
	refresh()
	_center()


func move_selection(step: int) -> void:
	if _row_ids.is_empty():
		_selected = 0
		return
	_selected = clampi(_selected + step, 0, _row_ids.size() - 1)
	refresh()


## Test/screenshot hook: parks the cursor on one row without simulating keys.
func select_row(index: int) -> void:
	_selected = clampi(index, 0, maxi(0, _row_ids.size() - 1))
	refresh()


func selected_index() -> int:
	return _selected


## E on the selected row: one craft through the manager. A refusal changes nothing
## in the world and only sets the reason line; a success clears it and re-reads
## gold, materials and inventory, which the manager just changed.
func activate() -> void:
	if _craft == null or _row_ids.is_empty():
		return
	_selected = clampi(_selected, 0, _row_ids.size() - 1)
	var result: Dictionary = _craft.craft(_row_ids[_selected])
	if bool(result.get("ok", false)):
		_reason = ""
		var output := String(result.get("output", ""))
		EventBus.toast.emit("Создано: %s" % ItemDB.display_name(output))
	else:
		_reason = String(result.get("reason", ""))
	refresh()


func refresh() -> void:
	if _list == null:
		return
	_title_label.text = STATION_TITLES_RU.get(_station_key(), "Ремесло")
	_gold_label.text = "Золото: %d" % (GameState.gold if GameState != null else 0)
	for child in _list.get_children():
		child.queue_free()
	for child in _materials.get_children():
		child.queue_free()
	_row_ids = _collect_rows()
	if _row_ids.is_empty():
		_selected = 0
		_scroll = 0
		_list.add_child(_make_text("пусто", Color(0.6, 0.6, 0.58)))
		_detail_label.text = ""
		_apply_reason()
		return
	_selected = clampi(_selected, 0, _row_ids.size() - 1)
	if _selected < _scroll:
		_scroll = _selected
	elif _selected >= _scroll + MAX_VISIBLE_ROWS:
		_scroll = _selected - (MAX_VISIBLE_ROWS - 1)
	_scroll = clampi(_scroll, 0, maxi(0, _row_ids.size() - MAX_VISIBLE_ROWS))
	var first := _scroll
	var last := mini(_row_ids.size(), first + MAX_VISIBLE_ROWS)
	for i in range(first, last):
		_list.add_child(_make_row(_row_ids[i], i == _selected))
	_render_detail(_row_ids[_selected])
	_apply_reason()


## The station whose bench is open. A manager built without one lists every
## recipe it knows, which is what a test or a screenshot of the whole table needs;
## a station NPC always passes its own id, so in play the list is that bench only.
func _station_key() -> String:
	return _craft.station() if _craft != null else ""


func _collect_rows() -> Array[String]:
	var ids: Array[String] = []
	if _craft == null:
		return ids
	var station := _craft.station()
	if station == "":
		return _craft.recipe_ids()
	for recipe_id in _craft.station_recipes(station):
		ids.append(String(recipe_id))
	return ids


func _make_row(recipe_id: String, selected: bool) -> Label:
	var output := String(_craft.preview(recipe_id).get("output", ""))
	var icon := ItemDB.icon(output) if output != "" else "?"
	var line := "%s %s · %d з." % [icon, _craft.recipe_name(recipe_id), _craft.gold_cost(recipe_id)]
	var color := COLOR_ROW
	if not bool(_craft.can_craft(recipe_id).get("ok", false)):
		# Not an error yet — the player may simply not have paid for it. Dimmed
		# rather than red, because the material lines below say exactly what is
		# short and a wall of red would shout at every recipe at once.
		color = Color(0.62, 0.64, 0.6)
	if selected:
		line = "> " + line
		color = color.lightened(0.35)
	return _make_text(line, color)


## The three lines §14.4 asks for before confirming: what it costs, what it eats
## (need/have, red when short), and what comes out — including the permanent
## bonus, spelled out, when the recipe is an upgrade.
func _render_detail(recipe_id: String) -> void:
	var info: Dictionary = _craft.preview(recipe_id)
	var output := String(info.get("output", ""))
	var icon := ItemDB.icon(output) if output != "" else "?"
	var amount := 1
	var raw_amount: Variant = _craft.recipe(recipe_id).get("output_amount", 1)
	if raw_amount is int or raw_amount is float:
		amount = maxi(1, int(raw_amount))
	var detail := "Результат: %s %s x%d" % [icon, String(info.get("output_name", "")), amount]
	if _has_upgrade(info):
		detail += "  ·  " + _upgrade_text(info.get("upgrade", {}))
	_detail_label.text = detail
	for child in _materials.get_children():
		child.queue_free()
	var materials: Dictionary = info.get("materials", {})
	for item_id: String in materials:
		var entry: Dictionary = materials[item_id] as Dictionary
		var need := int(entry.get("need", 0))
		var have := int(entry.get("have", 0))
		var line := "%s %s %d/%d" % [ItemDB.icon(item_id), ItemDB.display_name(item_id), need, have]
		_materials.add_child(_make_text(line, COLOR_ENOUGH if have >= need else COLOR_SHORT))


func _has_upgrade(info: Dictionary) -> bool:
	var upgrade: Variant = info.get("upgrade", {})
	return upgrade is Dictionary and not (upgrade as Dictionary).is_empty()


## "Атака +2" for one stat, joined with " · " when a block carries several. A stat
## the panel has no Russian name for shows its raw key, so a new upgradeable stat
## is visible in the UI instead of silently missing.
func _upgrade_text(raw: Variant) -> String:
	if not (raw is Dictionary):
		return ""
	var parts: PackedStringArray = []
	for stat: String in (raw as Dictionary):
		var value := int((raw as Dictionary)[stat])
		var label := String(UPGRADE_LABELS_RU.get(stat, stat))
		var suffix := "%" if (stat == "speed_bonus" or stat == "resist_bonus") else ""
		parts.append("%s +%d%s" % [label, value, suffix])
	return ", ".join(parts)


func _apply_reason() -> void:
	if _reason == "":
		_reason_label.visible = false
		_reason_label.text = ""
		return
	_reason_label.text = REASONS_RU.get(_reason, _reason)
	_reason_label.visible = true


# --- read-only views for tests and the screenshot probe ----------------------

func row_texts() -> PackedStringArray:
	return _label_texts(_list)


func material_texts() -> PackedStringArray:
	return _label_texts(_materials)


func detail_text() -> String:
	return _detail_label.text if _detail_label != null else ""


func reason_text() -> String:
	if _reason_label == null or not _reason_label.visible:
		return ""
	return _reason_label.text


func _label_texts(box: VBoxContainer) -> PackedStringArray:
	var out: PackedStringArray = []
	if box == null:
		return out
	for child in box.get_children():
		if child is Label:
			out.append((child as Label).text)
	return out


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
