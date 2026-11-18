class_name InputSource
extends RefCounted
## Single input funnel for the player.
##
## The human reads the real Input singleton; the debug bot installs an override
## that answers the exact same queries. The player never reads Input directly,
## so a bot can never get privileged access to game state.

static var _override: Object = null


static func set_override(source: Object) -> void:
	_override = source


static func clear_override() -> void:
	_override = null


static func has_override() -> bool:
	return _override != null


static func is_action_pressed(action: StringName) -> bool:
	if _override != null and _override.has_method("is_action_pressed"):
		return bool(_override.call("is_action_pressed", action))
	return Input.is_action_pressed(action)


static func is_action_just_pressed(action: StringName) -> bool:
	if _override != null and _override.has_method("is_action_just_pressed"):
		return bool(_override.call("is_action_just_pressed", action))
	return Input.is_action_just_pressed(action)


static func get_axis(negative: StringName, positive: StringName) -> float:
	return get_vector(negative, positive, positive, negative).x


static func get_vector(negative_x: StringName, positive_x: StringName, negative_y: StringName, positive_y: StringName) -> Vector2:
	if _override != null and _override.has_method("get_vector"):
		return _override.call("get_vector", negative_x, positive_x, negative_y, positive_y)
	return Input.get_vector(negative_x, positive_x, negative_y, positive_y)


static func aim_direction(from: Vector2) -> Vector2:
	if _override != null and _override.has_method("aim_direction"):
		return _override.call("aim_direction", from)
	return from.direction_to(get_global_mouse_position_static())


static func get_global_mouse_position_static() -> Vector2:
	var viewport := Engine.get_main_loop() as SceneTree
	if viewport == null or viewport.root == null:
		return Vector2.ZERO
	return viewport.root.get_mouse_position()
