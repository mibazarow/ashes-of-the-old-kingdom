class_name Forest
extends ZoneBase
## The first zone. Builds the forest slice at runtime: the grid from a fixed
## seed, props and spawns, the village safe zone and the villager schedules.
## Everything generic (grid reader, tileset build, exploration, camera, spawn
## scans, schedule wiring) lives in `ZoneBase`; this file is content only.

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
const NPC_SCENE := "res://scenes/npcs/edrik.tscn"
const VILLAGER_SCRIPT := "res://scripts/npcs/villager.gd"
const CHEST_SCENE := "res://scenes/interactables/chest.tscn"
const TRAP_SCENE := "res://scenes/interactables/spike_trap.tscn"
const PICKUP_SCENE := "res://scenes/items/pickup.tscn"
const BREAKABLE_SCENE := "res://scenes/world/breakable.tscn"

## Map is generated once from a fixed seed so every run and every test sees the
## same layout, while staying readable instead of a 60-line string literal.
const MAP_W := 52
const MAP_H := 32
const MAP_SEED := 20261107

## Points of interest kept as live node references so the map can show them
## without fragile path lookups. Populated in _spawn_actors.
var _npc_node: Node2D
var _merchant_node: Node2D
var _smith_node: Node2D
var _mila_node: Node2D
var _seris_node: Node2D
var _alvena_node: Node2D
var _chest_node: Node2D
var _chest_spear_node: Node2D
var _trap_node: Node2D
var _rubble_node: Node2D
var _ruins_gate_node: Node2D
var _root_mother_node: Node2D

## Fixed anchor for the spear chest, on the south-west side away from the sword
## chest in the east clearing. The exact tile is derived from the generated grid
## (see _find_walkable_near), so the spawn stays deterministic and never lands
## inside a tree cluster.
const SPEAR_CHEST_ANCHOR := Vector2i(12, 24)

## Anchor for the smith's forge, on the road just east of the village clearing.
## He is kept well outside Edrik's interact radius on purpose (see
## `_find_walkable_away`): the debug bot walks up to Edrik and presses E on the
## NEAREST interactable, so a forge within reach would steal the quest dialogue
## and the turn-in and break every quest bot.
const SMITH_ANCHOR := Vector2i(12, 12)

## Tile distance the smith must keep from the quest-giver, the merchant and the
## spawn point. 4 tiles is 64 px against a 26 px interact radius and an 18 px bot
## stop tolerance, so standing at Edrik can never put the forge inside reach.
const SMITH_MIN_SEPARATION := 4

## The village safe zone, in tiles: the dirt clearing the west of the map is built
## around (rows 6..11 x cols 2..9) plus a one-tile buffer on every side, so an
## enemy is turned back before it can reach a villager rather than at their feet.
## `Enemy` reads this through the `safe_zone_owner` group and refuses to step a
## single frame's move inside it, and walks straight out if it is ever inside.
const SAFE_ZONE_RECT := Rect2i(2, 5, 9, 8)

## Anchor for the third villager, the herbwife. She sits on the clearing among the
## other villagers but a few tiles from Edrik, the merchant and the spawn, so the
## debug bot walking to the FIRST interactable (Edrik) never comes within the
## interact radius of her and never has her dialogue stolen (see
## `_find_walkable_away`). The tile is derived from the generated grid, so she is
## never placed in a tree.
const MILA_ANCHOR := Vector2i(5, 7)
const MILA_MIN_SEPARATION := 3

## Anchors for the two newest villagers (spec §12): the miller Серис and the
## tanner Альвена. Both anchors are tiles of the village clearing (rows 6..11 x
## cols 2..9, all dirt), so the anchor itself is walkable ground and inside the
## safe zone, and `_find_villager_tile` returns it unchanged on this seed. Серис
## takes the west edge by the water chute his mill would use; Альвена takes the
## north-east corner, the three tiles from the forge that read as a pair beside
## the smith without standing within his reach.
const SERIS_ANCHOR := Vector2i(2, 6)
const ALVENA_ANCHOR := Vector2i(8, 6)

