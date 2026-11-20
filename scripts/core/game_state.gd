extends Node
## Authoritative player + run state. Everything that must survive a save lives here.

const QUICK_SLOT_COUNT := 4

## The six equipment slots of spec §7.3. The order is the display order of the
## character screen, and it is also the order every aggregation walks, so a slot
## cannot be skipped by one code path and seen by another. `accessory_1` and
## `accessory_2` are two concrete slots for the one data-level slot name
## `accessory`: an accessory item never names which of the two it wants.
const EQUIPMENT_SLOTS := ["weapon", "secondary", "armor", "boots", "accessory_1", "accessory_2"]

## The data-level slot name that may live in either of the two accessory slots.
const ACCESSORY_DATA_SLOT := "accessory"
const ACCESSORY_SLOTS := ["accessory_1", "accessory_2"]

# --- attributes (spec §7.1) ---------------------------------------------------
## The four attributes and their starting value. Every derived number the game
## reads (HP, mana, attack, crit, speed, magic power, control resistance) is a
## function of these plus the level, and `recompute_derived()` is the only place
## that turns them into numbers.
const ATTRIBUTE_NAMES := ["strength", "agility", "intelligence", "endurance"]
const BASE_ATTRIBUTE := 5

## Gendered Russian lead-in for an unmet requirement, so `equip_blocker` reads as
## natural text ("Нужна сила 7 (у вас 5)") rather than a machine string. The
## adjective agrees with the noun's grammatical gender (интеллект is masculine).
const ATTRIBUTE_REQUIRE_PHRASES := {
	"strength": "Нужна сила",
	"agility": "Нужна ловкость",
	"intelligence": "Нужен интеллект",
	"endurance": "Нужна выносливость",
}

## Hard ceiling of a single attribute (30). Without it one stat could be stacked
## until its derived number left the playable range; the per-level point pool is
## the real limit, this is the guard against a hand-edited or bugged save.
const MAX_ATTRIBUTE := 30

## Growth terms of the recomputation. The attribute terms come from
## data/progression.json; these are the flat base values and the per-level growth
## that exist before any point is spent.
const HP_BASE := 100
const HP_PER_LEVEL := 12
const MANA_BASE := 60
const MANA_PER_LEVEL := 6
const ATTACK_BASE := 5
const ATTACK_PER_STRENGTH := 1

## Safety ceilings and floors of the cached multipliers. The speed and resistance
## ceilings sit above what the attribute cap alone can produce (agility 30 gives
## 1.2 speed, endurance 30 gives 0.5 resistance), so the room left below them is
## the budget for equipment bonuses (`speed_bonus`, `resist_bonus`); past that
## the ceiling binds, which is the point — a ring cannot buy unlimited speed.
## The magic ceiling is the design value
## itself: intelligence 30 lands exactly on 2.5, so it is the end of the curve,
## and the floor keeps a below-base intelligence from ever weakening a spell.
const SPEED_MULTIPLIER_CAP := 1.3
const CONTROL_RESIST_CAP := 0.6
const MAGIC_MULTIPLIER_CAP := 2.5

const PROGRESSION_PATH := "res://data/progression.json"

## Where the player is standing. The id is one of the keys of `data/zones.json`,
## and `forest` is both the starting value and the fallback for a save that names
## nothing usable, so a corrupt or pre-zone save can never leave the run without
## a zone to load into.
const ZONES_PATH := "res://data/zones.json"
const DEFAULT_ZONE := "forest"

var zone: String = DEFAULT_ZONE

var level: int = 1
var xp: int = 0
var xp_to_next: int = 100

var hp: int = 100
var max_hp: int = 100
var mana: int = 60
var max_mana: int = 60
var base_attack: int = 5
var base_defense: int = 0
var gold: int = 0

## Сила / Ловкость / Интеллект / Выносливость and the points still unspent.
var attributes: Dictionary = {"strength": 5, "agility": 5, "intelligence": 5, "endurance": 5}
var attribute_points: int = 0

## Cached results of `recompute_derived()`. Read them through the getters; they
## are only ever written by the recompute, so they cannot drift apart.
var _crit_chance: float = 0.05
var _move_speed_multiplier: float = 1.0
var _magic_multiplier: float = 1.0
var _control_resistance: float = 0.0

var _progression_data: Dictionary = {}
var _progression_loaded: bool = false

## The zone ids read from `data/zones.json`, cached on first use. Held here as a
## plain list rather than reached through `ZoneManager` on purpose: the manager is
## a scene node that reads this very autoload, and pointing the other way too
## would close a compile-time cycle between the two scripts.
var _zone_ids: Array[String] = []
var _zones_loaded := false

var inventory: Array[Dictionary] = []

## The six slots of `EQUIPMENT_SLOTS`, each holding an item id or "" when empty.
## An item is never consumed by equipping, so it stays in `inventory` and the
## slot only records that it is currently worn.
var equipment: Dictionary = _default_equipment()

