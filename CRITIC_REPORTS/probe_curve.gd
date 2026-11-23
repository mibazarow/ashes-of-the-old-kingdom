extends SceneTree
## Read-only critic probe #6: per-zone difficulty and payout curve.
## Sums the live enemy instances of every zone and reports average regular (non-boss)
## hp / damage / xp / gold plus the zone's total xp and gold budget.
## Run: godot --headless --path . --script res://CRITIC_REPORTS/probe_curve.gd

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
	var manager := _scene.get_node_or_null("ZoneManager")
	for zone in ["forest", "ruins", "dungeon", "fortress"]:
		manager.call("travel", String(zone))
		for i in 5:
			await process_frame
		_measure(_scene.get_node_or_null("World"), String(zone))
	quit(0)


func _measure(world: Node, tag: String) -> void:
	if world == null:
		return
	var list: Array[Node] = []
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.is_in_group("enemy") or n.is_in_group("boss"):
			list.append(n)
	var reg_hp := 0
	var reg_dmg := 0
	var reg_xp := 0
	var reg_gold := 0
	var reg_n := 0
	var all_xp := 0
	var all_gold := 0
	var kinds := {}
	for n in list:
		var hp := int(n.get("max_health"))
		var dmg := int(n.get("attack_damage"))
		var xp := int(n.get("xp_reward"))
		var gold := int(n.get("gold_reward"))
		all_xp += xp
		all_gold += gold
		var t := String(n.get("enemy_type"))
		kinds[t] = int(kinds.get(t, 0)) + 1
		if not n.is_in_group("boss"):
			reg_hp += hp
			reg_dmg += dmg
			reg_xp += xp
			reg_gold += gold
			reg_n += 1
	var d: int = maxi(reg_n, 1)
	print("CURVE[%s] regulars=%d avg_hp=%.1f avg_dmg=%.1f avg_xp=%.1f avg_gold=%.1f | zone_xp=%d zone_gold=%d | kinds=%d" % [
		tag, reg_n, float(reg_hp) / d, float(reg_dmg) / d, float(reg_xp) / d,
		float(reg_gold) / d, all_xp, all_gold, kinds.size()
	])
