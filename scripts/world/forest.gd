class_name Forest
extends ZoneBase
## The first zone. Builds the forest slice at runtime: the grid from a fixed
## seed, props and spawns, and the two gates — the ruins to the east and the
## village to the west. The village itself (the six NPCs, their houses and the
## safe zone the enemies are turned back from) moved into its own zone in
## `scripts/world/village.gd`; what stays here is the wild half. The old village
## clearing survives as a keep-out rect: no hostile and no pilgrim is placed on
## the ground the headman's people still cross on their way in and out.
## Everything generic (grid reader, tileset build, exploration, camera, spawn
## scans) lives in `ZoneBase`; this file is content only.

const WOLF_SCENE := "res://scenes/enemies/wolf.tscn"
const ARCHER_SCENE := "res://scenes/enemies/archer.tscn"
const BOAR_SCENE := "res://scenes/enemies/boar.tscn"
const WISP_SCENE := "res://scenes/enemies/wisp.tscn"
const FOREST_WARDEN_SCENE := "res://scenes/enemies/forest_warden.tscn"
## The forest's second boss (spec §11): the Root Mother, met in the south ash glade.
## It summons spiders through phase one and grows destructible weak points through
## phase two, so it is a different fight from the warden rather than a bigger warden.
const ROOT_MOTHER_SCENE := "res://scenes/enemies/root_mother.tscn"
## The five new forest predators (spec §10). Each one is a different mechanic on
## the shared `Enemy` script rather than a recoloured wolf: the spider webs, the
## slime leaves a spore pool, the tick swarms, the lumberjack reads its axe a
## long time coming, the root beast is a turret that never walks.
const SPIDER_SCENE := "res://scenes/enemies/spider.tscn"
const SLIME_SCENE := "res://scenes/enemies/slime.tscn"
const TICK_SCENE := "res://scenes/enemies/tick.tscn"
const LUMBERJACK_SCENE := "res://scenes/enemies/lumberjack.tscn"
const ROOT_BEAST_SCENE := "res://scenes/enemies/root_beast.tscn"
const CHEST_SCENE := "res://scenes/interactables/chest.tscn"
const TRAP_SCENE := "res://scenes/interactables/spike_trap.tscn"
const PICKUP_SCENE := "res://scenes/items/pickup.tscn"
## The purse of gold draws the coin sprite, not the potion the pickup scene ships
## with: the scene's texture is the one every item find wants, and a find that
## carries only gold has no reason to draw a flask.
const COIN_TEXTURE := "res://assets/sprites/coin.png"
const BREAKABLE_SCENE := "res://scenes/world/breakable.tscn"

## Map is generated once from a fixed seed so every run and every test sees the
## same layout, while staying readable instead of a 60-line string literal.
const MAP_W := 52
const MAP_H := 32
const MAP_SEED := 20261107

## Points of interest kept as live node references so the map can show them
## without fragile path lookups. Populated in _spawn_actors.
var _chest_node: Node2D
var _chest_spear_node: Node2D
var _trap_node: Node2D
var _rubble_node: Node2D
var _ruins_gate_node: Node2D
var _village_gate_node: Node2D
var _root_mother_node: Node2D

## Fixed anchor for the spear chest, on the south-west side away from the sword
## chest in the east clearing. The exact tile is derived from the generated grid
## (see _find_walkable_near), so the spawn stays deterministic and never lands
## inside a tree cluster.
const SPEAR_CHEST_ANCHOR := Vector2i(12, 24)

## The old village clearing, in tiles (rows 6..11 x cols 2..9): the dirt patch
## the generated grid paints in the west of the map. The villagers who lived on
## it moved to their own zone (`scripts/world/village.gd`), so the forest no
## longer promises safety anywhere and owns no `safe_zone_owner` group. What the
## rect still does is keep the clearing empty: no new predator and no pilgrim is
## placed on it (`_is_new_enemy_tile`, `_is_pilgrim_tile`), because the road to
## `VillageGate` runs across it and a spider on the doorstep of the only safe
## place in the game is a defect the old rule was always also about.
const SAFE_ZONE_RECT := Rect2i(2, 5, 9, 8)

## Anchors for the two new predator types (roadmap stage D), on the east/south
## half of the map: far enough from the wolf pack and the village that the BOT-008
## hunter still reaches a wolf first, far enough from the eastern clearing that
## the cultist stays the only ranged enemy of note there. Each anchor is only a
## starting point — the actual tile comes from `_find_walkable_near`, so a tree
## cluster from the fixed seed can never swallow a spawn.
const BOAR_A_ANCHOR := Vector2i(38, 22)
const BOAR_B_ANCHOR := Vector2i(44, 26)
const WISP_A_ANCHOR := Vector2i(34, 26)
const WISP_B_ANCHOR := Vector2i(41, 18)

