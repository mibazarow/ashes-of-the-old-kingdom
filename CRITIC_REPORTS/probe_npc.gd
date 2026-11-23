extends SceneTree
## Read-only critic probe #4: does each NPC actually run a conversation?
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_npc.gd

var _scene: Node = null


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)
	for i in 5:
		await process_frame
	var db := root.get_node_or_null("DialogueDB")
	for zone in ["forest", "ruins", "dungeon", "fortress"]:
		var manager := _scene.get_node_or_null("ZoneManager")
		manager.call("travel", zone)
		for i in 5:
			await process_frame
		var world := _scene.get_node_or_null("World")
		if world == null:
			continue
		for n in world.get_tree().get_nodes_in_group("interactable"):
			var sname := String(n.name)
			if sname in ["PilgrimForest", "PilgrimRuins", "PilgrimDungeon", "PilgrimFortress"]:
				var did := String(n.call("dialogue_id"))
				print("PROBE[%s] %s dialogue_id=%s exists=%s" % [zone, sname, did,
					String(db.call("has_dialogue", did)) if db != null else "?"])
			elif n.has_method("interact") and (n.get("speaker_id") != null or n.get("display_name") != null):
				var sid := String(n.get("speaker_id")) if n.get("speaker_id") != null else sname.to_lower()
				var intro := "%s_intro" % sid
				var after := "%s_after_hunt" % sid
				print("PROBE[%s] NPC %s speaker_id=%s has_intro=%s has_after=%s quests=%s" % [
					zone, sname, sid,
					String(db.call("has_dialogue", intro)) if db != null else "?",
					String(db.call("has_dialogue", after)) if db != null else "?",
					str(n.get("quest_ids")) if n.get("quest_ids") != null else String(n.get("quest_id"))])
	quit(0)
