class_name Npc
extends Area2D
## Quest giver. Turns the quest in exactly once through QuestManager.

const QUEST_ID := "q01_ash_wolves"

@export var display_name: String = "Эдрик"
## Slug that names this character's dialogues in data/dialogue.json: the runner id
## is `"<speaker_id>_<context>"` (spec §12.2). It is a stable ASCII key, kept
## separate from the Cyrillic `display_name` so renaming the label never orphans
## the conversation data.
@export var speaker_id: String = "edrik"
@export var sprite_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D

var _bubble: Label


func _ready() -> void:
	add_to_group("interactable")
	if sprite_texture != null:
		sprite.texture = sprite_texture
	_bubble = Label.new()
	_bubble.text = "!"
	_bubble.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_bubble.add_theme_font_size_override("font_size", 8)
	_bubble.position = Vector2(-2, -24)
	add_child(_bubble)
	EventBus.quest_progress.connect(_on_quest_progress)
	EventBus.quest_completed.connect(_on_quest_completed)
	_refresh_bubble()


func prompt_text() -> String:
	return "Говорить — %s" % display_name


func interact(_player: Node) -> void:
	# Data-driven conversation first (spec §12.2). The context picks the dialogue:
	# the after-hunt line once the hunt is over, the intro otherwise. The runner is
	# built with the live state injected rather than reading the autoloads inside,
	# so the same object the test constructs is the one the game uses.
	var state: String = QuestManager.state_of(QUEST_ID)
	var context := "intro"
	if state == QuestManager.STATE_READY or state == QuestManager.STATE_DONE:
		context = "after_hunt"
	var runner := DialogueRunner.new(GameState, QuestManager)
	if runner.start("%s_%s" % [speaker_id, context]):
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("open_dialogue_runner"):
			hud.open_dialogue_runner(runner)
			return

	# Fallback: the runner refused (unknown dialogue, an unmet condition, or no HUD
	# to show it). The quest turn-in lives here on purpose — edrik_after_hunt is
	# gated on `quest_done`, so while the quest is only `ready` the runner refuses
	# and this path turns it in. This is the path the quest bot relies on.
	var quest: Dictionary = QuestManager.get_quest(QUEST_ID)
	var lines: Array = []

	if state == QuestManager.STATE_AVAILABLE:
		lines.append({"speaker": display_name, "text": String(quest.get("start_line", "..."))})
		EventBus.dialogue_requested.emit(lines)
		QuestManager.start(QUEST_ID)
		return
	if state == QuestManager.STATE_ACTIVE:
		var cur: int = QuestManager.progress_of(QUEST_ID)
		var total: int = QuestManager.target_count(QUEST_ID)
		lines.append({
			"speaker": display_name,
			"text": "Волки ещё живы: %d из %d. Опушка ждёт." % [cur, total],
		})
		EventBus.dialogue_requested.emit(lines)
		return
	if state == QuestManager.STATE_READY:
		lines.append({"speaker": display_name, "text": String(quest.get("turn_in_line", "..."))})
		EventBus.dialogue_requested.emit(lines)
		QuestManager.turn_in(QUEST_ID)
		return

	lines.append({"speaker": display_name, "text": "Деревня дышит ровнее. Спасибо."})
	EventBus.dialogue_requested.emit(lines)


func _refresh_bubble() -> void:
	var state: String = QuestManager.state_of(QUEST_ID)
	match state:
		QuestManager.STATE_AVAILABLE:
			_bubble.text = "!"
			_bubble.visible = true
		QuestManager.STATE_READY:
			_bubble.text = "?"
			_bubble.visible = true
		_:
			_bubble.visible = false


func _on_quest_progress(_id: StringName, _c: int, _t: int) -> void:
	_refresh_bubble()


func _on_quest_completed(_id: StringName) -> void:
	_refresh_bubble()
