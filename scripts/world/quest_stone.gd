class_name QuestStone
extends Area2D
## A quest giver that is not a person: a standing stone with a task carved into it.
##
## `Npc` is deliberately not the base here. That class is a villager — it owns a
## face, a name label, a speech bubble and a `DialogueRunner` conversation, and it
## reaches the HUD through `open_dialogue_runner()`. A slab of granite has none of
## that, and inheriting it would mean a stone with a floating `!` over it, opening
## a conversation with no speaker. So this is a flat `Area2D` in the `interactable`
## group, built and drawn in code exactly like `ZoneExit`, `Mechanism` and
## `RuinDoor`, and it walks the same legacy quest path those props hand to
## `QuestManager`: `start`, `turn_in`, nothing else. No runner, no scene file, no
## dialogue data — a stone is read, not talked to.
##
## The state names are spelled out below rather than read off `QuestManager` for
## the reason `Mechanism` and `RuinDoor` give for their flag strings: this class is
## reached by `class_name`, so it resolves the autoloads through the main loop
## instead of naming them, and the four states it compares against are the four
## constants of `quest_manager.gd` (`STATE_AVAILABLE`, `STATE_ACTIVE`,
## `STATE_READY`, `STATE_DONE`). Renaming a state there means renaming it here, and
## the ruins-quest group fails loudly if the two ever drift apart.

## The key this stone is known by in data and in save-independent dialogue ids.
## Not a quest id: one stone can carry several quests, which is what `quest_ids`
## is for and what the ruins tablet uses.
@export var stone_id: String = "ruins_tablet"
## The quests this stone offers, in offer order. The first entry is the first one
## handed out, so the order is the zone's quest sequence rather than a label.
@export var quest_ids: Array[String] = []

const STATE_AVAILABLE := "available"
const STATE_ACTIVE := "active"
const STATE_READY := "ready"
const STATE_DONE := "done"

## The two lines the HUD shows under the crosshair. The turn-in wording wins
## whenever it is true, because handing in a finished task is the only thing the
## stone can pay for: a prompt that promised «Прочесть скрижаль» and then paid out
## gold would be a prompt that lied about the action it was offering.
const PROMPT_READ := "Прочесть скрижаль"
const PROMPT_TURN_IN := "Сдать задание"

## The speaker label for the carved lines. A stone has no name, so the object of
## the sentence speaks instead of a person, and the dialogue panel never shows a
## blank or a fake villager name.
const SPEAKER := "Скрижаль"

const COLOR_FRAME := Color(0.22, 0.22, 0.26)
const COLOR_FACE := Color(0.44, 0.44, 0.50)
const COLOR_GLYPH := Color(0.76, 0.66, 0.38)
const COLOR_GLYPH_READY := Color(0.42, 0.78, 0.68)
const COLOR_BASE := Color(0.16, 0.16, 0.19)

## What the carving last showed, so `_process` redraws on a change instead of
## every frame — the same trick `Mechanism` uses for its lever.
var _drawn_ready := false


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("quest_stone")
	# The interactable layer with no mask, exactly like `ZoneExit` and `Mechanism`:
	# the stone reports no overlap to anything, because nothing in the project
	# masks this layer. The shape exists so the area is a real area, not a trigger,
	# and so the player's nearest-interactable scan has something to stand next to.
	collision_layer = 32
	collision_mask = 0
	var shape := CircleShape2D.new()
	shape.radius = 9.0
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	add_child(collision)
	_drawn_ready = _any_ready()


func _process(_delta: float) -> void:
	# A quest finishes while the player is out killing the last skeleton, not while
	# he stands here, so the carving has to watch the state rather than trust that
	# it was read once at spawn.
	var now_ready := _any_ready()
	if now_ready == _drawn_ready:
		return
	_drawn_ready = now_ready
	queue_redraw()


func prompt_text() -> String:
	return PROMPT_TURN_IN if _any_ready() else PROMPT_READ


