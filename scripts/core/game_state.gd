extends Node
## Authoritative player + run state. Everything that must survive a save lives here.

const XP_PER_LEVEL := 40
const MAX_LEVEL := 20
const QUICK_SLOT_COUNT := 4

var level: int = 1
var xp: int = 0
var xp_to_next: int = XP_PER_LEVEL

var hp: int = 100
var max_hp: int = 100
var mana: int = 60
var max_mana: int = 60
var base_attack: int = 5
var base_defense: int = 0
var gold: int = 0

var inventory: Array[Dictionary] = []
var equipment: Dictionary = {"weapon": "", "armor": ""}

## Quick slots 1–4 (index 0..3); an empty string means the slot is unassigned.
var quick_slots: Array[String] = ["health_potion", "mana_potion", "", ""]

var flags: Dictionary = {}
var kills: Dictionary = {}
var play_time_ms: int = 0

## Set while a modal UI (dialogue, inventory, pause) owns the input.
var ui_blocking: bool = false

var _last_tick_ms: int = 0


func _ready() -> void:
	_last_tick_ms = Time.get_ticks_msec()
	reset()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	play_time_ms += now - _last_tick_ms
	_last_tick_ms = now


func reset() -> void:
	level = 1
	xp = 0
	xp_to_next = XP_PER_LEVEL
	max_hp = 100
	hp = max_hp
	max_mana = 60
	mana = max_mana
	base_attack = 5
	base_defense = 0
	gold = 0
	inventory = []
	equipment = {"weapon": "", "armor": ""}
	quick_slots = _default_quick_slots()
	flags = {}
	kills = {}
	play_time_ms = 0
	_emit_all()


func _emit_all() -> void:
	EventBus.player_health_changed.emit(hp, max_hp)
	EventBus.player_mana_changed.emit(mana, max_mana)
	EventBus.player_xp_changed.emit(xp, xp_to_next, level)
	EventBus.player_gold_changed.emit(gold)
	EventBus.inventory_changed.emit()
	EventBus.equipment_changed.emit()


# --- health / resources -------------------------------------------------------

func take_damage(amount: int) -> int:
	if amount <= 0 or hp <= 0:
		return 0
	var applied := mini(amount, hp)
	hp -= applied
	EventBus.player_health_changed.emit(hp, max_hp)
	if hp <= 0:
		EventBus.player_died.emit()
	return applied


func heal(amount: int) -> int:
	var before := hp
	hp = mini(max_hp, hp + maxi(amount, 0))
	var applied := hp - before
	if applied > 0:
		EventBus.player_health_changed.emit(hp, max_hp)
	return applied


func restore_mana(amount: int) -> int:
	var before := mana
	mana = mini(max_mana, mana + maxi(amount, 0))
	var applied := mana - before
	if applied > 0:
		EventBus.player_mana_changed.emit(mana, max_mana)
	return applied


func spend_mana(amount: int) -> bool:
	if mana < amount:
		return false
	mana -= amount
	EventBus.player_mana_changed.emit(mana, max_mana)
	return true


func revive_full() -> void:
	hp = max_hp
	mana = max_mana
	EventBus.player_health_changed.emit(hp, max_hp)
	EventBus.player_mana_changed.emit(mana, max_mana)


# --- progression --------------------------------------------------------------

func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	xp += amount
	while xp >= xp_to_next and level < MAX_LEVEL:
		xp -= xp_to_next
		level += 1
		xp_to_next = XP_PER_LEVEL + (level - 1) * 25
		max_hp += 12
		hp = max_hp
		max_mana += 6
		mana = max_mana
		EventBus.toast.emit("Уровень %d" % level)
	EventBus.player_xp_changed.emit(xp, xp_to_next, level)
	EventBus.player_health_changed.emit(hp, max_hp)
	EventBus.player_mana_changed.emit(mana, max_mana)


func add_gold(amount: int) -> void:
	gold = maxi(0, gold + amount)
	EventBus.player_gold_changed.emit(gold)


func spend_gold(amount: int) -> bool:
	if amount < 0 or gold < amount:
		return false
	gold -= amount
	EventBus.player_gold_changed.emit(gold)
	return true


func total_attack() -> int:
	var bonus := 0
	var weapon: String = equipment.get("weapon", "")
	if weapon != "":
		bonus += int(ItemDB.get_item(weapon).get("attack", 0))
	return base_attack + bonus


func total_defense() -> int:
	var bonus := 0
	var armor: String = equipment.get("armor", "")
	if armor != "":
		bonus += int(ItemDB.get_item(armor).get("defense", 0))
	return base_defense + bonus


# --- inventory ----------------------------------------------------------------