## Quick slots 1–4 (index 0..3); an empty string means the slot is unassigned.
var quick_slots: Array[String] = ["health_potion", "mana_potion", "", ""]

## Permanent equipment upgrades from the smith (spec §14.4): item id -> a block of
## stat -> bonus, e.g. `{"iron_sword": {"attack": 2}}`. Keyed by item id, not by
## the worn instance, because the game has no per-instance item identity: the
## smith tempers the *type*, and every sword of that type carries the tempering.
## `total_bonus()` reads this dictionary on the fly, so the bonus is rebuilt from
## the slots on every read — equipping, unequipping and re-equipping cannot stack
## it, and there is exactly one place that decides what an upgrade is worth.
var item_upgrades: Dictionary = {}

## Skills the player knows (spec §9). Default loadout: one projectile from each
## damage school plus the nature heal. selected_skill is what the right mouse
## button casts.
var known_skills: Array[String] = ["fire_bolt", "ice_bolt", "shock", "heal_impulse"]
var selected_skill: String = "fire_bolt"

## Unspent skill points (spec §16.1 "Навыки"). A separate pool from
## `attribute_points`: learning a skill spends one of these, spending an
## attribute point never touches it. The player starts with one so the skills
## screen has something to spend on the first run, and `add_xp` grants
## `skill_points_per_level()` more on every level alongside the attribute pool.
var skill_points: int = 1

## Starting skill-point pool and the ceiling a restored save may carry. The
## ceiling is generous (well past the eight skills that exist) because it only
## guards against a hand-edited or bugged save, not against legitimate play.
const STARTING_SKILL_POINTS := 1
const MAX_SKILL_POINTS := 64

var flags: Dictionary = {}
var kills: Dictionary = {}
var play_time_ms: int = 0

## Dialogue nodes the player has already seen (spec §12.2 fast-skip). Keys are
## `"<dialogue_id>:<node_id>"`, composed by `DialogueRunner`, so the same short
## node id used in two dialogues never collides. Lives here rather than in the
## runner because the runner is a throwaway per conversation while the read-set
## must outlive it through a save.
var dialogue_read: Array[String] = []

## Set while a modal UI (dialogue, inventory, pause) owns the input.
var ui_blocking: bool = false

## The slot the main menu asked the game to load, 0 when nothing was asked.
## Lives here rather than in a scene-local variable because the menu and the game
## are two different scenes and `change_scene_to_file` frees the caller: the
## autoload is the only object that outlives the handoff. `Main._apply_pending_load`
## reads it once in `_ready` and zeroes it, so a later scene change inside the same
## run cannot load the same slot a second time.
var pending_load_slot: int = 0

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
	attributes = _default_attributes()
	attribute_points = 0
	xp_to_next = xp_needed_for(level)
	base_defense = 0
	gold = 0
	inventory = []
	equipment = _default_equipment()
	item_upgrades = {}
	quick_slots = _default_quick_slots()
	known_skills = _default_known_skills()
	selected_skill = _default_selected_skill()
	skill_points = STARTING_SKILL_POINTS
	flags = {}
	kills = {}
	play_time_ms = 0
	dialogue_read = []
	zone = DEFAULT_ZONE
	recompute_derived()
	hp = max_hp
	mana = max_mana
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


# --- attributes (spec §7.1) ---------------------------------------------------

## Value of one attribute. An unknown name or a hand-edited non-number reads as
## the starting value rather than 0, so a corrupt save cannot zero out a stat.
func attribute(attr_name: String) -> int:
	var raw: Variant = attributes.get(attr_name, BASE_ATTRIBUTE)
	return int(raw) if (raw is int or raw is float) else BASE_ATTRIBUTE


## Ceiling of a single attribute. See MAX_ATTRIBUTE for why the cap exists.
func max_attribute() -> int:
	return MAX_ATTRIBUTE


## Spends one point from the pool into one attribute and recomputes everything
## derived from it. Rejects an unknown attribute, an empty pool and an attribute
## already at the cap, so a rejected call changes nothing at all.
func spend_attribute_point(attr_name: String) -> bool:
	if not ATTRIBUTE_NAMES.has(attr_name):
		return false
	if attribute_points <= 0:
		return false
	if attribute(attr_name) >= max_attribute():
		return false
	attributes[attr_name] = attribute(attr_name) + 1
	attribute_points -= 1
	recompute_derived()
	EventBus.player_health_changed.emit(hp, max_hp)
	EventBus.player_mana_changed.emit(mana, max_mana)
	return true


