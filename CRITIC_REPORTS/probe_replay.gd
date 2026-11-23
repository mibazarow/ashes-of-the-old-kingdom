extends SceneTree
## Read-only critic probe #5: do enemies respawn on re-entry? save slots? economy sinks.
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_replay.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _count_enemies() -> int:
	var n := 0
	for e in root.get_nodes_in_group("enemy"):
		if not e.is_queued_for_deletion():
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
	var gs := root.get_node("GameState")

	# --- enemy respawn across a zone round trip ----------------------------
	mgr.call("travel", "forest")
	for i in 5:
		await process_frame
	var before := _count_enemies()
	# kill everything in the forest
	for e in root.get_nodes_in_group("enemy"):
		e.call("take_damage", 99999, &"critic_probe", Vector2.ZERO, 0)
	for i in 8:
		await process_frame
	var after_kill := _count_enemies()
	mgr.call("travel", "ruins")
	for i in 5:
		await process_frame
	mgr.call("travel", "forest")
	for i in range(6):
		await process_frame
	var after_return := _count_enemies()
	print("PROBE forest_enemies before=%d after_kill=%d after_return=%d  respawn=%s"
		% [before, after_kill, after_return, str(after_return > 0)])

	# --- total XP / gold actually obtainable ------------------------------
	print("PROBE xp_total=%d gold_total=%d level=%d" % [
		int(gs.get("total_xp")) if gs.get("total_xp") != null else -1,
		int(gs.get("gold")), int(gs.get("level"))])

	# --- save slots -------------------------------------------------------
	var sm := root.get_node_or_null("SaveManager")
	print("PROBE save_manager=", sm, " slots=",
		str(sm.call("slot_count")) if sm != null and sm.has_method("slot_count") else "no_method")
	if sm != null:
		for p in sm.get_method_list():
			if "slot" in String(p.name) or "save" in String(p.name):
				print("PROBE  SaveManager.%s" % String(p.name))
	quit(0)
