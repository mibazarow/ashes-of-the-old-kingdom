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
	var s: Variant = states.get(quest_id, {})
	if s is Dictionary:
		return int(s.get("progress", 0))
	return 0


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


func turn_in(quest_id: String) -> bool:
	if state_of(quest_id) != STATE_READY:
		return false
	var reward: Dictionary = get_quest(quest_id).get("reward", {})
	GameState.add_gold(int(reward.get("gold", 0)))
	GameState.add_xp(int(reward.get("xp", 0)))
	var items: Dictionary = reward.get("items", {})
	for item_id: String in items:
		GameState.add_item(item_id, int(items[item_id]))
	states[quest_id] = {"state": STATE_DONE, "progress": target_count(quest_id)}
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
