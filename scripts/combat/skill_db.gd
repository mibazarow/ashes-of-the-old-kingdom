class_name SkillDB
extends RefCounted
## Skill definitions loaded once from data/skills.json (spec §9).
##
## Mirrors ItemDB: a static cache filled lazily from a JSON object under the
## "skills" key, so callers never touch the file directly and the class also
## works under `godot --script`, where autoloads are not registered.

const PATH := "res://data/skills.json"

## Fixed school order for the UI and the tests; independent of JSON order.
const SCHOOL_ORDER := ["fire", "ice", "lightning", "nature"]

## Russian display names for the four schools. The school id in `data/skills.json`
## is a program key, and printing it straight into the HUD put a raw `· fire` on a
## line the player reads as prose. An id missing from this table comes back
## unchanged on purpose: a school added to the JSON without a name here shows its
## real id rather than being silently mislabelled with some other school's word.
const SCHOOL_NAMES := {
	"fire": "огонь",
	"ice": "лёд",
	"lightning": "молния",
	"nature": "природа",
}

static var _skills: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_error("SkillDB: missing %s" % PATH)
		return
	var text := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var block: Variant = parsed.get("skills", {})
		if block is Dictionary:
			_skills = block
		else:
			push_error("SkillDB: 'skills' is not an object in %s" % PATH)
	else:
		push_error("SkillDB: cannot parse %s" % PATH)


static func get_skill(skill_id: String) -> Dictionary:
	_ensure_loaded()
	var def: Variant = _skills.get(skill_id, {})
	return def if def is Dictionary else {}


static func all_skills() -> Dictionary:
	_ensure_loaded()
	return _skills


static func has_skill(skill_id: String) -> bool:
	return not get_skill(skill_id).is_empty()


## Schools in the fixed SCHOOL_ORDER that actually have at least one skill.
static func schools() -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for school in SCHOOL_ORDER:
		for id: String in _skills.keys():
			if String(get_skill(id).get("school", "")) == school:
				out.append(school)
				break
	return out


## The Russian word for a school, for every line the player reads. Unknown ids
## pass through as the id itself, so the HUD never invents a name it does not have.
static func school_name(school: String) -> String:
	return String(SCHOOL_NAMES.get(school, school))


## Skill ids of one school, kept in JSON declaration order.
static func skills_of_school(school: String) -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for id: String in _skills.keys():
		if String(get_skill(id).get("school", "")) == school:
			out.append(id)
	return out


static func is_shape(skill_id: String, shape: String) -> bool:
	return String(get_skill(skill_id).get("shape", "")) == shape