## How far the walkable scan looks around a new-enemy anchor before giving up.
## 5 tiles is 80 px against a 2x2 tree cluster, so it always finds the clearing.
const NEW_ENEMY_SCAN_RADIUS := 5

## The tile the player arrives on. Named as a constant rather than left as the
## two numbers inside `_spawn_actors`, because the rule below that keeps hostiles
## off the player's first few steps has to read the very same tile the player is
## actually placed on — a spawn point moved without moving this number would
## quietly shrink that clearance to nothing.
const PLAYER_SPAWN_TILE := Vector2i(4, 9)

## Anchors for the five new forest predators (spec §10). They sit on the south and
## east half of the map for two reasons. Mechanically, that is where the woods are
## thickest and the village is not. Practically, the debug hunter (BOT-008) walks
## at the NEAREST enemy and must still reach a wolf first: the closest wolf post
## is WolfA at (18, 14), 238 px from the spawn, and `NEW_ENEMY_CLEAR_FROM_SPAWN`
## below is what keeps every new post beyond that. Each anchor is only a starting
## point — the actual tile comes from `_find_new_enemy_tile`, so a tree cluster
## from the fixed seed can never swallow a spawn.
const SPIDER_A_ANCHOR := Vector2i(13, 25)
const SPIDER_B_ANCHOR := Vector2i(38, 16)
const SLIME_A_ANCHOR := Vector2i(26, 24)
const TICK_A_ANCHOR := Vector2i(12, 26)
const TICK_B_ANCHOR := Vector2i(15, 26)
const TICK_C_ANCHOR := Vector2i(18, 26)
const LUMBERJACK_A_ANCHOR := Vector2i(29, 19)
const ROOTBEAST_A_ANCHOR := Vector2i(45, 12)

## How far a new predator has to stay from the tile the player arrives on
## (Chebyshev, so the diagonal counts as close too). Sixteen tiles is 256 px,
## which is more than the 238 px to the nearest wolf post, so the hunter bot's
## first target stays a wolf, and it is also four times the width of the village
## safe zone — nobody spawns a spider on the herbwife's doorstep. The rule is
## enforced by `_find_new_enemy_tile` on the tile it is about to return, not on
## the anchor, so a scan that has to step around a tree cannot smuggle a post
## closer than this.
const NEW_ENEMY_CLEAR_FROM_SPAWN := 16

## How wide the new-predator scan looks for a free tile. Three tiles clears a
## 2x2 cluster without wandering a post out of the quarter of the map its anchor
## names, which is what keeps the pack of three ticks a pack instead of a spread.
const NEW_ENEMY_SCAN_RADIUS_SMALL := 3

## Anchor for the forest mini-boss (roadmap stage D, spec §10.4). It sits inside
## the east clearing the archer and the sword chest already hold, one tile short
## of the archer's own tile, so the boss guards the same clearing without standing
## on top of the ranged enemy or the chest.
##
## The scan radius here is deliberately 1 rather than `NEW_ENEMY_SCAN_RADIUS`:
## the clearing is carved walkable across the whole rectangle rows 4..7 x
## cols MAP_W-9..MAP_W-2, so a one-tile scan is guaranteed to land inside it,
## while a five-tile scan would just as happily walk out of the clearing toward
## the map border. The tile it picks is (MAP_W - 9, 6) on every run: the anchor,
## the rectangle and the seed are all fixed.
const FOREST_WARDEN_ANCHOR := Vector2i(MAP_W - 8, 7)
const FOREST_WARDEN_SCAN_RADIUS := 1

## Anchor for the second forest boss (spec §11), the Root Mother. It sits in the
## open south-central ground, deliberately far from the warden's east clearing so
## the two bosses never share a boss bar: the tile is 20 tiles from the warden (320
## px, past the 200 px engage radius) and 20 tiles from the arrival point, so the
## hunter bot still reaches a wolf first and the warden's own boss-bar test, which
## walks the player up to the warden, never trips the Root Mother's bar either. The
## tile is snapped by `_find_new_enemy_tile`, so it honours the same safe-zone and
## spawn-clearance rules as every other predator and cannot land in a tree.
const ROOT_MOTHER_ANCHOR := Vector2i(24, 24)

