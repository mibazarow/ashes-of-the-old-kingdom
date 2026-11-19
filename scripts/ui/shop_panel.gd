class_name ShopPanel
extends PanelContainer
## Buy/sell screen for one merchant (spec §14.3).
##
## Like CharacterPanel and SettingsPanel this is its own Control script: it owns
## its layout and centring, while the HUD opens, closes and gates it and feeds it
## the same InputSource polling every other panel uses, so the debug bot and a
## human drive it through one code path. The panel holds no rules of its own —
## every trade goes through the injected `ShopManager`, which is the single place
## gold, inventory and stock are checked and changed. The panel only renders the
## current state and surfaces the reason a trade was refused.
##
## Two modes share one list: buy walks the merchant's stock, sell walks the
## player's inventory. Tab switches between them; the cursor, the price and the
## detail line all follow the mode, so there is never a moment where the number
## on screen and the action E would take disagree.

const MAX_VISIBLE_ROWS := 8

const COLOR_HEADER := Color(0.96, 0.86, 0.5)
const COLOR_ROW := Color(0.9, 0.92, 0.86)
const COLOR_ROW_SELECTED := Color(1.0, 0.97, 0.62)
const COLOR_GOLD := Color(0.96, 0.82, 0.38)
const COLOR_DETAIL := Color(0.78, 0.86, 0.66)
const COLOR_HINT := Color(0.6, 0.62, 0.6)
const COLOR_REASON := Color(0.98, 0.66, 0.36)
const COLOR_SOLD_OUT := Color(0.55, 0.57, 0.55)

## Human-readable refusal for each reason code the ShopManager returns, so the
## player reads why a trade failed instead of watching nothing happen. A reason
## with no entry here would show its raw code, which is a bug we would rather see.
const REASONS_RU := {
	"unknown_item": "Неизвестный предмет",
	"not_in_stock": "Нет в наличии",
	"not_enough_gold": "Не хватает золота",
	"no_space": "Нет места в сумке",
	"not_owned": "Нечего продавать",
	"no_value": "Нет цены",
	"quest_item": "Этот предмет не продаётся",
	"equipped_item": "Сначала снимите с персонажа",
}

var _shop: ShopManager
var _buy_mode := true
var _selected := 0
var _scroll := 0
var _reason := ""
var _row_ids: Array[String] = []
var _gold_label: Label
var _mode_label: Label
var _list: VBoxContainer
var _detail_label: Label
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

	_mode_label = _make_text("", COLOR_HEADER)
	box.add_child(_mode_label)

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

	_reason_label = _make_text("", COLOR_REASON)
	_reason_label.visible = false
	box.add_child(_reason_label)

	box.add_child(_make_text("↑/↓ выбор · E купить/продать · Tab режим · Esc закрыть", COLOR_HINT))
	refresh()
	_center.call_deferred()


## Called by the HUD every time the shop opens. The panel keeps the manager the
## merchant handed over; it never builds its own, so the stock the player sees is
## the merchant's live stock.
func open(shop: ShopManager) -> void:
	_shop = shop
	_buy_mode = true
	_selected = 0
	_scroll = 0
	_reason = ""
	refresh()
	_center()


func is_buy_mode() -> bool:
	return _buy_mode


func toggle_mode() -> void:
	_buy_mode = not _buy_mode
	_selected = 0
	_scroll = 0
	_reason = ""
	refresh()


func move_selection(step: int) -> void:
	if _row_ids.is_empty():
		_selected = 0
		return
	_selected = clampi(_selected + step, 0, _row_ids.size() - 1)
	refresh()


## E on the selected row: one unit bought or sold through the manager. A refusal
## changes nothing in the world and only sets the reason line; a success clears it
## and re-reads gold, inventory and stock, which the manager just changed.
func activate() -> void:
	if _shop == null or _row_ids.is_empty():
		return
	_selected = clampi(_selected, 0, _row_ids.size() - 1)
	var item_id := _row_ids[_selected]
	var result: Dictionary = _shop.buy(item_id, 1) if _buy_mode else _shop.sell(item_id, 1)
	if bool(result.get("ok", false)):
		_reason = ""
	else:
		_reason = String(result.get("reason", ""))
	refresh()


func refresh() -> void:
	if _list == null:
		return
	_mode_label.text = "Лавка  [E] купить  ·  Tab: %s" % ("продать" if _buy_mode else "купить")
	_gold_label.text = "Золото: %d" % (GameState.gold if GameState != null else 0)
	for child in _list.get_children():
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
	_detail_label.text = _detail_for(_row_ids[_selected])
	_apply_reason()


## Buy rows are the merchant's stock; sell rows are the inventory. Both keep a
## stable order (data order, then inventory order) so the cursor does not jump
## under the player between refreshes.
func _collect_rows() -> Array[String]:
	var ids: Array[String] = []
	if _shop == null:
		return ids
	if _buy_mode:
		for entry in _shop.stock_entries():
			ids.append(String(entry.get("item_id", "")))
	else:
		for slot in GameState.inventory:
			ids.append(String(slot["id"]))
	return ids


func _make_row(item_id: String, selected: bool) -> Label:
	var name := ItemDB.display_name(item_id)
	var icon := ItemDB.icon(item_id)
	var line := ""
	var color := COLOR_ROW
	if _buy_mode:
		var left := _shop.stock_of(item_id)
		line = "%s %s · %d з. · есть %d" % [icon, name, _shop.buy_price(item_id), left]
		color = COLOR_ROW if left > 0 else COLOR_SOLD_OUT
	else:
		var owned := GameState.count_item(item_id)
		line = "%s %s · %d з. · %d шт." % [icon, name, _shop.sell_price(item_id), owned]
	if selected:
		line = "> " + line
		color = color.lightened(0.35) if not _buy_mode or _shop.stock_of(item_id) > 0 else COLOR_SOLD_OUT
	return _make_text(line, color)


func _detail_for(item_id: String) -> String:
	var def := ItemDB.get_item(item_id)
	var desc := String(def.get("description", ""))
	if _buy_mode:
		var head := "Покупка: %d з." % _shop.buy_price(item_id)
		return head if desc == "" else "%s\n%s" % [head, desc]
	var sell_head := "Продажа: %d з." % _shop.sell_price(item_id)
	return sell_head if desc == "" else "%s\n%s" % [sell_head, desc]


func _apply_reason() -> void:
	if _reason == "":
		_reason_label.visible = false
		_reason_label.text = ""
		return
	_reason_label.text = REASONS_RU.get(_reason, _reason)
	_reason_label.visible = true


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