## The ONE place that turns level + attributes + equipment into numbers. It only
## ever assigns from those inputs (never accumulates), so calling it twice is the
## same as calling it once, and no other system can add to a derived value twice.
## The equipment terms that feed a cached multiplier (`speed_bonus`,
## `resist_bonus`) are read here through `total_bonus()`, which recomputes them
## from the slots every time, so taking an item off can never leave a residue.
## Attack and defense stay read-through (`total_attack()`, `total_defense()`)
## because they are not cached; temporary effects stay outside entirely.
func recompute_derived() -> void:
	var strength_points := attribute("strength") - BASE_ATTRIBUTE
	var agility_points := attribute("agility") - BASE_ATTRIBUTE
	var intelligence_points := attribute("intelligence") - BASE_ATTRIBUTE
	var endurance_points := attribute("endurance") - BASE_ATTRIBUTE
	var levels := maxi(0, level - 1)

	max_hp = HP_BASE + levels * HP_PER_LEVEL \
			+ endurance_points * _int_setting("hp_per_endurance", 5)
	max_mana = MANA_BASE + levels * MANA_PER_LEVEL \
			+ intelligence_points * _int_setting("mana_per_intelligence", 4)
	base_attack = ATTACK_BASE + strength_points * ATTACK_PER_STRENGTH

	_crit_chance = clampf(
		_float_setting("crit_base", 0.05) \
		+ float(agility_points) * _float_setting("crit_per_agility", 0.005), 0.0, 1.0)
	# The agility term and the equipment term are added before the clamp, so a
	# ring speeds up an already quick character up to the same ceiling and no
	# further. Both terms are percentages of the base speed.
	_move_speed_multiplier = clampf(
		1.0 + float(agility_points) * _float_setting("speed_per_agility", 0.8) / 100.0 \
		+ float(total_bonus("speed_bonus")) / 100.0,
		1.0, SPEED_MULTIPLIER_CAP)
	_magic_multiplier = clampf(
		1.0 + float(intelligence_points) * _float_setting("magic_per_intelligence", 0.06),
		1.0, MAGIC_MULTIPLIER_CAP)
	_control_resistance = clampf(
		float(endurance_points) * _float_setting("control_resist_per_endurance", 0.02) \
		+ float(total_bonus("resist_bonus")) / 100.0,
		0.0, CONTROL_RESIST_CAP)

	# Current pools only get clamped into the new maxima: raising a maximum never
	# refills anything, and a maximum that shrank must not leave the player above
	# its own ceiling.
	hp = clampi(hp, 0, max_hp)
	mana = clampi(mana, 0, max_mana)


## Шанс крита (Ловкость). Read by `Player._apply_attack_hits()`.
func crit_chance() -> float:
	return _crit_chance


## Множитель скорости бега (Ловкость плюс `speed_bonus` экипировки, с потолком
## SPEED_MULTIPLIER_CAP). Stacks multiplicatively with the status movement
## multiplier in `Player._move_multiplier()`.
func move_speed_multiplier() -> float:
	return _move_speed_multiplier


## Множитель магического урона (Интеллект). Applied at cast time in `Player`.
## `1.0 + (intelligence - 5) * magic_per_intelligence`, held inside 1.0..2.5, so
## the curve ends at the attribute cap instead of running away with it.
func magic_multiplier() -> float:
	return _magic_multiplier


## Сопротивление контролю (Выносливость), 0..CONTROL_RESIST_CAP.
func control_resistance() -> float:
	return _control_resistance


func _default_attributes() -> Dictionary:
	return {"strength": BASE_ATTRIBUTE, "agility": BASE_ATTRIBUTE,
			"intelligence": BASE_ATTRIBUTE, "endurance": BASE_ATTRIBUTE}


# --- progression (spec §7.2) --------------------------------------------------

## The curve lives in data/progression.json so tuning it is a data edit. Anything
## unusable falls back to the built-in curve rather than leaving the player with
## no progression at all.
func _progression() -> Dictionary:
	if not _progression_loaded:
		_progression_loaded = true
		_progression_data = _default_progression()
		if FileAccess.file_exists(PROGRESSION_PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROGRESSION_PATH))
			if parsed is Dictionary:
				_progression_data = _sanitize_progression(parsed as Dictionary)
			else:
				push_error("GameState: cannot parse %s" % PROGRESSION_PATH)
	return _progression_data


func _default_progression() -> Dictionary:
	return {
		"max_level": 20,
		"points_per_level": 2,
		"skill_points_per_level": 1,
		"xp_curve": [0, 100, 240, 420, 640, 900, 1200, 1540, 1920, 2340, 2800,
				3300, 3840, 4420, 5040, 5700, 6400, 7140, 7920, 8740, 9600],
		"crit_base": 0.05,
		"crit_per_agility": 0.005,
		"speed_per_agility": 0.8,
		"hp_per_endurance": 5,
		"mana_per_intelligence": 4,
		"magic_per_intelligence": 0.06,
		"control_resist_per_endurance": 0.02,
	}


