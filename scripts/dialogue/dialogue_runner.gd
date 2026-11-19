class_name DialogueRunner
extends RefCounted
## Runs one data-driven conversation (spec §12.2) against injected state.
##
## Dependencies arrive through the constructor rather than the autoload globals,
## exactly like ShopManager, so the class compiles under `godot --script` where
## the globals are not yet registered and the test suite can build one directly.
## It owns the cursor into a single dialogue and nothing else: reading a node,
## applying its effects and moving to the next node are the only things it does.
## The HUD renders whatever it reports; the read-set lives on GameState so it
## outlives this throwaway object through a save.

var _game_state: Node = null
var _quest_manager: Node = null
var _dialogue_id: String = ""
var _node_id: String = ""
var _finished := true
var _revealed := false


func _init(game_state: Node = null, quest_manager: Node = null) -> void:
	_game_state = game_state
	_quest_manager = quest_manager


## Opens a dialogue and lands on its start node, honouring the dialogue-level
## condition. Returns false — leaving the runner finished and touching nothing —
## when the dialogue is unknown or its condition is not met. That refusal is what
## lets the NPC fall back to its quest behaviour (the after-hunt line is gated on
## `quest_done`, so it refuses while the quest is only `ready` and the turn-in
## still happens through the legacy path).
func start(dialogue_id: String) -> bool:
	_finished = true
	_node_id = ""
	_dialogue_id = dialogue_id
	var entry := DialogueDB.get_dialogue(dialogue_id)
	if entry.is_empty():
		return false
	if not _condition_met(entry.get("condition", null)):
		return false
	var start_id := String(entry.get("start", ""))
	if start_id == "" or DialogueDB.node(dialogue_id, start_id).is_empty():
		return false
	_finished = false
	_enter_node(start_id)
	return true


func dialogue_id() -> String:
	return _dialogue_id


func current_node_id() -> String:
	return _node_id


func current_node() -> Dictionary:
	if _finished:
		return {}
	return DialogueDB.node(_dialogue_id, _node_id)


## Who is speaking the current line: a node's own `speaker` when it names one,
## otherwise the dialogue-level `speaker`.
func current_speaker() -> String:
	var speaker := String(current_node().get("speaker", ""))
	if speaker != "":
		return speaker
	return String(DialogueDB.get_dialogue(_dialogue_id).get("speaker", ""))


## The current node's options, or an empty Array when it offers none.
func current_options() -> Array:
	var raw: Variant = current_node().get("options", [])
	return raw if raw is Array else []


func is_finished() -> bool:
	return _finished


## Advances a node that offers no choices to its `next`. Returns the new node id,
## or "" when the conversation ended (empty or unknown next). A node that DOES
## offer choices is not advanced here — the caller must choose() — so this is a
## no-op returning "" for it, which the HUD never treats as an end because it
## checks current_options() first.
func advance() -> String:
	if _finished or not current_options().is_empty():
		return ""
	return _move_to(String(current_node().get("next", "")))


## Picks option `index` on the current node: applies the option's effects, then
## moves to its `next`. Returns {ok, next, effects}. An out-of-range index, or a
## choice on a node without options, is refused with ok=false and changes nothing.
func choose(index: int) -> Dictionary:
	var options := current_options()
	if index < 0 or index >= options.size():
		return {"ok": false, "next": _node_id, "effects": []}
	var option: Variant = options[index]
	if not (option is Dictionary):
		return {"ok": false, "next": _node_id, "effects": []}
	var applied := _apply_effects((option as Dictionary).get("effects", null))
	var next_id := _move_to(String((option as Dictionary).get("next", "")))
	return {"ok": true, "next": next_id, "effects": applied}


## Marks the current line fully shown — the fast-forward target the HUD drives
## with Space. Text is drawn in full immediately, so this only records that there
## is nothing left to reveal; the HUD then lets E/Space move on. A freshly entered
## node starts unrevealed, which is what makes the call observable.
func skip_remaining() -> void:
	_revealed = true


func is_revealed() -> bool:
	return _revealed