## The south-side shortcut (roadmap stage D). The generated grid leaves exactly
## one tile of passage between the tree block at cols 12..15 rows 27..28 and the
## block at cols 20..21 rows 27..28: the neck runs (19,27) -> (19,28) -> (19,29),
## because (18,29) and (19,30) are trees on one side and (20,28), (21,28) are
## trees on the other. (19,28) is the mouth of that neck, so a pile there closes
## the direct line from the village down into the row-29 gully without cutting
## anything off — the gully stays reachable the long way round, north of the
## (20..21, 27..28) cluster and back down at col 22, which costs 4 extra tiles to
## the nook at (20,30) and 6 to (19,29). Those are BFS numbers measured through
## `cell_at`, asserted by the `breakable_shortcut` test group rather than
## trusted from this comment.
##
## The tile is deliberately NOT an articulation point: with the pile standing,
## every NPC, both chests and every enemy are still reachable at their original
## distance, which is what keeps the bots on their existing routes. It is also
## five rows clear of the road (rows 6..11), so it never blocks the main drag.
const RUBBLE_TILE := Vector2i(19, 28)
const RUBBLE_SHORTCUT_ID := "forest_south"

## How far the walkable scan looks for a find. Two tiles is enough to step out of
## a 2x2 cluster and small enough to keep each find inside the quarter of the map
## its anchor names, which is what "three finds in different parts of the map"
## means here: east, south-west and the gully behind the rubble.
const FIND_SCAN_RADIUS := 2

## Anchors for the three finds. The herb is on the east flank below the archer's
## clearing, the coin purse in the south-west, and the flask in the nook at
## (20,30) that the rubble seals — so the shortcut pays for itself in a potion.
## The flask uses radius 0 on purpose: its tile is chosen by the shortcut
## geometry, not by the scan, so the call is a walkability check on that exact
## tile, and the test group asserts every find (this one included) ends up on
## ground a player can stand on.
const PICKUP_HERB_ANCHOR := Vector2i(46, 13)
const PICKUP_COIN_ANCHOR := Vector2i(9, 26)
const PICKUP_FLASK_TILE := Vector2i(20, 30)

## The gate to the second zone, at the eastern end of the dirt road. The road is
## painted for x in 2..MAP_W-3 and drifts one tile per column, so with this seed
## its last tile is (MAP_W-3, 13) — the easternmost `,` on the map, two columns
## short of the border wall. The tile is checked for walkability by a radius-0
## scan rather than snapped by a wide one, because a scan free to move the gate
## would quietly relocate the only way out; if the road ever stops being walkable
## there, the spawn falls back to the anchor and the zone test notices.
const RUINS_GATE_TILE := Vector2i(MAP_W - 3, 13)

## The gate to the village, at the western end of the same road, on the first
## clearing tile east of the wall belt (the clearing paints x2..9, so (2,8) is
## dirt on every seed). Two tiles and a bit from the arrival point — 35 px
## against the 26 px interact reach — so no prompt shows under the player's
## feet on arrival, and the walk west to the village is a walk, not a key
## already pressed. The village answers with its own `ForestGate` two tiles
## inside its east wall.
const VILLAGE_GATE_TILE := Vector2i(2, 8)

## The pilgrim (spec §12): the grey, near-silent stranger who stands on the road
## east of the village and hands out the first fragment of the king's story. He is
## a story figure, not a hazard, so — unlike the villagers — he belongs OUTSIDE the
## village safe zone the enemies are turned back from, and far enough from the
## arrival tile that arriving never opens his prompt under the player's feet. The
## anchor is snapped by `_find_pilgrim_tile`, so a tree cluster from the fixed seed
## can never take him, and the avoid set keeps him off every enemy, prop and NPC.
const PILGRIM_ANCHOR := Vector2i(24, 4)
const PILGRIM_SCAN_RADIUS := 2
const PILGRIM_CLEAR_FROM_ENTRY := 6


## The forest keeps the green palette the original atlas was cut from.
func tile_atlas_path() -> String:
	return "res://assets/sprites/tiles_forest.png"


## Readability (CRITIC-P1-18): the forest floor is the lightest in the game, so
## enemies keep the dark silhouette and a moderately darkened body — both clear
## >=3:1 against the bright grass and dirt.
func enemy_outline_color() -> Color:
	return Color(0.043, 0.051, 0.067)


func enemy_body_tint() -> Color:
	return Color(0.5, 0.5, 0.5)


func zone_id() -> String:
	return "forest"


func zone_name() -> String:
	return "Лесной край"


func music_track() -> String:
	return "music_forest"


func ambience_track() -> String:
	return "ambience_forest"


