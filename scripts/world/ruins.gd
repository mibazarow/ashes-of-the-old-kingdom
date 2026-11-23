class_name Ruins
extends ZoneBase
## The second zone: a compact stone hall reached through the gate at the eastern
## end of the forest road. The forest keeps its villagers and its generated grid;
## this zone is hand-written masonry with one puzzle in it — a door across the
## only doorway, the mechanism that opens it, the key that feeds the mechanism and
## the skeletons the door was keeping shut.
##
## The layout is written out as constants rather than rolled from a seed: a fixed
## list of wall segments, pillars and dirt patches is deterministic by
## construction, so there is no generator to keep in step and no seed to pin. The
## puzzle sits on that fixed geometry rather than next to it: the door tile is the
## middle of the doorway the wall leaves open, and everything else is placed
## relative to it.

const SKELETON_SCENE := "res://scenes/enemies/skeleton.tscn"
const SKELETON_ARCHER_SCENE := "res://scenes/enemies/skeleton_archer.tscn"
## The hall's own new guard (spec §10): the cultist caster, the only healing aura in
## the game, which is exactly why it stays behind the sealed door — the arena bot is
## sent into this hall specifically to meet a support enemy, and the hall is the one
## place in the world it is found. The shieldbearer and the royal guard the hall used
## to field here now debut in the garrison above, and the hound pair has gone down to
## the undercroft below, so the last two zones each introduce new kinds instead of
## re-fielding the hall's roster (D4-R3).
const CULTIST_CASTER_SCENE := "res://scenes/enemies/cultist_caster.tscn"
## The ruins' boss (spec §11): the Captain of the Funeral Guard, met in the hall the
## locked door keeps shut. Its shield defines phase one and its fall defines phase
## two, so it is a different fight from the hall guards rather than a tougher one.
const CAPTAIN_SCENE := "res://scenes/enemies/captain_of_the_guard.tscn"
const PICKUP_SCENE := "res://scenes/items/pickup.tscn"

const MAP_W := 40
const MAP_H := 26

## Where the forest gate drops the player, read from `data/zones.json` so the
## table stays the single place that decides an entry point.
const FOREST_GATE_TILE := Vector2i(3, 11)

## The zone's own entry tile, used only as the fallback when the data table has
## nothing usable for this zone.
const FALLBACK_ENTRY_TILE := Vector2i(3, 8)

## How far the spawn scan widens when the entry tile named in the data turns out
## to sit on something solid. Three tiles clears a single pillar or a one-tile
## wall stub without wandering across the hall.
const ENTRY_FALLBACK_SCAN_RADIUS := 3

## Inner masonry. Each rect is (position, size) in tiles and is clamped to the
## interior when painted, so a segment can never punch a hole in the border.
## The two rects on column 14 leave a doorway at rows 9..13, which is the only
## way from the entry passage into the main hall.
const INNER_WALLS: Array[Rect2i] = [
	Rect2i(14, 1, 1, 8),
	Rect2i(14, 14, 1, 11),
	Rect2i(24, 6, 9, 1),
	Rect2i(24, 18, 9, 1),
	Rect2i(6, 20, 1, 3),
]

## Standing columns. Deliberately clear of the entry tile, the gate tile and the
## doorway, so nothing solid ever lands where the player has to walk.
const PILLARS: Array[Vector2i] = [
	Vector2i(8, 4), Vector2i(8, 12), Vector2i(8, 20),
	Vector2i(19, 4), Vector2i(19, 12), Vector2i(19, 20),
	Vector2i(29, 10), Vector2i(29, 14),
	Vector2i(34, 6), Vector2i(34, 19),
]

## Worn floor, drawn as dirt. Painted before the masonry so a patch can only ever
## be covered by a wall, never the other way round.
const DIRT_PATCHES: Array[Rect2i] = [
	Rect2i(2, 7, 8, 3),
	Rect2i(16, 10, 6, 4),
	Rect2i(26, 9, 10, 8),
	Rect2i(5, 16, 5, 3),
]