## Keeps only the values that can actually be used: a curve that is not a
## monotonic number list, a negative point grant, a non-positive level cap and a
## non-numeric coefficient each fall back to the default for that one key, so one
## typo in the data cannot take progression down with it.
func _sanitize_progression(raw: Dictionary) -> Dictionary:
	var clean := _default_progression()
	var max_level_raw: Variant = raw.get("max_level", null)
	if (max_level_raw is int or max_level_raw is float) and int(max_level_raw) >= 2:
		clean["max_level"] = int(max_level_raw)
	var points_raw: Variant = raw.get("points_per_level", null)
	if (points_raw is int or points_raw is float) and int(points_raw) >= 0:
		clean["points_per_level"] = int(points_raw)
	var skill_points_raw: Variant = raw.get("skill_points_per_level", null)
	if (skill_points_raw is int or skill_points_raw is float) and int(skill_points_raw) >= 0:
		clean["skill_points_per_level"] = int(skill_points_raw)
	var curve_raw: Variant = raw.get("xp_curve", null)
	if curve_raw is Array:
		var curve: Array = curve_raw as Array
		var candidate: Array[int] = []
		var previous := -1
		var usable := curve.size() >= 2
		for value: Variant in curve:
			if not (value is int or value is float) or int(value) <= previous:
				usable = false
				break
			previous = int(value)
			candidate.append(previous)
		if usable and candidate[0] == 0:
			clean["xp_curve"] = candidate
	for key: String in ["crit_base", "crit_per_agility", "speed_per_agility",
			"hp_per_endurance", "mana_per_intelligence", "magic_per_intelligence",
			"control_resist_per_endurance"]:
		var value: Variant = raw.get(key, null)
		if (value is int or value is float) and float(value) >= 0.0:
			clean[key] = float(value)
	return clean


func _int_setting(key: String, fallback: int) -> int:
	var raw: Variant = _progression().get(key, fallback)
	return int(raw) if (raw is int or raw is float) else fallback


func _float_setting(key: String, fallback: float) -> float:
	var raw: Variant = _progression().get(key, fallback)
	return float(raw) if (raw is int or raw is float) else fallback


func max_level() -> int:
	return _int_setting("max_level", 20)


func points_per_level() -> int:
	return _int_setting("points_per_level", 2)


## Skill points granted per level-up (spec §16.1). Independent of the attribute
## pool: a level gives both, and neither pool can pay for the other's purchase.
func skill_points_per_level() -> int:
	return _int_setting("skill_points_per_level", 1)


func xp_curve() -> Array:
	return _progression().get("xp_curve", []) as Array


## XP still needed at `level_at`. The curve stores TOTAL xp per level, so the
## requirement of a level is the difference of two neighbouring entries.
func xp_needed_for(level_at: int) -> int:
	var curve := xp_curve()
	if curve.size() < 2:
		return 100
	var index := clampi(level_at, 1, curve.size() - 1)
	return maxi(1, int(curve[index]) - int(curve[index - 1]))


func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	var level_cap := max_level()
	xp += amount
	var leveled := false
	while xp >= xp_to_next and level < level_cap:
		xp -= xp_to_next
		level += 1
		attribute_points += points_per_level()
		skill_points += skill_points_per_level()
		xp_to_next = xp_needed_for(level)
		leveled = true
		EventBus.toast.emit("Уровень %d" % level)
	# At the cap the bar stays full and nothing more is banked: there is no
	# level, and therefore no point grant, past it.
	if level >= level_cap:
		xp = mini(xp, xp_to_next)
	recompute_derived()
	if leveled:
		hp = max_hp
		mana = max_mana
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


## Attack as the game sees it: the recomputed base (which already contains the
## strength bonus) plus the equipment. Everything equipment-derived goes through
## `total_bonus()`, which walks the slots and reads the data, so equipping,
## unequipping and re-equipping cannot double anything: the number is rebuilt
## from the slots, never accumulated onto a previous value.
func total_attack() -> int:
	return base_attack + total_bonus("attack")


func total_defense() -> int:
	return base_defense + total_bonus("defense")


## The single aggregation helper behind every equipment total. Sums one numeric
## item field (`attack`, `defense`, `speed_bonus`, `resist_bonus`) over the items
## currently worn, in `EQUIPMENT_SLOTS` order, plus the permanent smith upgrade of
## the same stat for the same item (`item_upgrades`, spec §14.4).
##
## An id that is no longer in the data contributes 0 instead of failing the load,
## and a non-numeric field contributes 0 instead of throwing, so a hand-edited
## item cannot take combat down with it. An item contributes once per slot it
## occupies, which is why `equip()` refuses to wear the same item twice — and the
## upgrade term is read from the dictionary rather than accumulated anywhere, so
## the same tempering is counted once per worn item and never twice.
func total_bonus(stat: String) -> int:
	var total := 0
	for slot: String in EQUIPMENT_SLOTS:
		var item_id: String = String(equipment.get(slot, ""))
		if item_id == "":
			continue
		var raw: Variant = ItemDB.get_item(item_id).get(stat, 0)
		if raw is int or raw is float:
			total += int(raw)
		total += upgrade_bonus(item_id, stat)
	return total