## The forest owns no safe zone any more — the village does, in its own zone —
## so it advertises nothing and `is_in_safe_zone` stays the base's `false`. The
## `SAFE_ZONE_RECT` above survives as a private spawn keep-out, not a promise.


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		["Chest", "chest", _chest_node],
		["ChestSpear", "chest", _chest_spear_node],
		["Trap", "trap", _trap_node],
		# The shortcut marker disappears on its own once the pile is broken: the
		# loop below drops a node that has been freed. The validity check has to
		# come before the typed binding, not after it — assigning a freed instance
		# to `var node: Node2D` is itself a script error, and the rubble is the
		# first landmark that ever frees itself, so every map open after it broke
		# used to log one.
		["Rubble", "shortcut", _rubble_node],
		# The way out to the second zone. A gate is a landmark like any other so
		# the player can find the road's end on the map, and it is a live node
		# reference like the rest, so it drops out of the list the moment the
		# world that owns it goes away.
		["RuinsGate", "gate", _ruins_gate_node],
		# The way west into the village. Marked like the ruins gate so both doors
		# of the forest read on the map.
		["VillageGate", "gate", _village_gate_node],
		# The Root Mother is marked so the player can find the second boss on the
		# map. The warden is not a landmark (it never was); the boss marker points at
		# the one the player has not met yet, which is the one worth finding.
		["RootMother", "boss", _root_mother_node],
	]:
		if not is_instance_valid(entry[2]):
			continue
		var node: Node2D = entry[2]
		if node == null:
			continue
		out.append({
			"id": String(entry[0]),
			"kind": String(entry[1]),
			"tile": Vector2i(
				floori(node.global_position.x / float(TILE)),
				floori(node.global_position.y / float(TILE))
			),
		})
	return out


func _generate_map() -> void:
	_map_width = MAP_W
	_map_height = MAP_H
	var rng := RandomNumberGenerator.new()
	rng.seed = MAP_SEED
	var grid: Array = []
	for y in range(MAP_H):
		var row: Array = []
		for x in range(MAP_W):
			var edge := x == 0 or y == 0 or x == MAP_W - 1 or y == MAP_H - 1
			var border := x == 1 or y == 1 or x == MAP_W - 2 or y == MAP_H - 2
			if edge:
				row.append("#")
			elif border and rng.randf() < 0.55:
				row.append("T")
			else:
				row.append(".")
		grid.append(row)

	# A dirt road from the village (west) to the ruins edge (east).
	var road_y := 8
	for x in range(2, MAP_W - 2):
		road_y = clampi(road_y + rng.randi_range(-1, 1), 6, MAP_H - 5)
		for dy in range(0, 2):
			grid[road_y + dy][x] = ","

	# Village clearing around the spawn point.
	for y in range(6, 12):
		for x in range(2, 10):
			grid[y][x] = ","

	# Tree clusters, never on the road or the clearing.
	var clusters := 60
	for i in range(clusters):
		var cx := rng.randi_range(11, MAP_W - 4)
		var cy := rng.randi_range(2, MAP_H - 3)
		if grid[cy][cx] != ".":
			continue
		for dy in range(0, 2):
			for dx in range(0, 2):
				if grid[cy + dy][cx + dx] == ".":
					grid[cy + dy][cx + dx] = "T"

	# A small clearing on the east side for the archer and the chest.
	for y in range(4, 8):
		for x in range(MAP_W - 9, MAP_W - 2):
			if grid[y][x] == "T":
				grid[y][x] = "."

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