## The puzzle, on the fixed geometry above.
##
## The flag the door reads and the lever raises, and the item the lever spends.
## Both live here as one pair of constants so the two props of this zone cannot be
## wired to different strings, and so a later quest can read the same flag without
## reaching into either script.
const DOOR_OPEN_FLAG := "ruin_door_open"
const KEY_ITEM := "ruin_key"

## The flag the key's pickup raises when it leaves the ground, so a rebuilt ruins
## leaves the key off the floor instead of handing out a second copy. It lives with
## the other two puzzle flags so the prop and the zone cannot drift to different
## strings.
const KEY_TAKEN_FLAG := "ruins_key_taken"

## `INNER_WALLS` leaves exactly one way from the entry passage into the hall: the
## gap at column 14, rows 9..13. The door stands on the middle row of that gap and
## is as tall as the gap itself, because a slab one tile high in an opening five
## tiles high is a pillar in a doorway: the player walks round it on either side
## and the hall is open before the puzzle is. `DOORWAY_TILES` is what the slab is
## told to cover, so editing the wall gap without editing this number leaves the
## door visibly too short rather than silently passable.
const DOORWAY_TOP_ROW := 9
const DOORWAY_BOTTOM_ROW := 13
const DOOR_TILE := Vector2i(14, 11)
const DOORWAY_TILES := DOORWAY_BOTTOM_ROW - DOORWAY_TOP_ROW + 1

## The lever on the near side of the door: the side the player arrives on, so the
## mechanism is reachable from the passage without first opening the door it
## opens. One tile west of the slab also keeps the two apart in the player's
## nearest-interactable scan — standing on the lever's tile puts it 8 px away and
## the slab 24 px, inside the same 26 px reach but clearly the nearer of the two.
const MECHANISM_TILE := Vector2i(13, 11)

## Where the key lies. The hall behind the door is what the key pays for, so the
## key itself has to be on the side the player already owns: the far end of the
## entry passage, at the south-east corner of it, fifteen tiles from the entry
## tile and the longest walk in the reachable half of the map. A key placed behind
## the door would make the door permanent, and a key placed near the entry would
## make the walk pointless.
const KEY_ANCHOR := Vector2i(11, 23)
const KEY_SCAN_RADIUS := 2

## The quest giver of this zone, and the reason the ruins are no longer a courtyard
## with a puzzle and nothing to do in it. It is a `QuestStone`, not an `Npc`: the
## hall has no inhabitants, and a slab of granite that hands out tasks needs no
## face, no schedule and no conversation.
##
## The two quests are deliberately in this order. `q04_bone_guard` names the four
## guards in the hall, which is the half of the zone the player cannot reach yet,
## so it is the one that tells him the hall exists; `q05_ruin_key` asks for the key
## and is only offered once the first is paid for. The stone starts the first quest
## on offer and offers nothing else while it is running, so the sequence is decided
## by this list rather than by anything the stone knows.
const TABLET_STONE_ID := "ruins_tablet"
const TABLET_QUEST_IDS: Array[String] = ["q04_bone_guard", "q05_ruin_key", "q06_the_crown"]

## The tablet's tile: on the near side of the door, like the lever, because a
## quest giver the player has to solve the puzzle to reach would be a reward for
## the puzzle rather than a reason to start it. South of the doorway, on the far
## side of the passage from the lever, so standing at the carving never puts the
## lever inside the same 26 px reach — the two centres are 57 px apart. Eight
## tiles east and six south of the entry tile, which is twice the four-tile minimum
## the zone asks of a prop, so arriving is never standing in somebody's prompt.
const TABLET_ANCHOR := Vector2i(11, 14)
## Zero, like the gate's: the declared tile is checked for walkability rather than
## snapped to the nearest free one, because a wide row-major scan would answer with
## the top-left corner of its box and move the quest giver somewhere else. A prop
## the map marks and the quests hang from has to stay where the zone says it is.
const TABLET_SCAN_RADIUS := 0
const TABLET_CLEAR_FROM_ENTRY := 4