## The permanent upgrade one item carries for one stat (spec §14.4), or 0 when it
## was never upgraded or the block does not name this stat. A hand-edited
## non-number reads as 0 rather than poisoning the total.
func upgrade_bonus(item_id: String, stat: String) -> int:
	var block: Variant = item_upgrades.get(item_id, null)
	if not (block is Dictionary):
		return 0
	var raw: Variant = (block as Dictionary).get(stat, 0)
	return int(raw) if (raw is int or raw is float) else 0


## Whether one item already carries this upgrade stat. `CraftManager` asks this
## before it charges anything, so the refusal is a decision made up front rather
## than a half-applied tempering discovered afterwards.
func has_item_upgrade(item_id: String, stat: String) -> bool:
	var block: Variant = item_upgrades.get(item_id, null)
	return block is Dictionary and (block as Dictionary).has(stat)


## Records a permanent upgrade block on one item (spec §14.4) and recomputes what
## the bonus feeds. All-or-nothing: the block is refused, writing nothing, when
## the item already carries any of its stats or any value is not a positive
## number. That refusal is the idempotency gate — the same tempering cannot be
## applied twice, so a repeated craft can never stack the bonus — and it is why
## the bonus is stored as a value rather than as a counter of crafts.
func apply_item_upgrade(item_id: String, block: Dictionary) -> bool:
	if item_id == "" or block.is_empty():
		return false
	var entry: Dictionary = {}
	var current: Variant = item_upgrades.get(item_id, null)
	if current is Dictionary:
		entry = (current as Dictionary).duplicate(true)
	for stat: String in block:
		var raw: Variant = block[stat]
		if not (raw is int or raw is float) or int(raw) < 1:
			return false
		if entry.has(stat):
			return false
	for stat: String in block:
		entry[stat] = int(entry.get(stat, 0)) + int(block[stat])
	item_upgrades[item_id] = entry
	recompute_derived()
	EventBus.equipment_changed.emit()
	return true


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


## Wears an item into the slot its data names (spec §7.3). The rules:
## - only an item that exists in the data, is typed `equipment` and is present in
##   the inventory can be worn, and wearing never consumes it — the previously
##   worn item of the same slot simply stops being worn while it stays in the
##   inventory, so the swap is always reversible;
## - an `accessory` item takes the first free accessory slot, and when both are
##   worn it replaces `accessory_1`;
## - any other slot named in the data must be one of `EQUIPMENT_SLOTS`, so a
##   hand-edited slot name is refused instead of quietly creating a seventh slot
##   that nothing aggregates;
## - wearing an item that is already worn changes nothing and still succeeds,
##   which is what keeps one ring from landing in both accessory slots and being
##   counted twice;
## - an item whose data names attribute `requires` is refused until the matching
##   attribute reaches the required value (spec §7.3), so a spear or a ring is
##   gated behind investment rather than picked up at the starting 5/5/5/5.
##   `equip_blocker()` returns the human-readable reason for the refusal.
func equip(item_id: String) -> bool:
	# `equip_blocker()` is the single gate: an empty blocker already proved the
	# item is equipment, is carried, fits one of the six slots and meets every
	# attribute requirement (or is already worn), so the only work left is the
	# already-worn no-op check and the write. Routing both through one function is
	# what keeps the HUD's reason and the actual refusal from ever disagreeing.
	if equip_blocker(item_id) != "":
		return false
	if equipped_slot_of(item_id) != "":
		return true
	var target := _equipment_slot_for(item_id)
	equipment[target] = item_id
	recompute_derived()
	EventBus.equipment_changed.emit()
	EventBus.toast.emit("Надето: %s" % ItemDB.display_name(item_id))
	return true


## Why `equip(item_id)` would refuse right now, or "" when it would succeed
## (spec §7.3 attribute requirements). The HUD reads this to toast the exact
## reason ("Нужна сила 7 (у вас 5)") instead of a generic failure, and it is the
## one source of truth the equip gate itself consults, so the two cannot drift
## apart about what is equippable. The checks run in the same order equip() does:
## unknown item, not equipment, not carried, already worn (a success), a slot the
## game does not have, then the attribute requirements.
func equip_blocker(item_id: String) -> String:
	if ItemDB.get_item(item_id).is_empty():
		return "Предмет не найден"
	if not ItemDB.is_equipment(item_id):
		return "Нельзя надеть"
	if count_item(item_id) <= 0:
		return "Сначала подберите предмет"
	if equipped_slot_of(item_id) != "":
		return ""
	if _equipment_slot_for(item_id) == "":
		return "Нет подходящего слота"
	var requirements := ItemDB.requirements(item_id)
	for attr_name: String in requirements:
		var raw: Variant = requirements[attr_name]
		var required := int(raw) if (raw is int or raw is float) else 0
		if attribute(attr_name) < required:
			var phrase := String(ATTRIBUTE_REQUIRE_PHRASES.get(attr_name, attr_name))
			return "%s %d (у вас %d)" % [phrase, required, attribute(attr_name)]
	return ""