func _spawn_actors() -> void:
	player = _instantiate(PLAYER_SCENE, _tile_center(PLAYER_SPAWN_TILE.x, PLAYER_SPAWN_TILE.y), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	# The six villagers (Edrik, Yorek, Bran, Mila, Серис, Альвена) no longer
	# spawn here. They live in their own zone — `scripts/world/village.gd` —
	# behind `VillageGate` at the western end of the road, together with the safe
	# zone, the houses and the schedules that used to hang off this clearing. The
	# clearing itself stays painted (see `SAFE_ZONE_RECT`) so the road west runs
	# over ground, but it is empty ground now: the forest is all wild.

	var chest := _instantiate(CHEST_SCENE, _tile_center(MAP_W - 4, 5), "Chest")
	chest.name = "Chest"
	_chest_node = chest

	# Second chest, on the south-west side, holding the iron spear. The chest
	# scene is reused (not a new scene); its loot is overridden before add_child
	# so _ready() reads this chest's own opened flag, not the sword chest's.
	var spear_tile := _find_walkable_near(SPEAR_CHEST_ANCHOR, 6)
	var spear_packed: PackedScene = load(CHEST_SCENE)
	var chest_spear := spear_packed.instantiate() as Node2D
	chest_spear.name = "ChestSpear"
	chest_spear.position = _tile_center(spear_tile.x, spear_tile.y)
	chest_spear.set("chest_id", "chest_forest_02")
	chest_spear.set("item_id", "iron_spear")
	chest_spear.set("gold", 0)
	add_child(chest_spear)
	_chest_spear_node = chest_spear

	var trap := _instantiate(TRAP_SCENE, _tile_center(24, 9), "Trap")
	trap.name = "Trap"
	_trap_node = trap

	_spawn_enemy(WOLF_SCENE, 18, 14, "WolfA")
	# WolfB and WolfC sat on (21,16) and (25,13), which this seed's generated grid
	# paints as trees. The wolves walked onto grass a frame later, so a live-position
	# check never noticed; an authored-spawn check does. One tile north (21,15) and one
	# tile south (25,14) are the same pack positions on ground the map calls walkable.
	_spawn_enemy(WOLF_SCENE, 21, 15, "WolfB")
	_spawn_enemy(WOLF_SCENE, 25, 14, "WolfC")
	_spawn_enemy(WOLF_SCENE, 30, 18, "WolfD")
	_spawn_enemy(WOLF_SCENE, 34, 20, "WolfE")
	_spawn_enemy(ARCHER_SCENE, MAP_W - 6, 6, "ArcherA")

	# The two new types differ from a wolf by behaviour, not only by numbers: the
	# boar spots the player from 1.5x the sight line, charges at 1.35x the speed
	# and lands a longer, heavier, less frequent swing, while the wisp is a fragile
	# caster that kites at 1.5x speed and fires a short-telegraph shot often.
	# Their tiles come from the generated grid instead of hardcoded coordinates.
	_spawn_enemy_walkable(BOAR_SCENE, BOAR_A_ANCHOR, "BoarA")
	_spawn_enemy_walkable(BOAR_SCENE, BOAR_B_ANCHOR, "BoarB")
	_spawn_enemy_walkable(WISP_SCENE, WISP_A_ANCHOR, "WispA")
	_spawn_enemy_walkable(WISP_SCENE, WISP_B_ANCHOR, "WispB")

	# The five new predators (spec §10). They differ from everything above by
	# mechanic, not by palette: the spider chills on contact, the slime pays for
	# its slow walk by leaving a spore pool where it dies, the tick is cheap and
	# only dangerous in a pack, the lumberjack trades speed for a heavy telegraph,
	# and the root beast never leaves its tile but bites anything that steps into
	# reach. Their tiles come from `_find_new_enemy_tile`, which is the walkable
	# scan plus the two rules this half of the map needs: nothing inside the
	# village safe zone (or its buffer), and nothing closer to the arrival tile
	# than the nearest wolf post, so the hunter bot still reaches a wolf first.
	# The reserved set keeps three tick anchors whose scans overlap from
	# collapsing onto one tile.
	var new_predator_tiles := {}
	_spawn_new_enemy(SPIDER_SCENE, SPIDER_A_ANCHOR, "SpiderA", new_predator_tiles)
	_spawn_new_enemy(SPIDER_SCENE, SPIDER_B_ANCHOR, "SpiderB", new_predator_tiles)
	_spawn_new_enemy(SLIME_SCENE, SLIME_A_ANCHOR, "SlimeA", new_predator_tiles)
	_spawn_new_enemy(TICK_SCENE, TICK_A_ANCHOR, "TickA", new_predator_tiles)
	_spawn_new_enemy(TICK_SCENE, TICK_B_ANCHOR, "TickB", new_predator_tiles)
	_spawn_new_enemy(TICK_SCENE, TICK_C_ANCHOR, "TickC", new_predator_tiles)
	_spawn_new_enemy(LUMBERJACK_SCENE, LUMBERJACK_A_ANCHOR, "LumberjackA", new_predator_tiles)
	_spawn_new_enemy(ROOT_BEAST_SCENE, ROOTBEAST_A_ANCHOR, "RootBeastA", new_predator_tiles)

	# The mini-boss goes last among the enemies on purpose. It is the only enemy
	# of its type, it owns the far east corner, and its `boss` group is what the
	# HUD looks up for the boss bar — so nothing else in the world can shadow it.
	# It is also added after every other spawn so a debug bot that walks at the
	# nearest enemy still reaches a wolf first: the boss is ~39 tiles from the
	# player spawn, well outside the 230 px leash its own post allows.
	_spawn_enemy_walkable(FOREST_WARDEN_SCENE, FOREST_WARDEN_ANCHOR, "ForestWarden",
		FOREST_WARDEN_SCAN_RADIUS)

	# The second boss (spec §11) goes last among the enemies, after the warden, for
	# the same reason the warden went after the predators: it is the only enemy of its
	# type, and its tile is chosen against the set every other enemy already stands on
	# so it cannot collapse onto a post. Its node is kept as a live landmark reference.
	var boss_tiles := {}
	_root_mother_node = _spawn_boss(ROOT_MOTHER_SCENE, ROOT_MOTHER_ANCHOR, "RootMother", boss_tiles)

	_instantiate(PICKUP_SCENE, _tile_center(13, 10), "PickupA")

	# Three more finds for roadmap stage D, one per quarter of the map that did
	# not already hold one. Each tile comes from the same deterministic outward
	# scan the chests and the new enemies use, so a cluster from the fixed seed
	# can never swallow a find. They are appended AFTER PickupA on purpose: the
	# soak bot walks to the FIRST node of the `pickup` group, and that has to
	# stay the potion it banks a few tiles east of the spawn.
	_spawn_pickup("PickupHerb", _find_walkable_near(PICKUP_HERB_ANCHOR, FIND_SCAN_RADIUS),
		"wolf_fang", 2, 0)
	_spawn_pickup("PickupCoin", _find_walkable_near(PICKUP_COIN_ANCHOR, FIND_SCAN_RADIUS),
		"", 0, 35, COIN_TEXTURE)
	_spawn_pickup("PickupFlask", _find_walkable_near(PICKUP_FLASK_TILE, 0),
		"health_potion", 1, 0)

	_spawn_rubble()
	_spawn_ruins_gate()
	_spawn_village_gate()
	# The pilgrim goes last among the interactables, after both gates, so the
	# avoid set he is snapped against already knows every enemy, prop, gate and
	# find, and he cannot be parked on any of them. He is also the only villager-
	# class NPC left in the forest now that the six moved to their own zone, and
	# the debug bot no longer walks the FIRST interactable here at all — it walks
	# to the village through `VillageGate` first — so his group order is free.
	_spawn_pilgrim()


## The gate to `ruins`, at the eastern end of the road.
##
## It is appended after both chests, the trap and the rubble, and `ZoneExit`
## owns no overlap handler at all, so no bot route can reach it by accident and
## nothing can travel by walking over it. The gate is 42 tiles from the arrival
## point, far outside the 26 px interact radius.
func _spawn_ruins_gate() -> void:
	var tile := _find_walkable_near(RUINS_GATE_TILE, 0)
	var gate := ZoneExit.new()
	gate.name = "RuinsGate"
	gate.target_zone = "ruins"
	gate.prompt = "Войти в руины"
	gate.position = _tile_center(tile.x, tile.y)
	add_child(gate)
	_ruins_gate_node = gate


## The gate to `village`, at the western end of the same road. Its twin in the
## village is `ForestGate`; the two are the only doors between the wild and the
## one safe place left in the game. Like every `ZoneExit` it owns no overlap
## handler, so the west road is walked, not tripped, and the key press is the
## only thing that moves the player between the two zones.
func _spawn_village_gate() -> void:
	var tile := _find_walkable_near(VILLAGE_GATE_TILE, 0)
	var gate := ZoneExit.new()
	gate.name = "VillageGate"
	gate.target_zone = "village"
	gate.prompt = "В деревню"
	gate.position = _tile_center(tile.x, tile.y)
	add_child(gate)
	_village_gate_node = gate


## Places the pilgrim on the road east of the old clearing. Built in code (a
## `Sprite2D` child added before `add_child` so the base `Npc`'s `@onready`
## sprite resolves on the first frame); the grey tint is applied by
## `Pilgrim._ready` itself, so nothing here paints over it. He carries no quest
## and no schedule — a stranger who drifts between zones holds no post in this
## one — and he is deliberately not a landmark: a figure who is in every zone is
## not a fixed point of interest in any of them.
func _spawn_pilgrim() -> void:
	var tile := _find_pilgrim_tile(PILGRIM_ANCHOR, PILGRIM_SCAN_RADIUS, _occupied_pilgrim_tiles())
	var pilgrim := Pilgrim.new()
	pilgrim.name = "PilgrimForest"
	pilgrim.zone_id = "forest"
	pilgrim.sprite_texture = load("res://assets/sprites/npc.png")
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load("res://assets/sprites/npc.png")
	pilgrim.add_child(spr)
	pilgrim.position = _tile_center(tile.x, tile.y)
	add_child(pilgrim)


## Every tile in this zone that something already stands on and the pilgrim must not
## share: all enemies, all interactables (Edrik, the villagers, the chests, the
## gate), the finds, and the rubble — read back from the live world rather than
## hardcoded, so moving any anchor moves the pilgrim's clearance with it. The trap is
## not in any of those groups, so it is added by reference alongside the rubble.
func _occupied_pilgrim_tiles() -> Dictionary:
	var occupied := {}
	for group: StringName in [&"enemy", &"interactable", &"pickup"]:
		for node in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(node) or node.get_parent() != self:
				continue
			var body := node as Node2D
			if body == null:
				continue
			occupied[_tile_of_node(body)] = true
	for prop: Node2D in [_trap_node, _rubble_node]:
		if prop != null and is_instance_valid(prop):
			occupied[_tile_of_node(prop)] = true
	return occupied


## The pilgrim's tile: walkable ground, outside the old village clearing and its
## one-tile buffer (the keep-out that keeps the road to `VillageGate` clear of
## hostiles — a grey stranger is not something to post on the one stretch of
## this map that reads as a doorstep), at least
## `PILGRIM_CLEAR_FROM_ENTRY` tiles from the arrival tile, and clear of every tile in
## `avoid`. The declared anchor first, then the outward rings, so the named spot on
## the road wins over a tile a ring away. Deterministic like every other spawn here:
## the order depends only on the fixed anchor and the fixed grid. Falls back to the
## anchor when nothing in range passes, which the pilgrim test notices.
func _find_pilgrim_tile(anchor: Vector2i, radius: int, avoid: Dictionary) -> Vector2i:
	if _is_pilgrim_tile(anchor, avoid):
		return anchor
	for ring in range(1, radius + 1):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dy) != ring:
					continue
				var t := Vector2i(anchor.x + dx, anchor.y + dy)
				if _is_pilgrim_tile(t, avoid):
					return t
	return anchor