## Skeleton posts, all of them in the hall behind the door: the door is what keeps
## them off the player until the puzzle is solved, and `Enemy._player_visible()`
## casts its sight ray against the world layer the door is on, so a closed slab
## really does cut the line of sight as well as the corridor. Every anchor is
## snapped by `_find_prop_tile`, so a pillar or a wall segment edited later moves
## the post with it instead of swallowing it.
const SKELETON_A_ANCHOR := Vector2i(17, 9)
const SKELETON_B_ANCHOR := Vector2i(24, 10)
const SKELETON_C_ANCHOR := Vector2i(17, 15)
const SKELETON_D_ANCHOR := Vector2i(22, 16)
const SKELETON_ARCHER_A_ANCHOR := Vector2i(20, 5)
const SKELETON_ARCHER_B_ANCHOR := Vector2i(27, 13)

## The caster (spec §10), behind the door and snapped by `_find_prop_tile`. Placed
## after the six skeletons so it inherits the reserved set the first wave already
## claimed and cannot be parked on a skeleton, and before the descent so its tile is
## visible to the collision check the stair makes at the end. It is not within six
## tiles of `DUNGEON_GATE_TILE` even after the scan has shifted it by its full
## radius, which is what the ruins test measures against every hostile in the zone
## rather than only the skeletons.
const CULTIST_CASTER_A_ANCHOR := Vector2i(26, 12)

## The Captain's post (spec §11), deep in the hall behind the door and clear of every
## guard post, pillar and the descent. It is placed after the new posts so it inherits
## the reserved set they claimed, and it keeps ten tiles from the entry — twice the
## six the guards keep — so the boss that owns the hall is never the first thing the
## player meets on arrival. Snapped by `_find_prop_tile`, so it cannot land on a prop.
const CAPTAIN_ANCHOR := Vector2i(33, 11)
const CAPTAIN_SCAN_RADIUS := 2
const CAPTAIN_CLEAR_FROM_ENTRY := 10

## How wide each post scans for a free tile, and how far every one of them has to
## stay from the tile the player arrives on. Six tiles is 96 px against the 96 px
## sight line of a plain enemy: at that Chebyshev distance a post can see the
## entry tile but cannot have been standing close enough to be on top of the
## player the frame the zone finished building.
const ENEMY_SCAN_RADIUS := 2
const ENEMY_CLEAR_FROM_ENTRY := 6

## The stair down into the undercroft, in the far south-east corner of the hall the
## door was built to keep shut. Three things put it there rather than anywhere
## else in the hall. It is behind the door, so the descent is gated by the same
## key as the hall: the puzzle pays for the zone below, not only for a room. It is
## twelve tiles from the nearest skeleton post and twenty-three from the slab, so
## nobody walks off the stair into a fight they cannot see, and the prompt of the
## stair never competes with the prompt of a post in the same 26 px reach. And it
## is the far end of the longest walk the hall asks for, which is what a stair
## hidden behind a locked door should be.
##
## Scan radius zero, like the forest gate and the tablet: the declared tile is
## checked for walkability rather than snapped to the nearest free one, because a
## wide row-major scan would answer with the top-left corner of its box and move
## the descent somewhere the map and the tests no longer agree on.
const DUNGEON_GATE_TILE := Vector2i(37, 22)
const DUNGEON_GATE_SCAN_RADIUS := 0

## The pilgrim (spec §12), the same grey stranger the forest road holds, now in the
## entry passage. He stands on the NEAR side of the locked door — the half of the
## zone the player already owns — because the fragment he carries is the reason to
## solve the puzzle, not a reward for solving it, and a story figure the player can
## only reach after the key would be a fragment held hostage. Eight tiles east and
## south of the entry, on the worn floor of the passage, clear of the door, the
## lever, the tablet and the gate. Snapped by `_find_prop_tile` against the reserved
## set every prop and post already claimed, so he cannot land on any of them.
const PILGRIM_ANCHOR := Vector2i(9, 8)
const PILGRIM_SCAN_RADIUS := 2
const PILGRIM_CLEAR_FROM_ENTRY := 6

## Points of interest kept as live node references, as in `Forest`. The key drops
## out of the list by itself once it is picked up: the pickup frees itself, and the
## loop below skips a node that is no longer there.
var _gate_node: Node2D
var _door_node: Node2D
var _mechanism_node: Node2D
var _key_node: Node2D
var _tablet_node: Node2D
var _captain_node: Node2D