## Records the node as seen under the composed `"<dialogue_id>:<node_id>"` key, so
## the same short node id reused across dialogues never collides.
func mark_read(node_id: String) -> void:
	if _game_state != null and _game_state.has_method("mark_dialogue_read"):
		_game_state.call("mark_dialogue_read", _read_key(node_id))


func is_read(node_id: String) -> bool:
	if _game_state == null or not _game_state.has_method("is_dialogue_read"):
		return false
	return bool(_game_state.call("is_dialogue_read", _read_key(node_id)))


func _read_key(node_id: String) -> String:
	return "%s:%s" % [_dialogue_id, node_id]


## Lands on `node_id`, applies that node's entry effects (so a node can start a
## quest the moment it is shown) and resets the reveal flag for the new line.
func _enter_node(node_id: String) -> void:
	_node_id = node_id
	_revealed = false
	_apply_effects(current_node().get("effects", null))


## Moves to `node_id`; an empty or unknown id ends the conversation. Returns the
## new node id, or "" when it ended.
func _move_to(node_id: String) -> String:
	if node_id == "" or DialogueDB.node(_dialogue_id, node_id).is_empty():
		_finished = true
		_node_id = ""
		return ""
	_enter_node(node_id)
	return _node_id


## Applies one effect value, which may be a single effect dictionary or an array
## of them, and returns the list actually applied so the caller (and a test) can
## see what happened. An unrecognised shape is ignored, never fatal.
func _apply_effects(raw: Variant) -> Array:
	var applied: Array = []
	if raw is Dictionary:
		if _apply_effect(raw as Dictionary):
			applied.append(raw)
	elif raw is Array:
		for item: Variant in (raw as Array):
			if item is Dictionary and _apply_effect(item as Dictionary):
				applied.append(item)
	return applied


func _apply_effect(effect: Dictionary) -> bool:
	# Flag write: {"flag": name, "value": anything} — value defaults to true.
	if effect.has("flag"):
		if _game_state != null and _game_state.has_method("set_flag"):
			_game_state.call("set_flag", String(effect["flag"]), effect.get("value", true))
			return true
		return false
	# Quest action: {"quest": id, "action": "start"|"turn_in"}.
	if effect.has("quest"):
		return _apply_quest_effect(String(effect["quest"]), String(effect.get("action", "start")))
	return false


func _apply_quest_effect(quest_id: String, action: String) -> bool:
	if _quest_manager == null:
		return false
	match action:
		"start":
			if _quest_manager.has_method("start"):
				return bool(_quest_manager.call("start", quest_id))
		"turn_in":
			if _quest_manager.has_method("turn_in"):
				return bool(_quest_manager.call("turn_in", quest_id))
	return false


## Evaluates a condition value: absent or null always passes; otherwise a single
## condition dictionary or an array of them, all of which must hold. Supported
## keys: {"quest_done": id}, {"quest_active": id}, {"flag": name},
## {"not_flag": name}. An unrecognised key inside a condition is ignored, so a
## condition that names nothing checkable passes rather than silently locking a
## line the author meant to be always available.
func _condition_met(raw: Variant) -> bool:
	if raw == null:
		return true
	if raw is Array:
		for item: Variant in (raw as Array):
			if not _condition_met(item):
				return false
		return true
	if not (raw is Dictionary):
		return true
	var cond := raw as Dictionary
	if cond.is_empty():
		return true
	if cond.has("quest_done") and not _quest_is(String(cond["quest_done"]), "done"):
		return false
	if cond.has("quest_active") and not _quest_is(String(cond["quest_active"]), "active"):
		return false
	if cond.has("flag") and not _flag_is(String(cond["flag"]), true):
		return false
	if cond.has("not_flag") and not _flag_is(String(cond["not_flag"]), false):
		return false
	return true


func _quest_is(quest_id: String, want: String) -> bool:
	if _quest_manager == null or not _quest_manager.has_method("state_of"):
		return false
	return String(_quest_manager.call("state_of", quest_id)) == want


func _flag_is(flag_name: String, expected: Variant) -> bool:
	if _game_state == null or not _game_state.has_method("get_flag"):
		return false
	return _game_state.call("get_flag", flag_name, false) == expected
