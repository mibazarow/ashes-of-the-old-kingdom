extends SceneTree
## Read-only critic probe: can a HUMAN player commit an ending?
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_ending.gd

func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	await process_frame
	var manager := scene.get_node_or_null("ZoneManager")
	var hud := scene.get_node_or_null("HUD")
	print("PROBE manager=", manager, " hud=", hud)
	if manager != null:
		print("PROBE travel_fortress=", bool(manager.call("travel", "fortress")))
		await process_frame
		await process_frame
		await process_frame
	var world := scene.get_node_or_null("World")
	print("PROBE zone=", String(world.call("zone_id")) if world != null else "NO WORLD")
	var altar := world.get_node_or_null("EndingAltar") if world != null else null
	print("PROBE altar_found=", altar != null)
	if altar == null:
		quit(1)
		return
	var gs := root.get_node("GameState")
	print("PROBE ending_before=", String(gs.get("ending")))
	# Simulate the player standing at the throne and pressing E, after the King died.
	gs.call("set_flag", "king_defeated", true)
	print("PROBE prompt_after_king_dead=", String(altar.call("prompt_text")))
	altar.call("interact", null)
	await process_frame
	print("PROBE ending_after_interact=", String(gs.get("ending")),
		"  <-- empty means the player cannot commit an ending by pressing E")
	# Is there ANY selectable ending control anywhere in the HUD tree?
	var found: Array[String] = []
	_walk(hud, found)
	print("PROBE hud_nodes_matching_ending_ui=", str(found))
	# Does the HUD accept any key that maps to an ending?
	print("PROBE has_choose_hook=", hud.has_method("select_ending") or hud.has_method("_on_ending_chosen"))
	quit(0)


func _walk(n: Node, out: Array[String]) -> void:
	for c in n.get_children():
		var label := ""
		if c is Button:
			label = (c as Button).text
		elif c is Label:
			label = (c as Label).text
		var hay := (String(c.name) + " " + label).to_lower()
		if "dawn" in hay or "crown" in hay or "рассвет" in hay or "венец" in hay or "ending" in hay or "судьб" in hay:
			out.append("%s(%s)=%s" % [n.get_path_to(c), c.get_class(), label])
		_walk(c, out)
