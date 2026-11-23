extends SceneTree
## Read-only critic probe #3: per-zone census of NPCs, enemies, bosses, props.
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_census.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _go(zone: String) -> void:
	var manager := _scene.get_node_or_null("ZoneManager")
	manager.call("travel", zone)
	for i in 5:
		await process_frame


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)
	for i in 5:
		await process_frame
	for zone in ["forest", "ruins", "dungeon", "fortress"]:
		await _go(zone)
		var world := _scene.get_node_or_null("World")
		_census(world, String(zone))
	quit(0)


func _census(world: Node, tag: String) -> void:
	if world == null:
		return
	var props: Array[String] = []
	var enemies := {}
	var bosses: Array[String] = []
	var total := 0
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.is_in_group("interactable"):
			props.append("%s:%s" % [n.get_class(), String(n.get("npc_id") if n.get("npc_id") != null else n.name)])
		if n.is_in_group("enemy") or n.is_in_group("boss"):
			var t := String(n.get("enemy_type"))
			if n.is_in_group("boss"):
				bosses.append(t)
			else:
				enemies[t] = int(enemies.get(t, 0)) + 1
			total += 1
	print("PROBE[%s] interactables(%d)=%s" % [tag, props.size(), str(props)])
	print("PROBE[%s] enemies_total=%d kinds=%s" % [tag, total, str(enemies)])
	print("PROBE[%s] bosses=%s" % [tag, str(bosses)])