func _is_pilgrim_tile(tile: Vector2i, avoid: Dictionary) -> bool:
	var ch := cell_at(tile)
	if ch != "." and ch != ",":
		return false
	if SAFE_ZONE_RECT.grow(1).has_point(tile) or avoid.has(tile):
		return false
	return maxi(absi(tile.x - PLAYER_SPAWN_TILE.x), absi(tile.y - PLAYER_SPAWN_TILE.y)) >= PILGRIM_CLEAR_FROM_ENTRY


## The tile a live node stands on, in the same 16 px grid the world uses. Used to
## read the standing actors' positions back into the pilgrim separation rule
## instead of trusting hardcoded coordinates.
func _tile_of_node(node: Node2D) -> Vector2i:
	if node == null:
		return Vector2i(-9999, -9999)
	return Vector2i(
		floori(node.global_position.x / float(TILE)),
		floori(node.global_position.y / float(TILE))
	)


## Places one `Pickup` on a tile this function is handed, with its payload set
## before `add_child` so the pickup's own `_ready` reads this instance's values.
## `item_id = ""` is a valid find: the pickup then carries gold only, which is
## how the coin purse works. `texture` is the sprite the find draws; empty keeps
## the scene's own potion, which is right for every item find and wrong for a
## purse of gold — `PickupCoin` therefore names `COIN_TEXTURE` explicitly.
func _spawn_pickup(node_name: String, tile: Vector2i, item: String, count: int, coins: int,
		texture: String = "") -> void:
	var packed: PackedScene = load(PICKUP_SCENE)
	if packed == null:
		push_error("Forest: cannot load %s" % PICKUP_SCENE)
		return
	var pickup := packed.instantiate() as Node2D
	pickup.name = node_name
	pickup.position = _tile_center(tile.x, tile.y)
	pickup.set("item_id", item)
	pickup.set("amount", count)
	pickup.set("gold", coins)
	pickup.set("texture_path", texture)
	add_child(pickup)


