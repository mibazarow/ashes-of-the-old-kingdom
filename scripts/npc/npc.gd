class_name Npc
extends Area2D
## Quest giver. Turns the quest in exactly once through QuestManager.

const QUEST_ID := "q01_ash_wolves"

@export var display_name: String = "Эдрик"
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
	var quest: Dictionary = QuestManager.get_quest(QUEST_ID)
	var state: String = QuestManager.state_of(QUEST_ID)
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
