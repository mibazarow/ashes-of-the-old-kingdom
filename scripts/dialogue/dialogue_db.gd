class_name DialogueDB
extends RefCounted
## Dialogue definitions loaded once from data/dialogue.json (spec §12.2).
##
## Mirrors SkillDB/ItemDB: a static cache filled lazily from a JSON object under
## the "dialogues" key, so callers never touch the file directly and the class
## also works under `godot --script`, where autoloads are not registered. It
## holds no game state and references no autoload, which is what lets the test
## suite reference it by class name without a compile-time dependency on the
## autoloads.

const PATH := "res://data/dialogue.json"

static var _dialogues: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_error("DialogueDB: missing %s" % PATH)
		return
	var text := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var block: Variant = (parsed as Dictionary).get("dialogues", {})
		if block is Dictionary:
			_dialogues = block
		else:
			push_error("DialogueDB: 'dialogues' is not an object in %s" % PATH)
	else:
		push_error("DialogueDB: cannot parse %s" % PATH)


## The whole dialogue entry (speaker_id, speaker, start, optional condition,
## nodes). An unknown id reads as an empty dictionary rather than null.
static func get_dialogue(dialogue_id: String) -> Dictionary:
	_ensure_loaded()
	var def: Variant = _dialogues.get(dialogue_id, {})
	return def if def is Dictionary else {}


static func has_dialogue(dialogue_id: String) -> bool:
	return not get_dialogue(dialogue_id).is_empty()


## Every dialogue id, in JSON declaration order.
static func dialogue_ids() -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for id: Variant in _dialogues.keys():
		out.append(String(id))
	return out


## Dialogue ids whose `speaker_id` matches, in declaration order. The NPC builds
## its conversation id directly (`<speaker_id>_<context>`), so this is the
## read-only view a caller uses to list what one character can say.
static func for_speaker(speaker_id: String) -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for id: String in dialogue_ids():
		if String(get_dialogue(id).get("speaker_id", "")) == speaker_id:
			out.append(id)
	return out


## One node of one dialogue, or an empty dictionary when either is missing.
static func node(dialogue_id: String, node_id: String) -> Dictionary:
	var entry := get_dialogue(dialogue_id)
	if entry.is_empty() or node_id == "":
		return {}
	var nodes: Variant = entry.get("nodes", {})
	if not (nodes is Dictionary):
		return {}
	var block: Variant = (nodes as Dictionary).get(node_id, {})
	return block if block is Dictionary else {}
