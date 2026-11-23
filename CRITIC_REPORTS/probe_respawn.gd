extends SceneTree
## Read-only critic probe #5b: do cleared enemies come back on zone re-entry?
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_respawn.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _alive() -> int:
	var n := 0
	for e in get_nodes_in_group("enemy"):
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			var hc = e.get_node_or_null("HealthComponent")
			if hc != null and int(hc.get("current_health")) > 0:
				n += 1
	return n


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)
	for i in 5:
		await process_frame
	var mgr := _scene.get_node_or_null("ZoneManager")
	mgr.call("travel", "forest")
	for i in 5:
		await process_frame
	var before := _alive()
	for e in get_nodes_in_group("enemy"):
		var hc = e.get_node_or_null("HealthComponent")
		if hc != null:
			hc.call("take_damage", 9999, {})
	for i in 10:
		await process_frame
	var after := _alive()
	mgr.call("travel", "ruins")
	for i in 5:
		await process_frame
	mgr.call("travel", "forest")
	for i in 5:
		await process_frame
	var back := _alive()
	print("PROBE_RESPAWN forest alive_before=%d after_kill=%d after_reentry=%d respawned=%s"
		% [before, after, back, str(back > 0 and after == 0)])
	quit(0)
