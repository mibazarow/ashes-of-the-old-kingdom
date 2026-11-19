extends Node2D
## Entry point: wires the world, HUD and optional debug bot.

@onready var world: Node2D = $World
@onready var hud: CanvasLayer = $HUD
@onready var bot: Node = $Bot


func _ready() -> void:
	Telemetry.event(&"scene_ready", {"scene": "main"})
	Telemetry.write_run_meta({"main_scene": "main"})
	_apply_pending_load()
	bot.call("start_from_cmdline")
	_maybe_capture_screenshot()


## Debug aid: PEPEL_SCREENSHOT=<path> renders a few frames, saves a PNG and quits.
func _maybe_capture_screenshot() -> void:
	var path := OS.get_environment("PEPEL_SCREENSHOT")
	if path == "":
		return
	var ui_probe := OS.get_environment("PEPEL_SCREENSHOT_UI")
	if ui_probe == "dialogue":
		EventBus.dialogue_requested.emit([{
			"speaker": "Эдрик",
			"text": "Слышишь вой? Это пепельные волки. Три штуки у опушки — и деревня вздохнёт спокойнее.",
		}])
	elif ui_probe == "inventory":
		GameState.add_item("iron_sword", 1)
		GameState.add_item("health_potion", 3)
		GameState.equip("iron_sword")
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_inventory_for_shot")
		EventBus.toast.emit("Сундук: Железный меч")
	elif ui_probe == "journal":
		if QuestManager.quests.has("q01_ash_wolves"):
			QuestManager.start("q01_ash_wolves")
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_journal_for_shot")
	elif ui_probe == "settings":
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_settings_for_shot")
	elif ui_probe == "character":
		# A few unspent points so the screenshot shows a realistic screen state
		# (the points line and a spendable cursor), not an empty pool.
		GameState.attribute_points = 4
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_character_for_shot")
	elif ui_probe == "map":
		# Walk the player east along the road so the explored area grows past the
		# spawn clearing and the trap landmark falls inside the visited radius.
		var world := get_node_or_null("World")
		if world != null:
			var player := world.get_node_or_null("Player") as Node2D
			if player != null:
				player.position = Vector2(21 * 16 + 8, 9 * 16 + 8)
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_map_for_shot")
	elif ui_probe == "shop":
		# Gold plus a couple of sellable goods so the capture shows a real shop:
		# the gold line, the merchant's buy list and a non-empty sell list.
		GameState.add_gold(120)
		GameState.add_item("wolf_fang", 4)
		GameState.add_item("health_potion", 2)
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_shop_for_shot")
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[screenshot] saved=%s err=%d size=%s" % [path, err, str(image.get_size())])
	get_tree().quit(0)


func _apply_pending_load() -> void:
	var slot: int = int(OS.get_environment("PEPEL_LOAD_SLOT"))
	if slot <= 0:
		return
	var res: Dictionary = SaveManager.load_game(slot)
	if bool(res.get("ok", false)):
		Telemetry.event(&"load_on_start", {"slot": slot})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Telemetry.write_summary("closed_by_user")