## Clears an equipment slot (any of `EQUIPMENT_SLOTS`). Returns true only when
## something was actually equipped there; an empty or unknown slot is a no-op.
## The item stays in the inventory (equip never consumes it), so unequipping is
## always reversible.
func unequip(slot: String) -> bool:
	if not EQUIPMENT_SLOTS.has(slot):
		return false
	var current: String = String(equipment.get(slot, ""))
	if current == "":
		return false
	equipment[slot] = ""
	recompute_derived()
	EventBus.equipment_changed.emit()
	EventBus.toast.emit("Снято: %s" % ItemDB.display_name(current))
	return true


## The concrete slot an item belongs in, or "" when the slot named by its data is
## not one of the six. An `accessory` resolves to the first free accessory slot
## and falls back to `accessory_1` when both are worn, so the data never has to
## know that there are two of them.
func _equipment_slot_for(item_id: String) -> String:
	var data_slot := ItemDB.equipment_slot(item_id)
	if data_slot == ACCESSORY_DATA_SLOT:
		for accessory_slot: String in ACCESSORY_SLOTS:
			if String(equipment.get(accessory_slot, "")) == "":
				return accessory_slot
		return String(ACCESSORY_SLOTS[0])
	return data_slot if EQUIPMENT_SLOTS.has(data_slot) else ""


## The slot an item is currently worn in, or "" when it is not worn. The HUD reads
## this for both the `[надето]` marker and the equip/unequip toggle, so an
## accessory in either of the two accessory slots behaves like any other slot.
func equipped_slot_of(item_id: String) -> String:
	if item_id == "":
		return ""
	for slot: String in EQUIPMENT_SLOTS:
		if String(equipment.get(slot, "")) == item_id:
			return slot
	return ""


## How many of the six slots are currently worn.
func equipped_count() -> int:
	var count := 0
	for slot: String in EQUIPMENT_SLOTS:
		if String(equipment.get(slot, "")) != "":
			count += 1
	return count


## A fresh, empty set of the six slots. Static so the member initializer, reset()
## and the save restore all build the same shape.
static func _default_equipment() -> Dictionary:
	var slots: Dictionary = {}
	for slot: String in EQUIPMENT_SLOTS:
		slots[slot] = ""
	return slots


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


# --- skills -------------------------------------------------------------------

func _default_known_skills() -> Array[String]:
	return ["fire_bolt", "ice_bolt", "shock", "heal_impulse"]


func _default_selected_skill() -> String:
	return "fire_bolt"


## Selects the skill the right mouse button casts. Only a skill the player both
## knows and that exists in the data can be selected.
func select_skill(skill_id: String) -> bool:
	if not known_skills.has(skill_id):
		return false
	if not SkillDB.has_skill(skill_id):
		return false
	selected_skill = skill_id
	EventBus.skill_selected.emit(skill_id)
	return true


## Adds a skill to the known list, spending one skill point (spec §16.1). The
## checks run in this order so a refusal never spends anything: an id that is not
## in the data is refused, a skill already known is refused (idempotent, and it
## must not burn a point on something already owned), and only then an empty pool
## is refused. A successful learn is the only path that decrements `skill_points`.
func learn_skill(skill_id: String) -> bool:
	if not SkillDB.has_skill(skill_id):
		return false
	if known_skills.has(skill_id):
		return false
	if skill_points <= 0:
		return false
	skill_points -= 1
	known_skills.append(skill_id)
	return true


# --- zone ---------------------------------------------------------------------

## Records which zone the player stands in. Only an id declared in
## `data/zones.json` is accepted: an unknown one is refused and changes nothing,
## so a typo in a save or a call from a stale exit can never leave the run
## pointing at a zone that has no script, no name and no way back.
func set_zone(zone_id: String) -> bool:
	if not _zone_ids_known().has(zone_id):
		return false
	zone = zone_id
	return true


## Whether `zone_id` names a declared zone.
func has_zone(zone_id: String) -> bool:
	return _zone_ids_known().has(zone_id)


