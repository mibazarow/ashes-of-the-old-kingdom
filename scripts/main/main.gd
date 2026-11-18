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
		var pos: Array = res.get("player_position", [])
		if pos.size() == 2 and world.get("player") != null:
			world.get("player").global_position = Vector2(float(pos[0]), float(pos[1]))
		Telemetry.event(&"load_on_start", {"slot": slot})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Telemetry.write_summary("closed_by_user")
