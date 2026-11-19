extends Node
## Persisted key rebinding (spec §6). Settings live in their own file under
## user://settings, never inside user://saves, so controls do not travel with
## game progress (spec §18).
##
## The startup InputMap (project.godot) is captured before any stored file is
## applied, which gives "reset to default" a source that rebinding cannot
## overwrite. Only keyboard and mouse events are serialised; gamepad and
## anything else keep their project defaults for the current session.

const PATH := "user://settings/controls.json"
const VERSION := 1
const REBINDABLE: Array[String] = [
	"move_up", "move_down", "move_left", "move_right",
	"attack", "dash", "interact", "inventory", "journal", "map", "character", "pause",
	"ability", "quick_slot_1", "quick_slot_2", "quick_slot_3", "quick_slot_4",
]

## action -> the event list as it was at startup, before load_bindings().
var _defaults: Dictionary = {}


func _ready() -> void:
	for action in REBINDABLE:
		_defaults[action] = InputMap.action_get_events(action).duplicate()
	load_bindings()


## Replace the InputMap events of every stored action. Unknown actions,
## malformed entries and a corrupt file are ignored with a warning: the
## project defaults stay in place rather than the game failing to boot.
func load_bindings() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var parsed: Variant = _parse_json(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary:
		_warn("%s is not a JSON object, keeping defaults" % PATH)
		return
	var raw_bindings: Variant = (parsed as Dictionary).get("bindings", {})
	if not raw_bindings is Dictionary:
		_warn("%s has no bindings block, keeping defaults" % PATH)
		return
	for raw_action: Variant in (raw_bindings as Dictionary).keys():
		if not (raw_action is String) or not REBINDABLE.has(raw_action):
			continue
		var action := String(raw_action)
		var entries: Variant = (raw_bindings as Dictionary)[raw_action]
		if not entries is Array:
			continue
		var events: Array[InputEvent] = []
		for entry: Variant in entries:
			if entry is Dictionary:
				var event := _event_from_entry(entry)
				if event != null:
					events.append(event)
		if events.is_empty():
			continue
		InputMap.action_erase_events(action)
		for event in events:
			InputMap.action_add_event(action, event)


## Write the current InputMap of every rebindable action atomically:
## controls.json.tmp -> read back and parse -> rename over controls.json.
func save_bindings() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var bindings := {}
	for action in REBINDABLE:
		var entries: Array = []
		for event in InputMap.action_get_events(action):
			var entry := _entry_from_event(event)
			if not entry.is_empty():
				entries.append(entry)
		bindings[action] = entries
	var text := JSON.stringify({"version": VERSION, "bindings": bindings}, "\t")

	var tmp := PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		var msg := "cannot_open_tmp: %s" % error_string(FileAccess.get_open_error())
		_warn(msg)
		return {"ok": false, "error": msg}
	file.store_string(text)
	file.flush()
	file.close()

	var verify := FileAccess.get_file_as_string(tmp)
	if verify.length() != text.length() or _parse_json(verify) == null:
		DirAccess.remove_absolute(tmp)
		_warn("verification failed for %s" % PATH)
		return {"ok": false, "error": "verification_failed"}

	var err := DirAccess.rename_absolute(tmp, PATH)
	if err != OK:
		_warn("rename failed (%s)" % error_string(err))
		return {"ok": false, "error": "rename_failed:%s" % error_string(err)}
	return {"ok": true, "error": ""}


## Replace the single binding of `action` with `event`. Refused (no change)
## for an action outside REBINDABLE, a null or non key/mouse event, and for
## an input already owned by another rebindable action.
func rebind(action: String, event: InputEvent) -> bool:
	if not REBINDABLE.has(action) or event == null:
		return false
	var entry := _entry_from_event(event)
	if entry.is_empty():
		return false
	for other in REBINDABLE:
		if other == action:
			continue
		for current in InputMap.action_get_events(other):
			if _entry_from_event(current) == entry:
				return false
	var clean := _event_from_entry(entry)
	if clean == null:
		return false
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, clean)
	var saved := save_bindings()
	if not bool(saved.get("ok", false)):
		_warn("%s not persisted (%s)" % [action, saved.get("error", "")])
	return bool(saved.get("ok", false))


## First event of the startup default list, for display and "reset".
func default_event(action: String) -> InputEvent:
	var events: Array = _defaults.get(action, [])
	return events[0] if not events.is_empty() else null


## Put the whole startup event list back (a default action can hold more than
## one binding, e.g. WASD plus arrows) and persist the result.
func reset_action(action: String) -> void:
	if not _defaults.has(action):
		return
	InputMap.action_erase_events(action)
	for event in _defaults[action]:
		InputMap.action_add_event(action, event)
	save_bindings()


## Single-line diagnostic. Deliberately not push_warning(): that prints a
## multi-line GDScript backtrace, which a corrupt settings file (a recoverable,
## expected condition) should not spray into the log or the test output. The
## problem is still reported, on one line, and never silently swallowed.
func _warn(message: String) -> void:
	print("[input_bindings] %s" % message)


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _entry_from_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var code := int((event as InputEventKey).physical_keycode)
		if code <= 0:
			return {}
		return {"type": "key", "code": code}
	if event is InputEventMouseButton:
		var button := int((event as InputEventMouseButton).button_index)
		if button <= 0:
			return {}
		return {"type": "mouse", "button": button}
	return {}


func _event_from_entry(entry: Dictionary) -> InputEvent:
	match String(entry.get("type", "")):
		"key":
			var code := int(entry.get("code", 0))
			if code <= 0:
				return null
			var key := InputEventKey.new()
			key.physical_keycode = code
			return key
		"mouse":
			var button := int(entry.get("button", 0))
			if button <= 0:
				return null
			var mouse := InputEventMouseButton.new()
			mouse.button_index = button
			return mouse
	return null