## The ids of `data/zones.json`, loaded once and cached. Read defensively: a
## missing file, unparseable JSON or a `zones` block that is not an object each
## leave the list empty rather than throwing, and the empty list simply refuses
## every zone — which is the same outcome as the default zone, not a crash.
func _zone_ids_known() -> Array[String]:
	if _zones_loaded:
		return _zone_ids
	_zones_loaded = true
	_zone_ids = []
	if not FileAccess.file_exists(ZONES_PATH):
		push_error("GameState: missing %s" % ZONES_PATH)
		return _zone_ids
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ZONES_PATH))
	if not (parsed is Dictionary):
		push_error("GameState: cannot parse %s" % ZONES_PATH)
		return _zone_ids
	var zones: Variant = (parsed as Dictionary).get("zones", {})
	if not (zones is Dictionary):
		push_error("GameState: %s has no 'zones' object" % ZONES_PATH)
		return _zone_ids
	for raw_id: Variant in (zones as Dictionary):
		if raw_id is String and String(raw_id) != "" and not _zone_ids.has(String(raw_id)):
			_zone_ids.append(String(raw_id))
	return _zone_ids


## A save written before zones existed has no `zone` key, and a hand-edited one
## may name a zone the table no longer declares, so anything unusable restores
## the default rather than failing the load.
func _restore_zone(raw: Variant) -> String:
	if raw is String and _zone_ids_known().has(String(raw)):
		return String(raw)
	return DEFAULT_ZONE


# --- flags / counters ---------------------------------------------------------

func set_flag(key: String, value: Variant = true) -> void:
	flags[key] = value


func get_flag(key: String, fallback: Variant = false) -> Variant:
	return flags.get(key, fallback)


func register_kill(enemy_type: String) -> void:
	kills[enemy_type] = int(kills.get(enemy_type, 0)) + 1


func kill_count(enemy_type: String) -> int:
	return int(kills.get(enemy_type, 0))


# --- dialogue read-set (spec §12.2 fast-skip) ---------------------------------

## Records that one dialogue node has been seen. `key` is the composed
## `"<dialogue_id>:<node_id>"` the runner builds. Idempotent: a repeat never
## duplicates the entry, so re-walking a conversation cannot grow the array.
func mark_dialogue_read(key: String) -> void:
	if key == "":
		return
	if not dialogue_read.has(key):
		dialogue_read.append(key)


func is_dialogue_read(key: String) -> bool:
	return key != "" and dialogue_read.has(key)


## A save written before dialogues existed has no `dialogue_read` key, and a
## hand-edited one may hold anything, so the array is rebuilt entry by entry:
## only non-empty strings survive, duplicates are dropped, and a non-array (or a
## missing key) falls back to empty rather than failing the load.
func _restore_dialogue_read(raw: Variant) -> Array[String]:
	var restored: Array[String] = []
	if not (raw is Array):
		return restored
	for value: Variant in (raw as Array):
		if value is String and String(value) != "" and not restored.has(String(value)):
			restored.append(String(value))
	return restored


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
		"attributes": attributes.duplicate(true),
		"attribute_points": attribute_points,
		"gold": gold,
		"inventory": inventory.duplicate(true),
		"equipment": equipment.duplicate(true),
		"item_upgrades": item_upgrades.duplicate(true),
		"quick_slots": quick_slots.duplicate(),
		"known_skills": known_skills.duplicate(),
		"selected_skill": selected_skill,
		"skill_points": skill_points,
		"flags": flags.duplicate(true),
		"kills": kills.duplicate(true),
		"play_time_ms": play_time_ms,
		"dialogue_read": dialogue_read.duplicate(),
		"zone": zone,
	}


func from_dict(d: Dictionary) -> void:
	level = clampi(int(d.get("level", 1)), 1, max_level())
	xp_to_next = xp_needed_for(level)
	xp = clampi(int(d.get("xp", 0)), 0, xp_to_next)
	attributes = _restore_attributes(d.get("attributes", null))
	attribute_points = _restore_attribute_points(d.get("attribute_points", null))
	# The saved maxima are read only as the ceiling the saved pools were written
	# against. recompute_derived() at the end replaces them with the authoritative
	# ones and pulls the pools back under them, so a save whose hp sits above the
	# recomputed maximum cannot load a player with more HP than he owns.
	max_hp = int(d.get("max_hp", HP_BASE))
	hp = clampi(int(d.get("hp", max_hp)), 1, max_hp)
	max_mana = int(d.get("max_mana", MANA_BASE))
	mana = clampi(int(d.get("mana", max_mana)), 0, max_mana)
	base_defense = int(d.get("base_defense", 0))
	gold = int(d.get("gold", 0))
	inventory.clear()
	for slot in d.get("inventory", []):
		if slot is Dictionary and slot.has("id"):
			inventory.append({"id": String(slot["id"]), "amount": int(slot.get("amount", 1))})
	equipment = _restore_equipment(d.get("equipment", null))
	item_upgrades = _restore_item_upgrades(d.get("item_upgrades", null))
	quick_slots = _restore_quick_slots(d.get("quick_slots", null))
	# Skills are tolerant of a missing key (saves written before spec §9) and of
	# unknown ids (a skill removed from the data), so no schema bump is needed.
	known_skills = _restore_known_skills(d.get("known_skills", null))
	selected_skill = _restore_selected_skill(d.get("selected_skill", null), known_skills)
	skill_points = _restore_skill_points(d.get("skill_points", null))
	flags = d.get("flags", {}).duplicate(true)
	kills = d.get("kills", {}).duplicate(true)
	play_time_ms = int(d.get("play_time_ms", 0))
	dialogue_read = _restore_dialogue_read(d.get("dialogue_read", null))
	zone = _restore_zone(d.get("zone", null))
	recompute_derived()
	_emit_all()