func add_item(item_id: String, amount: int = 1) -> void:
	if amount <= 0:
		return
	for slot in inventory:
		if String(slot["id"]) == item_id:
			slot["amount"] = int(slot["amount"]) + amount
			EventBus.item_picked.emit(StringName(item_id), amount)
			EventBus.inventory_changed.emit()
			return
	inventory.append({"id": item_id, "amount": amount})
	EventBus.item_picked.emit(StringName(item_id), amount)
	EventBus.inventory_changed.emit()


func remove_item(item_id: String, amount: int = 1) -> bool:
	for i in range(inventory.size()):
		var slot := inventory[i]
		if String(slot["id"]) != item_id:
			continue
		if int(slot["amount"]) < amount:
			return false
		slot["amount"] = int(slot["amount"]) - amount
		if int(slot["amount"]) <= 0:
			inventory.remove_at(i)
		EventBus.inventory_changed.emit()
		return true
	return false


func count_item(item_id: String) -> int:
	for slot in inventory:
		if String(slot["id"]) == item_id:
			return int(slot["amount"])
	return 0


func equip(item_id: String) -> bool:
	var def := ItemDB.get_item(item_id)
	if def.is_empty():
		return false
	var slot: String = String(def.get("slot", ""))
	if slot == "":
		return false
	if count_item(item_id) <= 0:
		return false
	equipment[slot] = item_id
	EventBus.equipment_changed.emit()
	EventBus.toast.emit("Надето: %s" % String(def.get("name", item_id)))
	return true


# --- quick slots --------------------------------------------------------------

func _default_quick_slots() -> Array[String]:
	return ["health_potion", "mana_potion", "", ""]


## Assigns a consumable to quick slot `index` (0..3); "" clears the slot.
## Rejects an out-of-range index and anything that is not a consumable.
func set_quick_slot(index: int, item_id: String) -> bool:
	if index < 0 or index >= QUICK_SLOT_COUNT:
		return false
	if item_id != "" and not ItemDB.is_consumable(item_id):
		return false
	quick_slots[index] = item_id
	return true


func quick_slot_item(index: int) -> String:
	if index < 0 or index >= quick_slots.size():
		return ""
	return quick_slots[index]


# --- flags / counters ---------------------------------------------------------

func set_flag(key: String, value: Variant = true) -> void:
	flags[key] = value


func get_flag(key: String, fallback: Variant = false) -> Variant:
	return flags.get(key, fallback)


func register_kill(enemy_type: String) -> void:
	kills[enemy_type] = int(kills.get(enemy_type, 0)) + 1


func kill_count(enemy_type: String) -> int:
	return int(kills.get(enemy_type, 0))


# --- serialization ------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"level": level,
		"xp": xp,
		"xp_to_next": xp_to_next,
		"hp": hp,
		"max_hp": max_hp,
		"mana": mana,
		"max_mana": max_mana,
		"base_attack": base_attack,
		"base_defense": base_defense,
		"gold": gold,
		"inventory": inventory.duplicate(true),
		"equipment": equipment.duplicate(true),
		"quick_slots": quick_slots.duplicate(),
		"flags": flags.duplicate(true),
		"kills": kills.duplicate(true),
		"play_time_ms": play_time_ms,
	}


func from_dict(d: Dictionary) -> void:
	level = int(d.get("level", 1))
	xp = int(d.get("xp", 0))
	xp_to_next = int(d.get("xp_to_next", XP_PER_LEVEL))
	max_hp = int(d.get("max_hp", 100))
	hp = clampi(int(d.get("hp", max_hp)), 1, max_hp)
	max_mana = int(d.get("max_mana", 60))
	mana = clampi(int(d.get("mana", max_mana)), 0, max_mana)
	base_attack = int(d.get("base_attack", 5))
	base_defense = int(d.get("base_defense", 0))
	gold = int(d.get("gold", 0))
	inventory.clear()
	for slot in d.get("inventory", []):
		if slot is Dictionary and slot.has("id"):
			inventory.append({"id": String(slot["id"]), "amount": int(slot.get("amount", 1))})
	equipment = d.get("equipment", {"weapon": "", "armor": ""}).duplicate(true)
	quick_slots = _restore_quick_slots(d.get("quick_slots", null))
	flags = d.get("flags", {}).duplicate(true)
	kills = d.get("kills", {}).duplicate(true)
	play_time_ms = int(d.get("play_time_ms", 0))
	_emit_all()


## Saves written before quick slots existed have no such key, and a hand-edited
## one may hold anything, so anything unexpected falls back to the defaults
## rather than failing the load.
func _restore_quick_slots(raw: Variant) -> Array[String]:
	if raw is Array:
		var arr: Array = raw as Array
		if arr.size() == QUICK_SLOT_COUNT:
			var restored: Array[String] = []
			for value: Variant in arr:
				if not (value is String):
					return _default_quick_slots()
				restored.append(String(value))
			return restored
	return _default_quick_slots()