## Desaturated warm stone-grey: the ruins read as pale dead masonry, not
## as grass (CRITIC-P1-01).
func tile_atlas_path() -> String:
	return "res://assets/sprites/tiles_ruins.png"


## Readability (CRITIC-P1-18): the ruins floor is a mid-tone grey, the hardest
## to separate from, so the body is driven darker than the forest's (0.32) to
## clear >=3:1 against it while the outline stays dark.
func enemy_outline_color() -> Color:
	return Color(0.043, 0.051, 0.067)


func enemy_body_tint() -> Color:
	return Color(0.32, 0.32, 0.32)


func zone_id() -> String:
	return "ruins"


func zone_name() -> String:
	return "Руины у опушки"


func music_track() -> String:
	return "music_ruins"


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		["ForestGate", "gate", _gate_node],
		["RuinDoor", "door", _door_node],
		["RuinMechanism", "mechanism", _mechanism_node],
		# The key is a landmark while it still lies on the ground, which is the
		# whole point of marking a find on the map: it tells the player the passage
		# has something worth walking its length for.
		["RuinKey", "key", _key_node],
		# The quest giver stays marked for the whole life of the zone, unlike the
		# key: a task you have already handed in is still a place worth walking
		# back to, and the stone never frees itself.
		["RuinTablet", "tablet", _tablet_node],
		# The Captain is marked so the player can find the hall's boss on the map.
		# It stays marked for the life of the zone: the boss outlives the door that
		# gated it, and a cleared hall is still the place the player came for.
		["CaptainOfTheGuard", "boss", _captain_node],
	]:
		# The validity check comes before the typed binding: assigning a freed
		# instance to `var node: Node2D` is itself a script error.
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
	var grid: Array = []
	for y in range(MAP_H):
		var row: Array = []
		for x in range(MAP_W):
			var edge := x == 0 or y == 0 or x == MAP_W - 1 or y == MAP_H - 1
			row.append("#" if edge else ".")
		grid.append(row)

	for patch: Rect2i in DIRT_PATCHES:
		_paint_rect(grid, patch, ",")
	for wall: Rect2i in INNER_WALLS:
		_paint_rect(grid, wall, "#")
	for pillar: Vector2i in PILLARS:
		if _is_interior(pillar):
			grid[pillar.y][pillar.x] = "#"

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


## Paints one rect with a character, clipped to the interior so the border wall
## stays solid no matter how the constants are edited later.
func _paint_rect(grid: Array, rect: Rect2i, ch: String) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if not _is_interior(Vector2i(x, y)):
				continue
			grid[y][x] = ch


func _is_interior(tile: Vector2i) -> bool:
	return tile.x > 0 and tile.y > 0 and tile.x < MAP_W - 1 and tile.y < MAP_H - 1


