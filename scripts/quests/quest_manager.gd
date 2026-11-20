extends Node
## Quest definitions + runtime state. Reward payout is idempotent by design.

const PATH := "res://data/quests.json"
const STATE_AVAILABLE := "available"
const STATE_ACTIVE := "active"
const STATE_READY := "ready"
const STATE_DONE := "done"

var quests: Dictionary = {}
var states: Dictionary = {}


func _ready() -> void:
	_load_definitions()
	EventBus.enemy_died.connect(_on_enemy_died)
	# A `collect` objective tracks the live inventory, not a kill counter, so the
	# only honest moment to recompute it is whenever the bag changes. `kill`
	# objectives ignore the signal (their progress is a stored counter), so wiring
	# this here cannot disturb the existing hunt quest.
	EventBus.inventory_changed.connect(_recompute_collect_progress)


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
	var s: Variant = states.get(quest_id, {})
	if s is Dictionary:
		return String(s.get("state", STATE_AVAILABLE))
	return STATE_AVAILABLE


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


## True only while a `collect` quest is being tracked (not finished): that is the
## window in which its progress is derived from the inventory rather than stored.
func _is_collect_tracking(quest_id: String) -> bool:
	if not _is_collect(quest_id):
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
	# A `collect` quest is paid for with items, so the bag is re-checked at the
	# counter: if the player dropped or spent the required amount since the goal
	# flashed ready, the turn-in is refused and the quest falls back to active
	# rather than paying out for nothing.
	var required := 0
	if _is_collect(quest_id):
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


func from_dict(d: Dictionary) -> void:
	states = d.duplicate(true)


func reset() -> void:
	states = {}