## Equipment grew from the two slots the first slice had to the six of spec §7.3,
## and a save written before the growth only carries `weapon` and `armor`. Every
## slot is restored on its own: a slot the save does not mention comes back as an
## empty string rather than staying missing, so the loaded dictionary always holds
## exactly the six keys `total_bonus()` walks, while the values the old save did
## have survive untouched. A key that is not one of the six is dropped instead of
## carried, because nothing aggregates it. That is why no schema bump is needed:
## the old shape is a strict subset of the new one.
func _restore_equipment(raw: Variant) -> Dictionary:
	var restored := _default_equipment()
	if not (raw is Dictionary):
		return restored
	var block: Dictionary = raw as Dictionary
	for slot: String in EQUIPMENT_SLOTS:
		var value: Variant = block.get(slot, "")
		if value is String and String(value) != "":
			restored[slot] = String(value)
	return restored


## A save written before the smith existed has no `item_upgrades` key at all, and
## a hand-edited one may hold anything, so the block is rebuilt entry by entry:
## an item id with no dictionary behind it, a stat that is not a number and a
## bonus that does not raise the stat are each dropped on their own while the
## good entries in the same save survive. Nothing is clamped upward here — the
## recipes are the only thing that should ever write a bonus, and a save is
## allowed to carry a tempering the current data no longer offers.
func _restore_item_upgrades(raw: Variant) -> Dictionary:
	var restored: Dictionary = {}
	if not (raw is Dictionary):
		return restored
	var block: Dictionary = raw as Dictionary
	for raw_id: Variant in block:
		var item_id := String(raw_id)
		var entry: Variant = block[raw_id]
		if item_id == "" or not (entry is Dictionary):
			continue
		var clean: Dictionary = {}
		var stats: Dictionary = entry as Dictionary
		for raw_stat: Variant in stats:
			var stat := String(raw_stat)
			var value: Variant = stats[raw_stat]
			if stat == "" or not (value is int or value is float) or int(value) < 1:
				continue
			clean[stat] = int(value)
		if not clean.is_empty():
			restored[item_id] = clean
	return restored


## A save written before the attributes existed has no such key, and a
## hand-edited one may hold anything, so every key is restored on its own: a bad
## value falls back to the starting 5 rather than dropping the whole block (and a
## good value in the same block survives).
func _restore_attributes(raw: Variant) -> Dictionary:
	var restored := _default_attributes()
	if not (raw is Dictionary):
		return restored
	var block: Dictionary = raw as Dictionary
	for attr_name: String in ATTRIBUTE_NAMES:
		var value: Variant = block.get(attr_name, BASE_ATTRIBUTE)
		if not (value is int or value is float):
			continue
		var points := int(value)
		if points < 1 or points > MAX_ATTRIBUTE:
			continue
		restored[attr_name] = points
	return restored


## The point pool is a plain counter, but a save could carry a negative or an
## absurd number, both of which would let a player spend points he never earned.
func _restore_attribute_points(raw: Variant) -> int:
	if not (raw is int or raw is float):
		return 0
	return clampi(int(raw), 0, MAX_ATTRIBUTE * ATTRIBUTE_NAMES.size())


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


## A save may list a skill id that no longer exists in the data, or hold a
## hand-edited junk array. Anything that is not a known skill id is dropped; an
## empty result falls back to the default loadout rather than a skill-less player.
func _restore_known_skills(raw: Variant) -> Array[String]:
	var restored: Array[String] = []
	if raw is Array:
		for value: Variant in (raw as Array):
			if value is String:
				var id := String(value)
				if SkillDB.has_skill(id) and not restored.has(id):
					restored.append(id)
	if restored.is_empty():
		return _default_known_skills()
	return restored


## The selection must point at a skill the restored player actually knows; an
## unknown or unlearned selection falls back to the first known skill.
func _restore_selected_skill(raw: Variant, known: Array[String]) -> String:
	if raw is String:
		var id := String(raw)
		if known.has(id):
			return id
	return known[0] if not known.is_empty() else _default_selected_skill()


## A save written before skill points existed has no `skill_points` key, so it
## falls back to the starting pool rather than leaving an old player unable to
## learn anything; a hand-edited negative or absurd number is clamped into range
## so a save cannot mint points the player never earned.
func _restore_skill_points(raw: Variant) -> int:
	if not (raw is int or raw is float):
		return STARTING_SKILL_POINTS
	return clampi(int(raw), 0, MAX_SKILL_POINTS)