## The south shortcut obstacle. Its tile is a fixed constant rather than a scan
## result on purpose: the whole point of the pile is that it sits in the one
## natural neck on the south side, and a scan that "improved" the position would
## silently invalidate the BFS detour the test group measures.
func _spawn_rubble() -> void:
	var packed: PackedScene = load(BREAKABLE_SCENE)
	if packed == null:
		push_error("Forest: cannot load %s" % BREAKABLE_SCENE)
		return
	var rubble := packed.instantiate() as Node2D
	rubble.name = "Rubble"
	rubble.position = _tile_center(RUBBLE_TILE.x, RUBBLE_TILE.y)
	rubble.set("blocks_shortcut_id", RUBBLE_SHORTCUT_ID)
	add_child(rubble)
	_rubble_node = rubble


## `_spawn_enemy` for a spawn whose tile is derived from the generated grid rather
## than hardcoded: the anchor is snapped to the nearest walkable tile by the same
## deterministic outward scan the chests use, so a solid tile (stone or a tree)
## can never take an enemy. Deterministic like every other spawn here, because the
## scan order depends only on the fixed seed and the fixed anchor.
func _spawn_enemy_walkable(scene_path: String, anchor: Vector2i, node_name: String, radius: int = NEW_ENEMY_SCAN_RADIUS) -> void:
	var tile := _find_walkable_near(anchor, radius)
	_spawn_enemy(scene_path, tile.x, tile.y, node_name)