## How far the two new villagers keep from every other villager, the merchant,
## the smith and the arrival tile (Chebyshev). Three tiles is 48 px against the
## 26 px interact radius and the 18 px bot stop tolerance, so standing at Edrik
## can never bring a newcomer inside reach and steal a quest dialogue — the same
## margin the herbwife is held to.
const VILLAGER_MIN_SEPARATION := 3

## How wide the villager scan looks around an anchor when the anchor itself fails
## a rule. Three tiles clears a one-tile tree edge without wandering a villager
## out of the clearing its anchor names.
const VILLAGER_SCAN_RADIUS := 3

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


func zone_id() -> String:
	return "forest"


func zone_name() -> String:
	return "Лесной край"


func music_track() -> String:
	return "music_forest"


func ambience_track() -> String:
	return "ambience_forest"


## Advertise the safe zone before any actor is spawned, so an enemy created in
## `_spawn_actors` can already resolve this world through the group and honour
## the boundary from its very first physics frame.
func _advertise_zone() -> void:
	add_to_group("safe_zone_owner")


## The village safe zone rectangle, exposed so `Enemy` and a test read the exact
## same rect the world enforces rather than a copy of its numbers.
func safe_zone_rect() -> Rect2i:
	return SAFE_ZONE_RECT


## True when `tile` falls inside the village safe zone. `Enemy` converts its own
## world position to a tile and asks this each frame; the hostiles keep out.
func is_in_safe_zone(tile: Vector2i) -> bool:
	return SAFE_ZONE_RECT.has_point(tile)


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		["Edrik", "npc", _npc_node],
		["Yorek", "npc", _merchant_node],
		["Bran", "npc", _smith_node],
		["Mila", "npc", _mila_node],
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

	var npc := _instantiate(NPC_SCENE, _tile_center(7, 9), "Edrik")
	npc.name = "Edrik"
	_npc_node = npc

	# The merchant is added after Edrik on purpose: the debug bot picks the first
	# node in the `interactable` group, so Edrik must stay first or the quest bots
	# would open the shop instead of the dialogue. It sits on the village clearing
	# (dirt, walkable, never a tree cluster), far enough from the spawn point that
	# no prompt shows at start and far enough from Edrik that walking to him never
	# comes within the interact radius of the shop.
	var merchant := Merchant.new()
	merchant.name = "Yorek"
	merchant.sprite_texture = load("res://assets/sprites/npc.png")
	merchant.position = _tile_center(3, 11)
	add_child(merchant)
	_merchant_node = merchant

	# The smith joins last among the village NPCs, after Edrik and Yorek, for the
	# same reason the merchant does: the debug bot picks the FIRST node of the
	# `interactable` group, so Edrik must stay first or the quest bots would open a
	# bench instead of the dialogue. His tile is chosen by `_find_walkable_away` so
	# that he is also outside the interact radius of anyone standing at Edrik.
	var smith := Smith.new()
	smith.name = "Bran"
	smith.sprite_texture = load("res://assets/sprites/npc.png")
	var smith_tile := _find_walkable_away(
		SMITH_ANCHOR, 4, [Vector2i(7, 9), Vector2i(3, 11), Vector2i(4, 9)], SMITH_MIN_SEPARATION)
	smith.position = _tile_center(smith_tile.x, smith_tile.y)
	add_child(smith)
	_smith_node = smith

	# The herbwife joins last among the village NPCs, after Edrik, Yorek and Bran,
	# for the same reason they each joined after the one before: the debug bot picks
	# the FIRST node of the `interactable` group, so Edrik must stay first. She is a
	# `Villager` (a multi-quest giver) built in code like the merchant and the smith,
	# given both of her quests and placed by `_find_walkable_away` a few tiles from
	# Edrik, the merchant and the spawn, so standing at Edrik never reaches her.
	var mila_script: GDScript = load(VILLAGER_SCRIPT)
	var mila: Node2D = mila_script.new() as Node2D
	mila.name = "Mila"
	mila.set("display_name", "Травница Мила")
	mila.set("speaker_id", "mila")
	mila.set("sprite_texture", load("res://assets/sprites/npc.png"))
	mila.set("quest_ids", PackedStringArray(["q02_gather_fangs", "q03_clear_boars"]))
	# The base `Npc` scene carries a `Sprite2D` child that its `_ready` reaches for
	# through an `@onready`; a code-built villager has no scene, so the sprite is
	# added here, before `add_child`, so the lookup resolves on the first frame.
	var mila_sprite := Sprite2D.new()
	mila_sprite.name = "Sprite2D"
	mila_sprite.texture = load("res://assets/sprites/npc.png")
	mila.add_child(mila_sprite)
	var mila_tile := _find_walkable_away(
		MILA_ANCHOR, 3, [Vector2i(7, 9), Vector2i(3, 11), Vector2i(4, 9)], MILA_MIN_SEPARATION)
	mila.position = _tile_center(mila_tile.x, mila_tile.y)
	add_child(mila)
	_mila_node = mila

	# The two newest villagers (spec §12/§13) join after Mila and before the chests,
	# for the same reason every villager joined after the one before: the debug bot
	# picks the FIRST node of the `interactable` group, so Edrik must stay first or
	# the quest bots would open a mill instead of the hunt dialogue. Each is a
	# `Villager` built in code like the herbwife, carrying one of the new quests,
	# placed by `_find_villager_tile` on the clearing so it is walkable, inside the
	# safe zone and at least `VILLAGER_MIN_SEPARATION` tiles from every other
	# villager, the merchant, the smith and the arrival tile. The avoid list is read
	# back from the live nodes rather than hardcoded, so moving an anchor above
	# moves the clearance with it.
	var villager_avoid: Array[Vector2i] = [
		PLAYER_SPAWN_TILE,
		_tile_of_node(_npc_node),
		_tile_of_node(_merchant_node),
		_tile_of_node(_smith_node),
		_tile_of_node(_mila_node),
	]
	var seris_tile := _find_villager_tile(SERIS_ANCHOR, villager_avoid, VILLAGER_MIN_SEPARATION)
	_seris_node = _spawn_villager("Seris", "Мельник Серис", "seris",
		PackedStringArray(["q09_the_mill"]), seris_tile, Color(0.62, 0.78, 0.95))
	var alvena_avoid: Array[Vector2i] = villager_avoid.duplicate()
	alvena_avoid.append(seris_tile)
	var alvena_tile := _find_villager_tile(ALVENA_ANCHOR, alvena_avoid, VILLAGER_MIN_SEPARATION)
	_alvena_node = _spawn_villager("Alvena", "Кожевница Альвена", "alvena",
		PackedStringArray(["q10_armor_fit"]), alvena_tile, Color(0.95, 0.80, 0.55))

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
		"", 0, 35)
	_spawn_pickup("PickupFlask", _find_walkable_near(PICKUP_FLASK_TILE, 0),
		"health_potion", 1, 0)

	_spawn_rubble()
	_spawn_ruins_gate()