func _spawn_actors() -> void:
	# The entry tile comes from the data table, snapped to the nearest walkable
	# cell so a hand-edited `entry_tile` that lands on a pillar still spawns a
	# player standing on floor. Radius 3 is enough to step off a single pillar or
	# a one-tile wall stub without wandering across the hall.
	var entry := ZoneManager.entry_tile(zone_id())
	if entry == Vector2i.ZERO:
		entry = FALLBACK_ENTRY_TILE
	var spawn_tile := _entry_spawn_tile(entry)
	player = _instantiate(PLAYER_SCENE, _tile_center(spawn_tile.x, spawn_tile.y), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	# The way back. Its tile is a fixed constant checked for walkability by a
	# radius-0 scan rather than snapped by a wide one: the gate marks the spot the
	# player arrived at, and a scan free to move it would silently relocate the
	# only exit in the zone. Three tiles from the entry tile, so arriving never
	# opens the prompt under the player's feet.
	var gate_tile := _find_walkable_near(FOREST_GATE_TILE, 0)
	var gate := ZoneExit.new()
	gate.name = "ForestGate"
	gate.target_zone = "forest"
	gate.prompt = "Вернуться в лес"
	gate.position = _tile_center(gate_tile.x, gate_tile.y)
	add_child(gate)
	_gate_node = gate

	# The puzzle is placed before the posts that guard it, so the tiles it occupies
	# — the slab, the lever, the key, the gate — are already reserved while the
	# posts are still being snapped and none of them can land on a prop.
	var key_tile := _find_walkable_near(KEY_ANCHOR, KEY_SCAN_RADIUS)
	var reserved := {
		DOOR_TILE: true,
		MECHANISM_TILE: true,
		key_tile: true,
		gate_tile: true,
	}
	# The tablet is snapped against the same reserved set the props already took,
	# and its own tile joins that set before the posts are placed, so a skeleton can
	# never be parked on top of the quest giver.
	var tablet_tile := _find_prop_tile(
		TABLET_ANCHOR, TABLET_SCAN_RADIUS, spawn_tile, reserved, TABLET_CLEAR_FROM_ENTRY)
	reserved[tablet_tile] = true
	_spawn_door()
	_spawn_mechanism()
	_spawn_key(key_tile)
	_spawn_tablet(tablet_tile)
	_spawn_skeletons(spawn_tile, reserved)
	_spawn_new_posts(spawn_tile, reserved)
	# The Captain is placed after every guard so it inherits the reserved set they
	# claimed and cannot be parked on a post, and before the descent so its tile is
	# visible to the collision check the stair makes at the end.
	_spawn_captain(spawn_tile, reserved)
	# Last, after every post has had its turn at the reserved set. The stair's tile
	# is a fixed constant rather than a scan, so the order cannot move it, but the
	# reserved set is the only thing here that knows which tiles the posts ended up
	# on, and reading it after they are placed means an edit to a post anchor that
	# walks a skeleton onto the stair shows up as a collision this function can see
	# instead of two props sharing one tile in silence.
	_spawn_dungeon_gate(spawn_tile, reserved)
	# The pilgrim is placed after every prop, post and stair so he inherits the whole
	# reserved set they claimed and cannot be parked on the door, the lever, the key,
	# the tablet, a guard or either gate. His tile is the entry passage, snapped by
	# `_find_prop_tile` against that set with the six-tile clearance the zone asks of
	# a prop that is not a hostile.
	_spawn_pilgrim(spawn_tile, reserved)


## The slab across the doorway. Built in code the way `ZoneExit`, the merchant and
## the smith are: a prop with no sprite of its own needs no scene file, and a node
## assembled here cannot drift away from the tile constant that places it. The
## height is handed over before the node enters the tree, because the slab builds
## its own collision shape in `_ready` and has to be told how tall the zone's own
## opening is before that happens.
func _spawn_door() -> void:
	var door := RuinDoor.new()
	door.name = "RuinDoor"
	door.door_id = "ruin_door"
	door.open_flag = DOOR_OPEN_FLAG
	door.opening_tiles = DOORWAY_TILES
	door.position = _tile_center(DOOR_TILE.x, DOOR_TILE.y)
	add_child(door)
	_door_node = door


## The lever that spends the key. It names the flag by string and never the door
## by path, so the door it belongs to is whichever door answers to that flag.
func _spawn_mechanism() -> void:
	var lever := Mechanism.new()
	lever.name = "RuinMechanism"
	lever.mechanism_id = "ruin_mechanism"
	lever.requires_item = KEY_ITEM
	lever.sets_flag = DOOR_OPEN_FLAG
	lever.position = _tile_center(MECHANISM_TILE.x, MECHANISM_TILE.y)
	add_child(lever)
	# The lever is also the `use` objective of q05: when it falls, the quest manager
	# is told which mechanism moved, so a `use` quest aimed at this mechanism advances.
	# The connection lives here, beside the node that owns the signal, so the lever
	# never has to know quests exist.
	lever.triggered.connect(_on_mechanism_triggered)
	_mechanism_node = lever


## A world mechanism finished its motion. Forwarded to the quest manager as a `use`
## event keyed by the mechanism's own id, which is exactly the `use` target a quest
## names; quests aimed at any other mechanism (or none) are untouched.
func _on_mechanism_triggered(mechanism_id: String) -> void:
	QuestManager.notify_objective_used(mechanism_id)


## The key, lying on the ground and collected by walking over it like every other
## find. The forest's pickup scene is reused rather than duplicated; its sprite is
## a potion, so the icon is tinted rust to read as something else on the floor.
func _spawn_key(tile: Vector2i) -> void:
	var packed: PackedScene = load(PICKUP_SCENE)
	if packed == null:
		push_error("Ruins: cannot load %s" % PICKUP_SCENE)
		return
	var pickup := packed.instantiate() as Node2D
	pickup.name = "RuinKey"
	pickup.position = _tile_center(tile.x, tile.y)
	pickup.set("item_id", KEY_ITEM)
	pickup.set("amount", 1)
	pickup.set("gold", 0)
	# The key is a one-off find: once it is in the bag it must not lie in the
	# passage again on the next rebuild of this zone, which travel does every time
	# the player walks back through the forest gate.
	pickup.set("taken_flag", KEY_TAKEN_FLAG)
	var sprite := pickup.get_node_or_null("Sprite2D") as Sprite2D
	if sprite != null:
		sprite.modulate = Color(0.85, 0.62, 0.35)
	add_child(pickup)
	_key_node = pickup


## The carved slab that hands out the zone's two quests. Built in code like the
## door and the lever: a prop with no sprite of its own needs no scene file, and a
## node assembled here cannot drift away from the tile constant that places it. The
## quest list is handed over as a copy rather than the constant itself, because a
## `const` array is read-only and an exported `Array[String]` is a live property a
## later editor session could append to.
func _spawn_tablet(tile: Vector2i) -> void:
	var tablet := QuestStone.new()
	tablet.name = "RuinTablet"
	tablet.stone_id = TABLET_STONE_ID
	tablet.quest_ids = TABLET_QUEST_IDS.duplicate()
	tablet.position = _tile_center(tile.x, tile.y)
	add_child(tablet)
	_tablet_node = tablet


## Four guards and two bowmen on their own posts. Each tile is marked reserved as
## it is taken, so two posts whose anchors are close can never collapse onto the
## same tile once the grid nudges them.
func _spawn_skeletons(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[SKELETON_SCENE, SKELETON_A_ANCHOR, "SkeletonA"],
		[SKELETON_SCENE, SKELETON_B_ANCHOR, "SkeletonB"],
		[SKELETON_SCENE, SKELETON_C_ANCHOR, "SkeletonC"],
		[SKELETON_SCENE, SKELETON_D_ANCHOR, "SkeletonD"],
		[SKELETON_ARCHER_SCENE, SKELETON_ARCHER_A_ANCHOR, "SkeletonArcherA"],
		[SKELETON_ARCHER_SCENE, SKELETON_ARCHER_B_ANCHOR, "SkeletonArcherB"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## The caster, on the same reserved-tile flow as the skeletons and placed right after
## them, so every tile the first wave took is already off limits and every tile this
## post takes is still visible to the collision check the descent makes when it is
## placed last. It is the only healing aura in the game and the reason the hall is
## worth opening: the arena bot is sent behind this door specifically to meet a
## support enemy, so it stays. The shieldbearer and the royal guard the hall used to
## field here now debut in the garrison above, and the hound pair has gone down to
## the undercroft below (D4-R3).
func _spawn_new_posts(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[CULTIST_CASTER_SCENE, CULTIST_CASTER_A_ANCHOR, "CultistCasterA"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## The hall's boss (spec §11), snapped against the reserved set the props and the
## guards already claimed and kept ten tiles from the arrival point. Its node is kept
## as a live landmark reference so the map can mark the boss.
func _spawn_captain(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		CAPTAIN_ANCHOR, CAPTAIN_SCAN_RADIUS, entry, reserved, CAPTAIN_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	_captain_node = _instantiate(CAPTAIN_SCENE, _tile_center(tile.x, tile.y), "CaptainOfTheGuard")


## The stair down to the third zone, at the far end of the hall the door guards.
## Built in code like the gate, the door and the lever: a `ZoneExit` has no sprite
## of its own and draws itself, so a node assembled here cannot drift away from the
## tile constant that places it, and the descent cannot be edited out of existence
## by a scene edit. It is deliberately not a landmark: the map marks the four pieces
## of the puzzle that opens this hall, and the stair is what the puzzle pays for, so
## marking it on the map would hand the player the reward before the question.
func _spawn_dungeon_gate(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		DUNGEON_GATE_TILE, DUNGEON_GATE_SCAN_RADIUS, entry, reserved, 0)
	reserved[tile] = true
	var gate := ZoneExit.new()
	gate.name = "DungeonGate"
	gate.target_zone = "dungeon"
	gate.prompt = "Спуститься в подземелье"
	gate.position = _tile_center(tile.x, tile.y)
	add_child(gate)


## The grey stranger in the entry passage. Built in code like the villagers (a
## `Sprite2D` child added before `add_child` so the base `Npc`'s `@onready` sprite
## resolves on the first frame); the grey tint is applied by `Pilgrim._ready`
## itself. He carries no quest and no schedule and is deliberately not a landmark —
## the map keeps its six markers, and a figure who is in every zone is not a fixed
## point of interest in this one.
func _spawn_pilgrim(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		PILGRIM_ANCHOR, PILGRIM_SCAN_RADIUS, entry, reserved, PILGRIM_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	var pilgrim := Pilgrim.new()
	pilgrim.name = "PilgrimRuins"
	pilgrim.zone_id = "ruins"
	pilgrim.sprite_texture = load("res://assets/sprites/npc.png")
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load("res://assets/sprites/npc.png")
	pilgrim.add_child(spr)
	pilgrim.position = _tile_center(tile.x, tile.y)
	add_child(pilgrim)


## The outward row-major scan of `ZoneBase._find_walkable_near` with two rules
## added: a tile a prop already stands on is not free, and neither is a tile
## closer than `clear_from_entry` to the tile the player arrives on (Chebyshev, so
## the diagonal counts as close too). Deterministic for the same reason the base
## scan is — the order depends only on the anchor and the grid.
##
## The clearance is a parameter rather than the one constant it was, because the
## two callers ask for different things of the same rule: a skeleton has to stay
## six tiles off the arrival point so nobody spawns inside a post's sight line,
## while a stone tablet only has to stay out of the prompt that would open under
## the player's feet.
func _find_prop_tile(
		anchor: Vector2i,
		radius: int,
		entry: Vector2i,
		reserved: Dictionary,
		clear_from_entry: int
	) -> Vector2i:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var t := Vector2i(anchor.x + dx, anchor.y + dy)
			if not _is_walkable(t) or reserved.has(t):
				continue
			if maxi(absi(t.x - entry.x), absi(t.y - entry.y)) < clear_from_entry:
				continue
			return t
	return anchor


func _is_walkable(tile: Vector2i) -> bool:
	var ch := cell_at(tile)
	return ch == "." or ch == ","


## The tile the player arrives on: the entry point named in `data/zones.json`,
## unless that cell turns out to be solid, in which case the nearest walkable
## one.
##
## `ZoneBase._find_walkable_near` cannot simply be handed the entry tile with a
## radius, because it returns the first walkable cell of its scan box in
## row-major order rather than preferring the anchor — asked about (3, 8) with a
## radius of 3 it answers (1, 5), which is a different place entirely. The
## declared tile is where the player is meant to arrive, so it is used whenever it
## is walkable, and the base scan is only reached as the fallback for data that
## put an entry point inside a pillar.
func _entry_spawn_tile(entry: Vector2i) -> Vector2i:
	if _is_walkable(entry):
		return entry
	for radius in range(1, ENTRY_FALLBACK_SCAN_RADIUS + 1):
		var candidate := _find_walkable_near(entry, radius)
		if _is_walkable(candidate):
			return candidate
	return entry


## The ruins have no villagers and therefore no schedule to serve, but the day
## cycle is world-owned state the HUD reads through the `day_clock` group, so the
## zone runs its own clock. Without it the clock line would simply go blank for
## as long as the player stood here.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
