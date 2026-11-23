extends Node
## Quest definitions + runtime state. Reward payout is idempotent by design.

const PATH := "res://data/quests.json"
const STATE_AVAILABLE := "available"
const STATE_ACTIVE := "active"
const STATE_READY := "ready"
const STATE_DONE := "done"
## A quest the player is not allowed to take yet. The state is DERIVED, never
## stored: it is what `available` would have been while an entry in `requires` is
## still unfinished or `min_level` has not been reached. Nothing writes it into
## `states`, so a save carries no lock and a quest can never be un-locked by
## editing a save file, and a quest already in progress keeps its stored state no
## matter what happens to the quests it was gated on.
const STATE_LOCKED := "locked"

var quests: Dictionary = {}
var states: Dictionary = {}

## The last measured lock state of every quest id, so the moment a gate lifts can
## be announced exactly once. Rebuilt wholesale on load, save and reset — those
## three are the only ways the world can change under us without a signal.
var _was_locked: Dictionary = {}


func _ready() -> void:
	_load_definitions()
	EventBus.enemy_died.connect(_on_enemy_died)
	# A `collect` objective tracks the live inventory, not a kill counter, so the
	# only honest moment to recompute it is whenever the bag changes. `kill`
	# objectives ignore the signal (their progress is a stored counter), so wiring
	# this here cannot disturb the existing hunt quest.
	EventBus.inventory_changed.connect(_recompute_collect_progress)
	# The two events a gate can hinge on: finishing the quest another quest
	# `requires`, and reaching the `min_level` one asks for. Both are checked by
	# `_announce_unlocks`, which compares against the snapshot rather than
	# listening for an "unlocked" event, because there is no such event — a lock is
	# a derived state, and a derived state only changes when one of its inputs
	# does. `_snapshot_locks` runs last so the snapshot is taken against the world
	# as loaded, not against an empty `states` that would make a loaded game
	# announce quests the player already had.
	EventBus.quest_completed.connect(_on_quest_completed)
	EventBus.player_xp_changed.connect(_on_player_xp_changed)
	_snapshot_locks()


## Records the lock state of every defined quest without announcing anything. The
## baseline the next `_announce_unlocks` compares against.
func _snapshot_locks() -> void:
	_was_locked = {}
	for quest_id: String in quests.keys():
		_was_locked[quest_id] = is_locked(quest_id)


func _on_quest_completed(_quest_id: StringName) -> void:
	_announce_unlocks()


func _on_player_xp_changed(_current: int, _needed: int, _level: int) -> void:
	_announce_unlocks()


## Announces the quests whose gate lifted since the last measurement. A quest that
## was never offered to the player and is now offerable is otherwise invisible:
## the journal only lists taken quests, and the giver who holds it is in a zone the
## player has no reason to walk back into. The toast is the only hint the game
## gives that content the player could not reach an hour ago is now reachable, so
## it names the quest and the place it is handed out.
func _announce_unlocks() -> void:
	for quest_id: String in quests.keys():
		var now_locked := is_locked(quest_id)
		var was_locked := bool(_was_locked.get(quest_id, false))
		_was_locked[quest_id] = now_locked
		if was_locked and not now_locked:
			var quest: Dictionary = get_quest(quest_id)
			var title := String(quest.get("title", quest_id))
			var where := String(quest.get("where", ""))
			EventBus.toast.emit("Доступно задание: %s%s"
				% [title, (" — " + where) if where != "" else ""])
			Telemetry.event(&"quest_unlocked", {"quest_id": quest_id})


