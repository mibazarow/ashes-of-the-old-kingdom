class_name Villager
extends Npc
## A code-built villager who hands out several quests. Unlike the base `Npc` (a
## single quest giver) she overrides the interaction to walk her own `quest_ids`
## list. One of those quests is the *spoken* one — the one her data-driven
## conversation grants through its choice effect (spec §12.2) — named by
## `dialogue_quest_id`, or simply the first in the list when she has no separate
## spoken quest. Any other quest she carries (a task moved onto her from the ruin
## stone, so the stone no longer hands out most of the chain) has no dialogue tree
## and runs through the legacy per-quest flow below: the same fallback the base
## `Npc` keeps for Edrik.

## The quests this villager gives, in offer order. Set by the world when it spawns
## her; a bare `Villager` offers nothing and simply chats.
@export var quest_ids: PackedStringArray = PackedStringArray()

## Which of `quest_ids` is carried by the spoken conversation rather than the plain
## quest flow — the quest whose `<speaker>_intro` tree starts it. Left empty for a
## villager whose first quest is the spoken one (the common case); set explicitly
## when a non-dialogue task was added ahead of the spoken quest in `quest_ids`.
@export var dialogue_quest_id: String = ""


func _ready() -> void:
	super()
	# A saturated herb green, distinct from the merchant's deep azure and the
	# smith's charcoal. Each of the three already wears its own sprite from
	# `Actor/Character/` of the Ninja Adventure pack (`npc_mila.png` and the
	# other named-villager sheets); this tint is a deliberate readability
	# treatment on top of real art, not a stand-in for a shared placeholder.
	# Guarded because a bare `Villager` built without the world's sprite has none.
	# This is the identity hue only: the zone's brightness scalar is multiplied
	# into it on the first processed frame by the body pass in `Npc._process`,
	# and a spawning zone script may still paint its own figure tint here after
	# `add_child` — that tint gets scaled the same way (Nela's undercroft grey,
	# Oren's garrison ochre, the village herbwives' per-character pastels).
	if sprite != null and is_instance_valid(sprite):
		sprite.modulate = Color(0.55, 0.95, 0.60)


func prompt_text() -> String:
	return "Поговорить"


func interact(player: Node) -> void:
	# Speaking to this villager is itself the `talk` objective of any quest aimed at
	# this speaker — q07 is a word carried down to Нела, so the conversation with her
	# *is* the errand. Reported before her own quests are read, so a `talk` quest
	# completes on the very conversation the player came to have; quests aimed at any
	# other speaker are untouched.
	QuestManager.notify_npc_talked(speaker_id)

	# The conversation belongs to the one spoken quest of hers. Its context follows
	# that quest alone: an available quest opens her intro (which grants it), a ready
	# or finished one opens the after-hunt line. A quest that is merely active, or a
	# spoken quest still locked behind another, opens no conversation — the plain flow
	# below reports it or offers whichever of her other quests is actionable.
	var spoken := dialogue_quest_id
	if spoken == "" and quest_ids.size() > 0:
		spoken = quest_ids[0]
	var spoken_state := QuestManager.state_of(spoken) if spoken != "" else ""
	var context := ""
	if spoken_state == QuestManager.STATE_READY or spoken_state == QuestManager.STATE_DONE:
		context = "after_hunt"
	elif spoken_state == QuestManager.STATE_AVAILABLE:
		context = "intro"
	if context != "":
		var runner := DialogueRunner.new(GameState, QuestManager)
		if runner.start("%s_%s" % [speaker_id, context]):
			var hud := get_tree().get_first_node_in_group("hud")
			if hud != null and hud.has_method("open_dialogue_runner"):
				hud.open_dialogue_runner(runner)
				return

	# Fallback: no conversation opened (no HUD, an unmet condition, or a quest with no
	# tree of its own). Walk her whole list and do the first thing any quest needs —
	# offer a new one, report progress on an active one, or hand in a finished one.
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
