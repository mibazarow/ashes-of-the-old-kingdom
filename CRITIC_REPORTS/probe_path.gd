extends SceneTree
## Read-only critic probe #2: main-path gates, quest reachability, content census.
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_path.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _travel_sync(zone: String) -> Node:
	var manager := _scene.get_node_or_null("ZoneManager")
	var ok := bool(manager.call("travel", zone))
	var world := _scene.get_node_or_null("World")
	print("PROBE travel %s ok=%s zone=%s" % [zone, ok, String(world.call("zone_id")) if world != null else "?"])
	return world


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)
	for i in 4:
		await process_frame

	# --- fresh-start HUD / quest state -------------------------------------
	var hud := _scene.get_node_or_null("HUD")
	print("PROBE fresh_active_quests=", str(_collect_active()))
	if hud != null and hud.has_method("quest_tracker_text"):
		print("PROBE tracker_text=", String(hud.call("quest_tracker_text")))
	var gs := root.get_node("GameState")

	# --- forest: village inside it? NPCs, exits ----------------------------
	var world := _scene.get_node_or_null("World")
	_census(world, "forest")
	var exit_ids: Array[String] = []
	for n in world.get_tree().get_nodes_in_group("interactable"):
		if n.get("target_zone") != null:
			exit_ids.append("%s->%s" % [n.name, String(n.get("target_zone"))])
	print("PROBE forest_exits=", str(exit_ids))

	# --- ruins: is the door gated? can we open it without key/lever? -------
	world = _travel_sync("ruins")
	for i in 4:
		await process_frame
	_census(world, "ruins")
	var exit_ids2: Array[String] = []
	for n in world.get_tree().get_nodes_in_group("interactable"):
		if n.get("target_zone") != null:
			exit_ids2.append("%s->%s" % [n.name, String(n.get("target_zone"))])
	print("PROBE ruins_exits=", str(exit_ids2))
	var door: Node = null
	for n in world.get_tree().get_nodes_in_group("ruin_door"):
		door = n
	if door != null:
		print("PROBE door_open_before_anything=", bool(door.call("is_open")))
		door.call("interact", null)
		print("PROBE door_open_after_interact_no_key=", bool(door.call("is_open")))
	# try to walk to dungeon straight away
	var mgr := _scene.get_node_or_null("ZoneManager")
	print("PROBE can_travel_dungeon_from_ruins_without_key=", bool(mgr.call("travel", "dungeon")))
	for i in 3:
		await process_frame
	world = _scene.get_node_or_null("World")
	print("PROBE zone_now=", String(world.call("zone_id")))
	_census(world, "dungeon_no_key")
	# back to ruins, check what the stair needs
	mgr.call("travel", "ruins")
	for i in 3:
		await process_frame

	print("PROBE flags_after_arrival=", str(gs.get("flags")) if gs.get("flags") != null else "n/a")
	quit(0)


func _collect_active() -> Array[String]:
	var out: Array[String] = []
	var qm := root.get_node_or_null("QuestManager")
	if qm == null:
		return out
	var all: Dictionary = qm.get("quests")
	for k in all.keys():
		var st := String(all[k].get("state", "?"))
		if st != "locked":
			out.append("%s=%s" % [k, st])
	return out


func _census(world: Node, tag: String) -> void:
	if world == null:
		return
	var npcs := 0
	var chests := 0
	var enemies := 0
	var bosses := 0
	var interactables := 0
	var names: Array[String] = []
	for c in world.get_children():
		if c.is_in_group("npc"):
			npcs += 1
			names.append(String(c.name))
		if c.is_in_group("chest"):
			chests += 1
		if c.is_in_group("enemy"):
			enemies += 1
		if c.is_in_group("boss"):
			bosses += 1
		if c.is_in_group("interactable"):
			interactables += 1
	print("PROBE census[%s] npc=%d interactable=%d chest=%d enemy=%d boss=%d npc_names=%s"
		% [tag, npcs, interactables, chests, enemies, bosses, str(names)])
