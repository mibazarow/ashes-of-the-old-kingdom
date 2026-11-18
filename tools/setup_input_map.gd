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
	"attack": [KEY_J, KEY_SPACE],
	"dash": [KEY_SHIFT],
	"interact": [KEY_E],
	"inventory": [KEY_I],
	"pause": [KEY_ESCAPE],
	"quick_slot_1": [KEY_1],
	"quick_slot_2": [KEY_2],
	"save_game": [KEY_F5],
	"load_game": [KEY_F9],
}


func _init() -> void:
	for action: String in ACTIONS:
		var events: Array[InputEvent] = []
		for code: int in ACTIONS[action]:
			var key := InputEventKey.new()
			key.physical_keycode = code
			events.append(key)
		ProjectSettings.set_setting("input/" + action, {"deadzone": 0.2, "events": events})

	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	var attack_events: Array[InputEvent] = [mouse]
	ProjectSettings.set_setting("input/attack", {"deadzone": 0.2, "events": attack_events})

	var joy_attack := InputEventJoypadButton.new()
	joy_attack.button_index = JOY_BUTTON_X
	var with_joy: Array[InputEvent] = [mouse, joy_attack]
	ProjectSettings.set_setting("input/attack", {"deadzone": 0.2, "events": with_joy})

	var err := ProjectSettings.save()
	print("input map written, save error=", err)
	quit(0)