## The gate to `ruins`, at the eastern end of the road.
##
## It is appended after every other interactable in the zone — Edrik, Yorek,
## Bran, Mila, both chests, the trap and the rubble — for the same reason each
## villager joined after the one before: the debug bot walks the FIRST node of the
## `interactable` group, so Edrik has to stay first or the quest bots would open a
## gate instead of the dialogue. The gate is also 42 tiles from Edrik, far outside
## the 26 px interact radius, and `ZoneExit` owns no overlap handler at all, so no
## bot route can reach it and nothing can travel by walking over it.
func _spawn_ruins_gate() -> void:
	var tile := _find_walkable_near(RUINS_GATE_TILE, 0)
	var gate := ZoneExit.new()
	gate.name = "RuinsGate"
	gate.target_zone = "ruins"
	gate.prompt = "Войти в руины"
	gate.position = _tile_center(tile.x, tile.y)
	add_child(gate)
	_ruins_gate_node = gate


## Builds one `Villager` in code (the herbwife's type) and places it on `tile`,
## carrying `quests` as its offer list. Mirrors exactly what the Mila block in
## `_spawn_actors` does by hand: a `Sprite2D` child is added before `add_child` so
## the base `Npc`'s `@onready` sprite lookup resolves on the first frame, and the
## per-villager `tint` is applied AFTER `add_child` because `Villager._ready`
## paints every herbwife the same green and would otherwise overwrite it. Returns
## the live node so the caller can keep it as a landmark/schedule reference.
func _spawn_villager(node_name: String, display: String, speaker: String,
		quests: PackedStringArray, tile: Vector2i, tint: Color) -> Node2D:
	var script: GDScript = load(VILLAGER_SCRIPT)
	if script == null:
		push_error("Forest: cannot load %s" % VILLAGER_SCRIPT)
		return null
	var villager: Node2D = script.new() as Node2D
	villager.name = node_name
	villager.set("display_name", display)
	villager.set("speaker_id", speaker)
	villager.set("sprite_texture", load("res://assets/sprites/npc.png"))
	villager.set("quest_ids", quests)
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load("res://assets/sprites/npc.png")
	villager.add_child(spr)
	villager.position = _tile_center(tile.x, tile.y)
	add_child(villager)
	spr.modulate = tint
	return villager