## `_spawn_enemy_walkable` for the new predator types, whose tiles carry two rules
## the boar and the wisp never had to respect: the village clearing is off limits
## to a hostile, and so is the ground right around the arrival tile. Every tile
## already standing under another enemy is skipped too, so two posts whose scans
## overlap can never collapse onto one square. Deterministic like the rest of this
## file: the order depends only on the fixed seed, the fixed anchors and the fixed
## order of the calls above.
func _spawn_new_enemy(scene_path: String, anchor: Vector2i, node_name: String, taken: Dictionary) -> void:
	for tile: Vector2i in _occupied_enemy_tiles().keys():
		taken[tile] = true
	var chosen := _find_new_enemy_tile(anchor, NEW_ENEMY_SCAN_RADIUS_SMALL, taken)
	taken[chosen] = true
	_spawn_enemy(scene_path, chosen.x, chosen.y, node_name)


## `_spawn_new_enemy` for a single unique boss, returning the live node so the zone
## can keep it as a landmark reference. Same tile rules as a new predator (walkable,
## outside the safe zone and its buffer, clear of the arrival tile, not on a tile
## another enemy already holds), and the same deterministic scan.
func _spawn_boss(scene_path: String, anchor: Vector2i, node_name: String, taken: Dictionary) -> Node2D:
	for tile: Vector2i in _occupied_enemy_tiles().keys():
		taken[tile] = true
	var chosen := _find_new_enemy_tile(anchor, NEW_ENEMY_SCAN_RADIUS_SMALL, taken)
	taken[chosen] = true
	return _instantiate(scene_path, _tile_center(chosen.x, chosen.y), node_name)


## The tiles the enemies already in this zone stand on, read back from the world
## rather than tracked by hand, so a post added above this function (a wolf, a
## boar, a wisp) is automatically off limits to the ones added below it.
func _occupied_enemy_tiles() -> Dictionary:
	var occupied := {}
	for node in get_tree().get_nodes_in_group("enemy"):
		var body := node as Node2D
		if body == null or not is_instance_valid(body):
			continue
		occupied[Vector2i(floori(body.global_position.x / float(TILE)), floori(body.global_position.y / float(TILE)))] = true
	return occupied


## The declared anchor first, then the outward rings: a wide row-major scan answers
## with the top-left corner of its box rather than the anchor, which is how a post
## named for the south wood ends up three rows north of it. The anchor of each new
## predator is walkable ground in this seed, so the ordinary case is the anchor
## itself, and the rings are only the escape for a later edit to the tree clusters.
##
## Two rules a plain walkability check does not carry: a tile inside the village
## safe zone or its one-tile buffer is not free (an enemy parked there spends its
## first frames walking out, and the clearing is the one place this world promises
## is safe), and neither is a tile nearer to the arrival point than
## `NEW_ENEMY_CLEAR_FROM_SPAWN`, which is what keeps the hunter bot's nearest enemy
## a wolf. Both are applied to the candidate, never to the anchor, so a scan
## stepping around a tree cannot slip past them. Falls back to the anchor when
## nothing in range passes, which the roster test notices rather than trusts.
func _find_new_enemy_tile(anchor: Vector2i, radius: int, taken: Dictionary) -> Vector2i:
	if _is_new_enemy_tile(anchor, taken):
		return anchor
	for ring in range(1, radius + 1):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dy) != ring:
					continue
				var t := Vector2i(anchor.x + dx, anchor.y + dy)
				if _is_new_enemy_tile(t, taken):
					return t
	return anchor


func _is_new_enemy_tile(tile: Vector2i, taken: Dictionary) -> bool:
	var ch := cell_at(tile)
	if ch != "." and ch != ",":
		return false
	if SAFE_ZONE_RECT.grow(1).has_point(tile) or taken.has(tile):
		return false
	return maxi(absi(tile.x - PLAYER_SPAWN_TILE.x), absi(tile.y - PLAYER_SPAWN_TILE.y)) >= NEW_ENEMY_CLEAR_FROM_SPAWN


## The forest has no villagers and therefore no schedule to serve — the six and
## their `ScheduleComponent`s live in the village zone now — but the day cycle
## is world-owned state the HUD reads through the `day_clock` group, so the zone
## runs its own clock, exactly like the ruins, the dungeon and the fortress.
## Without it the clock line would simply go blank for as long as the player
## stood here.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
