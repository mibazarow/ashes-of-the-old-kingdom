extends Node2D
## Entry point: wires the world, HUD, zone manager and optional debug bot.

## Resolved from the tree on every read rather than cached in `_ready`: travel
## replaces the `World` node outright, so a reference taken once would keep
## pointing at the zone the player left.
var world: Node2D:
	get:
		return get_node_or_null("World") as Node2D

@onready var hud: CanvasLayer = $HUD
@onready var bot: Node = $Bot

## The HUD toast (`hud.gd _on_toast`) holds for TOAST_HOLD_SECONDS and fades
## over TOAST_FADE_SECONDS, so a zone capture taken right after `travel` carried
## the `Зона: ...` line a real player only sees for those 2.1 s — on top of the
## HUD's permanent zone line, which is the duplicate the owner saw in every
## zone frame. The capture path waits the toast out. Suppression (a flag the
## toast listeners ignore) was the other candidate, but the only toast listener
## lives in `hud.gd`, outside this file's reach, and waiting changes nothing in
## real play: travelling still toasts exactly as before. The `inventory` probe
## keeps its short toast on purpose — that one is the screen state the frame is
## meant to show, not a travel announcement.
const TOAST_HOLD_SECONDS := 1.6
const TOAST_FADE_SECONDS := 0.5

## The toast lifetime plus a margin, so the captured frame is certainly after
## the fade has landed on alpha 0.
const ZONE_CAPTURE_SETTLE_SECONDS := TOAST_HOLD_SECONDS + TOAST_FADE_SECONDS + 0.2

## Set by the zone capture branches below; read by `screenshot_must_outlive_toast`.
var _screenshot_zone_travelled := false


## Pure gate so a test can pin the rule without running a capture: a frame taken
## after a travel must wait the zone toast out; every other probe captures
## after the plain frame settle.
static func screenshot_must_outlive_toast(zone_travelled: bool) -> bool:
	return zone_travelled


func _ready() -> void:
	_ensure_zone_manager()
	Telemetry.event(&"scene_ready", {"scene": "main"})
	Telemetry.write_run_meta({"main_scene": "main"})
	_apply_pending_load()
	bot.call("start_from_cmdline")
	_maybe_capture_screenshot()


## The zone manager is a plain child node rather than an autoload: it owns the
## `World` node, so it belongs to the scene that holds the world. Built here
## instead of edited into main.tscn, and only when one is not already there, so a
## scene that ships its own `ZoneManager` keeps it.
##
## It is appended after `Bot`, and travel moves the new world onto the HUD's
## index, so the child order stays World, HUD, Bot, ZoneManager: the CanvasLayer
## keeps drawing over the world no matter how many times the zone changes.
func _ensure_zone_manager() -> ZoneManager:
	var existing := get_node_or_null("ZoneManager") as ZoneManager
	if existing != null:
		return existing
	var manager := ZoneManager.new()
	manager.name = "ZoneManager"
	add_child(manager)
	return manager


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
	elif ui_probe == "skills":
		# Show the skills screen exactly as the player left it: the default known
		# loadout, the active skill, the locked rest and the starting skill point.
		# Nothing is learned or selected here, so the capture reflects real state
		# rather than a rigged one.
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_skills_for_shot")
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
	elif ui_probe == "craft":
		# Gold plus enough claws so both smith recipes read as affordable, and the
		# tempering unlocked the way an NPC or a note would unlock it, so the
		# capture shows the full §14.4 promise: fee, need/have materials and the
		# permanent bonus line ("Атака +2") of the selected upgrade.
		GameState.add_gold(120)
		GameState.add_item("wolf_fang", 4)
		GameState.set_flag("recipe_temper_known", true)
		var hud := get_node_or_null("HUD")
		if hud != null:
			hud.call("open_craft_for_shot")
	elif ui_probe == "village":
		# The village, reached the way a player reaches it: through the zone
		# manager rather than by editing the scene. It is joined to the forest the
		# run starts in, so one travel lands on the same zone line the player reads
		# after walking out through the gate.
		var manager := get_node_or_null("ZoneManager")
		if manager != null:
			manager.call("travel", "village")
			_screenshot_zone_travelled = true
	elif ui_probe == "ruins":
		# The second zone, reached the way a player reaches it: through the zone
		# manager rather than by editing the scene. The capture then shows both the
		# ruins themselves and the zone line following the travel.
		var manager := get_node_or_null("ZoneManager")
		if manager != null:
			manager.call("travel", "ruins")
			_screenshot_zone_travelled = true
	elif ui_probe == "dungeon":
		# The third zone, reached the way a player reaches it: down through the
		# ruins. Two travels rather than one, because the undercroft has no door to
		# the forest — the stair is in the hall the ruins' key opens, so the capture
		# walks the same route and lands on the same zone line the player would see.
		var manager := get_node_or_null("ZoneManager")
		if manager != null:
			manager.call("travel", "ruins")
			manager.call("travel", "dungeon")
			_screenshot_zone_travelled = true
	elif ui_probe == "fortress":
		# The fourth zone, reached the way a player reaches it: down through the
		# ruins, across the undercroft and up through the door at its far end. Three
		# travels rather than one, because the fortress has no door to the forest —
		# the ascent is in the north-east corner of the undercroft — so the capture
		# walks the same route and lands on the same zone line the player would see.
		var manager := get_node_or_null("ZoneManager")
		if manager != null:
			manager.call("travel", "ruins")
			manager.call("travel", "dungeon")
			manager.call("travel", "fortress")
			_screenshot_zone_travelled = true
	for i in range(20):
		await get_tree().process_frame
	# The zone toast from the last travel holds 1.6 s and fades over 0.5 s (see
	# `TOAST_HOLD_SECONDS`); the 20 frames above are a third of a second, so a
	# zone frame captured without this wait always carried the duplicate
	# `Зона: ...` line. Wait the toast out, then grab the frame.
	if screenshot_must_outlive_toast(_screenshot_zone_travelled):
		await get_tree().create_timer(ZONE_CAPTURE_SETTLE_SECONDS).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[screenshot] saved=%s err=%d size=%s" % [path, err, str(image.get_size())])
	get_tree().quit(0)


func _apply_pending_load() -> void:
	# Two ways in, one path. The main menu hands a slot over through the autoload
	# (`GameState.pending_load_slot`) because changing the scene frees the menu that
	# asked, and `PEPEL_LOAD_SLOT=<n>` is the headless probe that has no menu to ask
	# with. The autoload value is consumed either way, so a travel or a second scene
	# change later in the same run cannot replay the same load.
	var slot: int = GameState.pending_load_slot
	GameState.pending_load_slot = 0
	if slot <= 0:
		slot = int(OS.get_environment("PEPEL_LOAD_SLOT"))
	if slot <= 0:
		return
	# Travel before the load, never after. `load_game` hands the saved position to
	# whichever player is in the tree at that moment, so travelling afterwards
	# would free that player along with the zone it lives in and leave the run on
	# the new zone's entry tile instead of the spot the save recorded. Travelling
	# first puts the player in the zone the position was measured in, and the
	# position lands on them exactly. `travel` refuses the zone already stood in,
	# so a same-zone load — every load written before zones existed — costs
	# nothing and changes nothing.
	var saved_zone := SaveManager.slot_zone(slot)
	if saved_zone != "":
		_ensure_zone_manager().call("travel", saved_zone)
	var res: Dictionary = SaveManager.load_game(slot)
	if bool(res.get("ok", false)):
		Telemetry.event(&"load_on_start", {"slot": slot, "zone": String(GameState.zone)})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Telemetry.write_summary("closed_by_user")
