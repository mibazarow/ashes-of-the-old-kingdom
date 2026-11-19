class_name ShopManager
extends RefCounted
## Pure buy/sell rules for one merchant, driven by data/shop.json.
##
## The class holds no scene and reads no autoload by name: the caller injects a
## `GameState` reference, so the same rules run in the live game and in a
## headless test with a throwaway state. `data/shop.json` is the single source of
## stock — nothing here hardcodes an item or a price. Prices come from `ItemDB`,
## which reads `data/items.json`, so a price edit lands in one place only.
##
## Atomicity (spec §14.3): every mutation first runs the matching `can_*` check,
## which is pure and writes nothing. Only after it passes does the commit run, and
## the one step that can still fail is ordered first — `buy` spends gold before it
## touches the inventory, `sell` pays gold before it removes the item — so a
## rejected or interrupted trade leaves gold, inventory and stock exactly as they
## were. A trade never half-applies.

const PATH := "res://data/shop.json"

## Stack cap used by the free-space check. The inventory keeps one slot per item
## id, so a purchase is refused when it would push that stack past this cap; the
## item is never silently dropped and never split into a phantom second slot.
const MAX_STACK := 99

## The injected `GameState`. Typed loosely as `Node` so this script compiles
## without an autoload identifier in scope; every call is a plain method call.
var _state: Node
var _stock: Dictionary = {}
var _buy_rate: float = 0.5
var _merchant_id: String = ""


func _init(state: Node) -> void:
	_state = state
	_load()


func _load() -> void:
	if not FileAccess.file_exists(PATH):
		push_error("ShopManager: missing %s" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary):
		push_error("ShopManager: cannot parse %s" % PATH)
		return
	var data: Dictionary = parsed
	_merchant_id = String(data.get("merchant_id", ""))
	var rate: float = float(data.get("buy_rate", 0.5))
	# A rate outside 0..1 is a data error; clamp rather than sell above buy price.
	_buy_rate = clampf(rate, 0.0, 1.0)
	_stock = {}
	var entries: Variant = data.get("stock", [])
	if entries is Array:
		for entry in entries:
			if not (entry is Dictionary):
				continue
			var item_id := String(entry.get("item_id", ""))
			if item_id == "" or ItemDB.get_item(item_id).is_empty():
				continue
			var amount := int(entry.get("amount", 0))
			if amount < 0:
				amount = 0
			# One entry per id wins; a duplicated id must not double the stock.
			_stock[item_id] = amount


func merchant_id() -> String:
	return _merchant_id


func buy_rate() -> float:
	return _buy_rate


## Remaining stock for one item; an item the merchant never carried reads as 0.
func stock_of(item_id: String) -> int:
	return int(_stock.get(item_id, 0))


## Current stock as `[{item_id, amount}]`, in the order the data lists it, for a
## UI to render. Amounts reflect live stock, so a bought-out entry shows 0.
func stock_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item_id in _stock:
		out.append({"item_id": String(item_id), "amount": stock_of(String(item_id))})
	return out


## Full buy price for one unit — the item's data price, unchanged.
func buy_price(item_id: String) -> int:
	return int(ItemDB.get_item(item_id).get("price", 0))


## What the merchant pays for one unit: `floor(price * buy_rate)`, floored at 0.
## There is deliberately no forced minimum of 1: an item the data prices at 0 is
## worth nothing back, and a forced 1 would make it an infinite gold printer (the
## same free item sold for a coin over and over). A 0-value item is refused by
## `can_sell` with `no_value` instead of being paid for.
func sell_price(item_id: String) -> int:
	var raw := int(floor(float(buy_price(item_id)) * _buy_rate))
	return maxi(0, raw)


func can_buy(item_id: String, amount: int) -> Dictionary:
	if ItemDB.get_item(item_id).is_empty():
		return {"ok": false, "reason": "unknown_item"}
	if amount < 1 or stock_of(item_id) < amount:
		return {"ok": false, "reason": "not_in_stock"}
	var total := buy_price(item_id) * amount
	if _state.gold < total:
		return {"ok": false, "reason": "not_enough_gold"}
	if _state.count_item(item_id) + amount > MAX_STACK:
		return {"ok": false, "reason": "no_space"}
	return {"ok": true, "reason": ""}


func buy(item_id: String, amount: int) -> Dictionary:
	var check := can_buy(item_id, amount)
	if not bool(check.get("ok", false)):
		return {"ok": false, "reason": String(check.get("reason", "")), "gold_spent": 0}
	var total := buy_price(item_id) * amount
	# Gold first: it is the only step that can still fail, so a failure here
	# returns before the inventory or stock is touched — no partial state.
	if not _state.spend_gold(total):
		return {"ok": false, "reason": "not_enough_gold", "gold_spent": 0}
	_state.add_item(item_id, amount)
	_stock[item_id] = stock_of(item_id) - amount
	return {"ok": true, "reason": "", "gold_spent": total}


func can_sell(item_id: String, amount: int) -> Dictionary:
	if ItemDB.get_item(item_id).is_empty():
		return {"ok": false, "reason": "unknown_item"}
	if amount < 1 or _state.count_item(item_id) < amount:
		return {"ok": false, "reason": "not_owned"}
	if String(ItemDB.get_item(item_id).get("type", "")) == "quest":
		return {"ok": false, "reason": "quest_item"}
	# A worn item stays in the inventory, so count alone would let it be sold out
	# from under its slot; refuse any amount of an item that is currently worn.
	if String(_state.equipped_slot_of(item_id)) != "":
		return {"ok": false, "reason": "equipped_item"}
	# A 0-value item (price 0 in the data) is worth nothing back; paying even the
	# floor of 0 would mint gold from nothing, so refuse it before any coin moves.
	if sell_price(item_id) <= 0:
		return {"ok": false, "reason": "no_value"}
	return {"ok": true, "reason": ""}


func sell(item_id: String, amount: int) -> Dictionary:
	var check := can_sell(item_id, amount)
	if not bool(check.get("ok", false)):
		return {"ok": false, "reason": String(check.get("reason", "")), "gold_gained": 0}
	var total := sell_price(item_id) * amount
	# Pay first (spec §14.3: the item leaves only once payment succeeded). If the
	# removal then somehow fails, the gold is refunded so the player never pays
	# for nothing and never keeps both the item and the coin.
	_state.add_gold(total)
	if not _state.remove_item(item_id, amount):
		_state.add_gold(-total)
		return {"ok": false, "reason": "not_owned", "gold_gained": 0}
	# Stock is deliberately untouched: the merchant does not restock from the
	# player, so selling never inflates what the merchant offers to buy back.
	return {"ok": true, "reason": "", "gold_gained": total}