func _load_definitions() -> void:
	if not FileAccess.file_exists(PATH):
		push_error("QuestManager: missing %s" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if parsed is Dictionary:
		quests = parsed.get("quests", {})
	else:
		push_error("QuestManager: cannot parse %s" % PATH)


func get_quest(quest_id: String) -> Dictionary:
	var q: Variant = quests.get(quest_id, {})
	return q if q is Dictionary else {}


func state_of(quest_id: String) -> String:
	# `null` rather than `{}` as the miss sentinel: an empty Dictionary passes an
	# `is Dictionary` test, so defaulting to one would make every untaken quest read
	# as a stored one and quietly bypass the gate below.
	var s: Variant = states.get(quest_id, null)
	if s is Dictionary:
		return String(s.get("state", STATE_AVAILABLE))
	return STATE_AVAILABLE if _gates_met(quest_id) else STATE_LOCKED


## True when nothing stands between the player and taking this quest: every quest
## listed in `requires` is finished, and the level is at or above `min_level`.
## A quest with no definition reports true on purpose — it has no gates to fail,
## and `start()` is the one that refuses an unknown id, so that refusal stays the
## single place an undefined quest is turned away.
func _gates_met(quest_id: String) -> bool:
	var quest: Dictionary = get_quest(quest_id)
	if quest.is_empty():
		return true
	var requirements: Variant = quest.get("requires", [])
	if requirements is Array:
		for requirement: Variant in requirements:
			if not is_done(String(requirement)):
				return false
	return GameState.level >= int(quest.get("min_level", 1))


## True while a quest that has not been taken yet is still behind a gate. A quest
## already in progress, ready or finished is never locked: the gate governs taking,
## not keeping, so a quest cannot be revoked from a player who has it.
func is_locked(quest_id: String) -> bool:
	return state_of(quest_id) == STATE_LOCKED


## Why the player cannot take this quest yet, in the player's own words, or an
## empty string when nothing is missing. The givers do not ask this — they simply
## stop offering a locked quest, because their offer loops match on the four
## offerable states and `locked` is not one of them — but a direct `start()` does,
## and so does anything that wants to explain a refusal instead of staying silent.
func locked_reason(quest_id: String) -> String:
	var quest: Dictionary = get_quest(quest_id)
	if quest.is_empty():
		return ""
	var requirements: Variant = quest.get("requires", [])
	if requirements is Array:
		for requirement: Variant in requirements:
			var missing := String(requirement)
			if not is_done(missing):
				var missing_title := String(get_quest(missing).get("title", missing))
				return "Сначала нужно выполнить: %s" % missing_title
	var min_level := int(quest.get("min_level", 1))
	if GameState.level < min_level:
		return "Нужен уровень %d" % min_level
	return ""


func progress_of(quest_id: String) -> int:
	# A `collect` quest reads its progress straight from the bag, so the journal,
	# the turn-in gate and a save round-trip all agree with what the player is
	# actually carrying. A `kill` quest keeps its stored counter. A finished quest
	# reports its stored (completed) progress rather than the drained bag.
	if _is_collect_tracking(quest_id):
		return mini(target_count(quest_id), GameState.count_item(_collect_target(quest_id)))
	var s: Variant = states.get(quest_id, {})
	if s is Dictionary:
		return int(s.get("progress", 0))
	return 0


func objective_type(quest_id: String) -> String:
	var obj: Dictionary = get_quest(quest_id).get("objective", {})
	return String(obj.get("type", ""))


func objective_target(quest_id: String) -> String:
	var obj: Dictionary = get_quest(quest_id).get("objective", {})
	return String(obj.get("target", ""))


func _is_collect(quest_id: String) -> bool:
	return objective_type(quest_id) == "collect"


## The two objective types whose progress is the live bag rather than a stored
## counter. `collect` is "amass N of an item for the giver"; `deliver` is "carry N
## of an item to the giver" — the same bag read, because handing goods to the very
## NPC who holds the quest is exactly what the giver turn-in already does, and both
## spend the items on hand-over. They stay distinct type strings so the journal and
## the objective vocabulary can tell an errand from a haul.
func _is_bag_tracking(quest_id: String) -> bool:
	var t := objective_type(quest_id)
	return t == "collect" or t == "deliver"


## True only while a bag-tracked quest (`collect` or `deliver`) is being tracked
## (not finished): that is the window in which its progress is derived from the
## inventory rather than stored.
func _is_collect_tracking(quest_id: String) -> bool:
	if not _is_bag_tracking(quest_id):
		return false
	var state: String = state_of(quest_id)
	return state == STATE_ACTIVE or state == STATE_READY


func _collect_target(quest_id: String) -> String:
	return objective_target(quest_id)



func target_count(quest_id: String) -> int:
	var obj: Dictionary = get_quest(quest_id).get("objective", {})
	return int(obj.get("count", 0))


func is_done(quest_id: String) -> bool:
	return state_of(quest_id) == STATE_DONE


func start(quest_id: String) -> bool:
	if get_quest(quest_id).is_empty():
		return false
	if state_of(quest_id) == STATE_LOCKED:
		# The givers never reach this branch — they skip a locked quest on their
		# way past it — so the only caller that lands here is one that asked for
		# this quest by name. It gets told why in the same words the journal would
		# use, rather than a silent false.
		var reason := locked_reason(quest_id)
		if reason != "":
			EventBus.toast.emit(reason)
			Telemetry.event(&"quest_start_refused",
				{"quest_id": quest_id, "reason": reason})
		return false
	if state_of(quest_id) != STATE_AVAILABLE:
		return false
	states[quest_id] = {"state": STATE_ACTIVE, "progress": 0}
	EventBus.quest_started.emit(StringName(quest_id))
	EventBus.toast.emit("Задание: %s" % String(get_quest(quest_id).get("title", quest_id)))
	EventBus.quest_progress.emit(StringName(quest_id), 0, target_count(quest_id))
	Telemetry.event(&"quest_started", {"quest_id": quest_id})
	return true


func _on_enemy_died(enemy_id: StringName, enemy_type: StringName, _pos: Vector2) -> void:
	var _unused := enemy_id
	for quest_id: String in states.keys():
		if state_of(quest_id) != STATE_ACTIVE:
			continue
		var obj: Dictionary = get_quest(quest_id).get("objective", {})
		if String(obj.get("type", "")) != "kill":
			continue
		if String(obj.get("target", "")) != String(enemy_type):
			continue
		var target := int(obj.get("count", 0))
		var entry: Dictionary = states[quest_id]
		entry["progress"] = mini(target, int(entry.get("progress", 0)) + 1)
		if int(entry["progress"]) >= target:
			entry["state"] = STATE_READY
			EventBus.toast.emit("Цель выполнена: %s" % String(get_quest(quest_id).get("title", quest_id)))
		EventBus.quest_progress.emit(StringName(quest_id), int(entry["progress"]), target)
		Telemetry.event(&"quest_progress", {"quest_id": quest_id, "progress": entry["progress"], "target": target})


## Progress hooks for the objective types that are neither a kill counter nor a bag
## read: `visit` (reach a zone), `talk` (speak to a named speaker) and `use` (trigger
## a world mechanism). Each advances a stored counter by exactly one matching event —
## the same shape `_on_enemy_died` uses for `kill`. The world props call these when
## the thing happens (`Dungeon` reports arrival, `Villager` reports a conversation,
## `Ruins` reports the lever falling), so the quest never polls the world; the world
## tells the quest. Progress is clamped at the target, and a quest that is not
## `active`, or whose type/target does not match the event, is left untouched.
func notify_zone_visited(zone_id: String) -> void:
	_advance_stored_objective("visit", zone_id)


func notify_npc_talked(speaker_id: String) -> void:
	_advance_stored_objective("talk", speaker_id)


func notify_objective_used(object_id: String) -> void:
	_advance_stored_objective("use", object_id)


func _advance_stored_objective(obj_type: String, target: String) -> void:
	for quest_id: String in states.keys():
		if state_of(quest_id) != STATE_ACTIVE:
			continue
		var obj: Dictionary = get_quest(quest_id).get("objective", {})
		if String(obj.get("type", "")) != obj_type:
			continue
		if String(obj.get("target", "")) != target:
			continue
		var count := int(obj.get("count", 0))
		var entry: Dictionary = states[quest_id]
		entry["progress"] = mini(count, int(entry.get("progress", 0)) + 1)
		if int(entry["progress"]) >= count:
			entry["state"] = STATE_READY
			EventBus.toast.emit("Цель выполнена: %s" % String(get_quest(quest_id).get("title", quest_id)))
		EventBus.quest_progress.emit(StringName(quest_id), int(entry["progress"]), count)
		Telemetry.event(&"quest_progress", {"quest_id": quest_id, "progress": entry["progress"], "target": count})


## Re-evaluates every tracked `collect` quest against the live inventory. Runs on
## each `inventory_changed`. Progress is clamped to the target, and the ready flag
## follows the bag in both directions: enough items flips ACTIVE -> READY, dropping
## below the target flips READY -> ACTIVE, so the counter can never claim a goal the
## player no longer holds. `kill` quests are skipped entirely.
func _recompute_collect_progress() -> void:
	for quest_id: String in states.keys():
		if not _is_collect_tracking(quest_id):
			continue
		var obj: Dictionary = get_quest(quest_id).get("objective", {})
		var target := int(obj.get("count", 0))
		var have := mini(target, GameState.count_item(String(obj.get("target", ""))))
		var entry: Dictionary = states[quest_id]
		var prev := int(entry.get("progress", 0))
		var prev_state: String = String(entry.get("state", STATE_ACTIVE))
		entry["progress"] = have
		if have >= target:
			if prev_state != STATE_READY:
				entry["state"] = STATE_READY
				EventBus.toast.emit("Цель выполнена: %s" % String(get_quest(quest_id).get("title", quest_id)))
		elif prev_state == STATE_READY:
			entry["state"] = STATE_ACTIVE
		if have != prev or String(entry.get("state", "")) != prev_state:
			EventBus.quest_progress.emit(StringName(quest_id), have, target)
			Telemetry.event(&"quest_progress", {"quest_id": quest_id, "progress": have, "target": target})



func turn_in(quest_id: String) -> bool:
	if state_of(quest_id) != STATE_READY:
		return false
	# A bag-tracked quest (`collect` or `deliver`) is paid for with items, so the bag
	# is re-checked at the counter: if the player dropped or spent the required amount
	# since the goal flashed ready, the turn-in is refused and the quest falls back to
	# active rather than paying out for nothing.
	var required := 0
	if _is_bag_tracking(quest_id):
		required = target_count(quest_id)
		if GameState.count_item(_collect_target(quest_id)) < required:
			var revert: Dictionary = states.get(quest_id, {})
			revert["state"] = STATE_ACTIVE
			revert["progress"] = progress_of(quest_id)
			states[quest_id] = revert
			return false
		if not GameState.remove_item(_collect_target(quest_id), required):
			return false
	var reward: Dictionary = get_quest(quest_id).get("reward", {})
	# Mark done BEFORE paying: the reward's add_item fires inventory_changed, and
	# the collect recompute must see this quest already finished so it does not
	# re-open a quest that was just completed.
	states[quest_id] = {"state": STATE_DONE, "progress": target_count(quest_id)}
	GameState.add_gold(int(reward.get("gold", 0)))
	GameState.add_xp(int(reward.get("xp", 0)))
	var items: Dictionary = reward.get("items", {})
	for item_id: String in items:
		GameState.add_item(item_id, int(items[item_id]))
	EventBus.quest_completed.emit(StringName(quest_id))
	EventBus.toast.emit("Задание выполнено: %s" % String(get_quest(quest_id).get("title", quest_id)))
	Telemetry.event(&"quest_completed", {"quest_id": quest_id})
	return true



func to_dict() -> Dictionary:
	return states.duplicate(true)


## Restores stored states only. Locks are not saved and are not restored: they are
## recomputed from the restored `states` plus the level, which is why a save cannot
## hold a quest open that the gates have since closed, and why the snapshot is
## retaken here instead of announcing every quest a loaded game already unlocked.
func from_dict(d: Dictionary) -> void:
	states = d.duplicate(true)
	_snapshot_locks()


func reset() -> void:
	states = {}
	_snapshot_locks()