## The whole quest flow of the stone, in one deterministic order:
##
## 1. hand in the first finished task, because that is what the prompt promised;
## 2. otherwise report the first task still in progress — a second task offered
##    while the first is unfinished would have the stone promise two things at
##    once, and the player could never tell which one the carving was talking
##    about;
## 3. otherwise start the first task still on offer;
## 4. otherwise say nothing new: every task this stone knows about is done.
##
## Every branch ends in exactly one toast of its own, on top of whatever
## `QuestManager` announces for the state change it just made, so the stone always
## answers — including the branches where it refuses to.
func interact(_player: Node) -> void:
	var manager := _autoload("QuestManager")
	if manager == null:
		return
	for quest_id: String in quest_ids:
		if _state_of(manager, quest_id) == STATE_READY:
			var title := _title(manager, quest_id)
			_speak(String(_quest(manager, quest_id).get("turn_in_line", "...")))
			if bool(manager.call("turn_in", quest_id)):
				_toast("Сдано: %s" % title)
			else:
				# Reachable: a `collect` task falls back to active when the item
				# left the bag between the flash and this call, and the stone must
				# not claim a reward it did not hand out.
				_toast("%s не сдано: нужно %s" % [
					title, String(manager.call("objective_target", quest_id))
				])
			return
	for quest_id: String in quest_ids:
		if _state_of(manager, quest_id) == STATE_ACTIVE:
			var current := int(manager.call("progress_of", quest_id))
			var total := int(manager.call("target_count", quest_id))
			_speak("%s: %d из %d. Ещё не готово." % [_title(manager, quest_id), current, total])
			_toast("Скрижаль помнит: %d из %d" % [current, total])
			return
	for quest_id: String in quest_ids:
		if _state_of(manager, quest_id) == STATE_AVAILABLE:
			var title := _title(manager, quest_id)
			_speak(String(_quest(manager, quest_id).get("start_line", "...")))
			var started := bool(manager.call("start", quest_id))
			_toast(("Скрижаль: %s" % title) if started else "Скрижаль молчит")
			return
	_toast("Скрижаль молчит")


func _state_of(manager: Node, quest_id: String) -> String:
	return String(manager.call("state_of", quest_id))


func _quest(manager: Node, quest_id: String) -> Dictionary:
	var quest: Variant = manager.call("get_quest", quest_id)
	return quest if quest is Dictionary else {}


func _title(manager: Node, quest_id: String) -> String:
	return String(_quest(manager, quest_id).get("title", quest_id))


## The carved line, handed to the dialogue panel in the same `{speaker, text}`
## shape an `Npc` hands its spoken lines to, so the HUD needs no new branch to
## show a stone.
func _speak(text: String) -> void:
	var bus := _autoload("EventBus")
	if bus == null:
		return
	bus.emit_signal("dialogue_requested", [{"speaker": SPEAKER, "text": text}])


func _toast(message: String) -> void:
	var bus := _autoload("EventBus")
	if bus == null:
		return
	bus.emit_signal("toast", message)


func _any_ready() -> bool:
	var manager := _autoload("QuestManager")
	if manager == null:
		return false
	for quest_id: String in quest_ids:
		if _state_of(manager, quest_id) == STATE_READY:
			return true
	return false


## A leaning slab with three carved strokes: the frame, the face and the
## inscription. The strokes are brass while the stone still has something to give
## and turn cold green the moment a task is ready to hand in, which is the same
## signal the prompt gives in words. Drawn rather than textured — the slice has no
## tablet sprite, and a drawn placeholder is easier to replace with real art than a
## node wired into a scene file would be.
func _draw() -> void:
	draw_rect(Rect2(-2.0, 6.0, 4.0, 3.0), COLOR_BASE)
	draw_rect(Rect2(-7.0, -14.0, 14.0, 21.0), COLOR_FRAME)
	draw_rect(Rect2(-5.0, -12.0, 10.0, 17.0), COLOR_FACE)
	var glyph := COLOR_GLYPH_READY if _drawn_ready else COLOR_GLYPH
	draw_rect(Rect2(-3.0, -10.0, 6.0, 1.0), glyph)
	draw_rect(Rect2(-3.0, -7.0, 6.0, 1.0), glyph)
	draw_rect(Rect2(-3.0, -4.0, 4.0, 1.0), glyph)
	draw_rect(Rect2(-3.0, -1.0, 6.0, 1.0), glyph)


func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)
