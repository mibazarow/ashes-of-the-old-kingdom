extends SceneTree
## One-shot tool: writes the InputMap actions into project.godot.
##
## Run: godot --headless --path . --script res://tools/setup_input_map.gd
## Using the engine itself guarantees the serialized Object(...) syntax matches
## the installed version instead of guessing it.

const ACTIONS := {
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"dash": [KEY_SPACE, KEY_SHIFT],
	"interact": [KEY_E],
	"inventory": [KEY_I],
	"journal": [KEY_J],
	"map": [KEY_M],
	"character": [KEY_C],
	"pause": [KEY_ESCAPE],
	"quick_slot_1": [KEY_1],
	"quick_slot_2": [KEY_2],
	"quick_slot_3": [KEY_3],
	"quick_slot_4": [KEY_4],
	"save_game": [KEY_F5],
	"load_game": [KEY_F9],
}


func _init() -> void:
	for action: String in ACTIONS:
		var events: Array[InputEvent] = []
		for code: int in ACTIONS[action]:
			events.append(_key(code))
		ProjectSettings.set_setting("input/" + action, {"deadzone": 0.2, "events": events})

	# attack is mouse-driven per the spec, with the gamepad button as the only
	# alternative; J now opens the quest journal instead of attacking. Build the
	# whole list at once: assigning twice silently dropped the earlier events.
	var attack_events: Array[InputEvent] = [_mouse_left(), _joy(JOY_BUTTON_X)]
	ProjectSettings.set_setting("input/attack", {"deadzone": 0.2, "events": attack_events})

	# The placeholder ability is right-mouse-driven, same explicit-list pattern as
	# attack so the serialized events survive the save.
	var ability_events: Array[InputEvent] = [_mouse_right()]
	ProjectSettings.set_setting("input/ability", {"deadzone": 0.2, "events": ability_events})

	var err := ProjectSettings.save()
	print("input map written, save error=", err)
	quit(0)


func _key(code: int) -> InputEventKey:
	var key := InputEventKey.new()
	key.physical_keycode = code
	key.keycode = code
	return key


func _mouse_left() -> InputEventMouseButton:
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	return mouse


func _mouse_right() -> InputEventMouseButton:
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_RIGHT
	return mouse


func _joy(button: int) -> InputEventJoypadButton:
	var joy := InputEventJoypadButton.new()
	joy.button_index = button
	return joy
