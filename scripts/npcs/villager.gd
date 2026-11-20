class_name Villager
extends Npc
## Third villager — the herbwife "Травница Мила". Unlike the base `Npc` (a single
## quest giver) she hands out several quests, so she overrides the interaction to
## walk her own `quest_ids` list: start the first quest still available, otherwise
## turn in the first one that is ready. The data-driven conversation still runs
## first (spec §12.2); the per-quest lines below are the legacy fallback the runner
## leaves to it — exactly the contract the base `Npc` keeps for Edrik.

## The quests this villager gives, in offer order. Set by `Forest` when it spawns
## her; a bare `Villager` offers nothing and simply chats.
@export var quest_ids: PackedStringArray = PackedStringArray()


func _ready() -> void:
	super()
	# A cool herb tint, distinct from the merchant's blue and the smith's forge
	# orange, so the three code-built villagers read apart on the one shared sprite.
	# Guarded because a bare `Villager` built without the world's sprite has none.
	if sprite != null and is_instance_valid(sprite):
		sprite.modulate = Color(0.66, 0.92, 0.62)


func prompt_text() -> String:
	return "Поговорить"


func interact(player: Node) -> void:
	# Conversation first, mirroring the base Npc: the runner is built with the live
	# state injected, and only consumes the interaction when a HUD can show it.
	var any_ready := false
	for qid: String in quest_ids:
		var s: String = QuestManager.state_of(qid)
		if s == QuestManager.STATE_READY or s == QuestManager.STATE_DONE:
			any_ready = true
			break
	var context := "after_hunt" if any_ready else "intro"
	var runner := DialogueRunner.new(GameState, QuestManager)
	if runner.start("%s_%s" % [speaker_id, context]):
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("open_dialogue_runner"):
			hud.open_dialogue_runner(runner)
			return

	# Fallback: no runner (unknown dialogue, unmet condition, or no HUD). Offer or
	# turn in the first quest in `quest_ids` that has something to say.
	var lines: Array = []
	for qid: String in quest_ids:
		var state: String = QuestManager.state_of(qid)
		var quest: Dictionary = QuestManager.get_quest(qid)
		lines.clear()
		if state == QuestManager.STATE_AVAILABLE:
			lines.append({"speaker": display_name, "text": String(quest.get("start_line", "..."))})
			EventBus.dialogue_requested.emit(lines)
			QuestManager.start(qid)
			return
		if state == QuestManager.STATE_ACTIVE:
			var cur: int = QuestManager.progress_of(qid)
			var total: int = QuestManager.target_count(qid)
			lines.append({
				"speaker": display_name,
				"text": "%s: %d из %d. Ещё не готово." % [String(quest.get("title", "Задание")), cur, total],
			})
			EventBus.dialogue_requested.emit(lines)
			return
		if state == QuestManager.STATE_READY:
			lines.append({"speaker": display_name, "text": String(quest.get("turn_in_line", "..."))})
			EventBus.dialogue_requested.emit(lines)
			QuestManager.turn_in(qid)
			return
	lines.append({"speaker": display_name, "text": "Травы сушатся, а дела подождут."})
	EventBus.dialogue_requested.emit(lines)


## The marker over her head reflects any of her quests: a new one to take ("!") or
## a finished one to hand in ("?"), so the override watches the whole list rather
## than the single `quest_id` the base class tracks.
func _refresh_bubble() -> void:
	if _bubble == null:
		return
	var has_available := false
	for qid: String in quest_ids:
		match QuestManager.state_of(qid):
			QuestManager.STATE_READY:
				_bubble.text = "?"
				_bubble.visible = true
				return
			QuestManager.STATE_AVAILABLE:
				has_available = true
	if has_available:
		_bubble.text = "!"
		_bubble.visible = true
	else:
		_bubble.visible = false