## The tile a new villager stands on: the anchor when it passes every rule, else
## the first ring tile that does, scanning outward ring-by-ring so the declared
## corner of the clearing wins over a tile a ring away. Three rules a plain
## walkability check does not carry: the tile must be inside the village safe zone
## (a villager belongs in the clearing the enemies are turned back from), and it
## must keep `min_distance` tiles (Chebyshev) from every point in `avoid` so the
## debug bot walking to Edrik never comes within the interact radius of anyone
## else. Deterministic like every other spawn here: the order depends only on the
## fixed anchors and the fixed grid. Falls back to the anchor when nothing in
## range passes, which the villager test group notices rather than trusts.
func _find_villager_tile(anchor: Vector2i, avoid: Array[Vector2i], min_distance: int) -> Vector2i:
	if _is_villager_tile(anchor, avoid, min_distance):
		return anchor
	for ring in range(1, VILLAGER_SCAN_RADIUS + 1):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dy) != ring:
					continue
				var t := Vector2i(anchor.x + dx, anchor.y + dy)
				if _is_villager_tile(t, avoid, min_distance):
					return t
	return anchor


func _is_villager_tile(tile: Vector2i, avoid: Array[Vector2i], min_distance: int) -> bool:
	var ch := cell_at(tile)
	if ch != "." and ch != ",":
		return false
	if not SAFE_ZONE_RECT.has_point(tile):
		return false
	for point: Vector2i in avoid:
		if maxi(absi(tile.x - point.x), absi(tile.y - point.y)) < min_distance:
			return false
	return true


## The tile a live node stands on, in the same 16 px grid the world uses. Used to
## read the existing villagers' positions back into the newcomer separation rule
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
## how the coin purse works.
func _spawn_pickup(node_name: String, tile: Vector2i, item: String, count: int, coins: int) -> void:
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


## Builds the day cycle and gives every scheduled villager a `ScheduleComponent`.
## The clock is added first so its `_ready` (which loads `data/schedules.json` and
## seeds the morning phase) runs before any component reads `phase()`. The smith
## keeps his forge tile: his schedule morning spot is the tile `_find_walkable_away`
## already chose, so attaching a schedule never drags him into the village and
## never breaks the separation that keeps the quest bots talking to Edrik.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
	_attach_schedule(_npc_node)
	_attach_schedule(_merchant_node)
	_attach_schedule(_smith_node)
	_attach_schedule(_mila_node)
	_attach_schedule(_seris_node)
	_attach_schedule(_alvena_node)
