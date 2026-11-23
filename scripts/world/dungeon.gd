class_name Dungeon
extends ZoneBase
## The third zone: the flooded undercroft beneath the ruins, reached down the
## stair in the guarded hall. The ruins hand the player a door, a lever and a key;
## what the key pays for is this place, so the zone below has to be a place worth
## the walk rather than one more corridor.
##
## Like the ruins, the layout is written out as constants instead of rolled from a
## seed: a fixed list of masonry blocks, columns, floor patches, chokepoint stubs
## and alcoves is deterministic by construction, so there is no generator to keep
## in step and no seed to pin. Unlike the ruins, this zone is not a hall. Spec §5.1
## asks for corridors that loop back on themselves, so the grid is built as the
## negative space of eight masonry blocks: three horizontal corridors (rows 1..3,
## 12..14, 24..26) crossed by four vertical ones (columns 1..3, 12..14, 24..26,
## 37..39), each three tiles wide. Every crossing is a way round, which is what
## makes the map cyclic rather than a branchy dead-end tree, and the four stubs
## that push off a block face into a corridor narrow it to two tiles without ever
## closing it — those are the places the traps sit, on ground the player can see
## the far side of before committing to it.
##
## The three alcoves are the other half of the shape: pockets carved into a block,
## open on one side only, so the map has rooms to find as well as roads to walk.
## They are carved after the masonry, which is why carving is a paint of its own
## rather than an absence of wall.

const SKELETON_SCENE := "res://scenes/enemies/skeleton.tscn"
const SKELETON_ARCHER_SCENE := "res://scenes/enemies/skeleton_archer.tscn"
const WISP_SCENE := "res://scenes/enemies/wisp.tscn"
## The three new undercroft types (spec §10, D4-R3): the crawler is a fast, low
## melee pest that closes the corridor before you read it, the bearer is a slow
## carrier whose corpse turns the ground it fell on into `blight` for anyone
## standing there, and the hound — brought down from the hall above so the
## undercroft introduces three kinds the player has not met rather than two — is
## only dangerous in pairs, which is what makes the two of them a pack rather than
## two lone crawlers.
const BONE_CRAWLER_SCENE := "res://scenes/enemies/bone_crawler.tscn"
const PLAGUE_BEARER_SCENE := "res://scenes/enemies/plague_bearer.tscn"
const GRAVE_HOUND_SCENE := "res://scenes/enemies/grave_hound.tscn"
## The undercroft's boss (spec §11): the Bell Ringer of the Empty Crypt, met deep
## past the trap plates. Its ringing shock wave and phase-two hazard circles make it
## a fight about ground and spacing, not another skeleton with a bigger pool.
const BELL_RINGER_SCENE := "res://scenes/enemies/bell_ringer.tscn"
const TRAP_SCENE := "res://scenes/interactables/spike_trap.tscn"

const MAP_W := 44
const MAP_H := 28

## The zone's own entry tile, used only as the fallback when the data table has
## nothing usable for this zone. It is the same tile `data/zones.json` names, and
## it sits in the west end of the middle corridor, where that corridor meets the
## west one — the one spot in the zone from which all three horizontal and all
## four vertical corridors are one turn away.
const FALLBACK_ENTRY_TILE := Vector2i(3, 12)

## How far the spawn scan widens when the entry tile named in the data turns out
## to sit on something solid. Three tiles clears a single column or a one-tile
## stub without wandering out of the crossing.
const ENTRY_FALLBACK_SCAN_RADIUS := 3

## The stair back up, in the west corridor two tiles north of the arrival tile:
## close enough that a player who came down to look around can leave without
## walking the zone, far enough that arriving never opens the prompt under his
## feet. A radius-0 scan checks the declared tile rather than snapping it to the
## nearest free one, because a wide row-major scan would answer with the top-left
## corner of its box and move the stair somewhere else.
const RUINS_EXIT_TILE := Vector2i(2, 10)

## The door to the fourth zone, in the far north-east corner of the undercroft: the
## tile the walk from the stair is longest to reach (50 steps against the 25 that
## cross the zone end to end), the one that takes the player past the plate on the
## narrowed stretch of the middle corridor before it opens, and the one furthest
## from every post, plate and column in the zone — ten tiles from the nearest of
## them, so the door never shares a prompt with a skeleton and nobody spawns in the
## doorway. A door to the fortress belongs at the end of the longest road the
## undercroft asks for, not at the first free corner.
##
## Scan radius zero, like the ruins' descent: the declared tile is checked for
## walkability rather than snapped to the nearest free one, because a wide
## row-major scan would answer with the top-left corner of its box and move the
## ascent somewhere the map and the tests no longer agree on.
const FORTRESS_GATE_TILE := Vector2i(42, 1)
const FORTRESS_GATE_SCAN_RADIUS := 0

## The masonry. Eight blocks, each one the mass between two neighbouring
## corridors, and each clamped to the interior when painted, so no block can ever
## punch a hole in the border however these numbers are edited later. Together
## they are the whole map: what is left of the floor between them is the corridor
## network, which is why widening one block is the same edit as narrowing the
## corridor beside it.
const WALL_BLOCKS: Array[Rect2i] = [
	Rect2i(4, 4, 8, 8),
	Rect2i(15, 4, 9, 8),
	Rect2i(27, 4, 10, 8),
	Rect2i(40, 4, 3, 8),
	Rect2i(4, 15, 8, 9),
	Rect2i(15, 15, 9, 9),
	Rect2i(27, 15, 10, 9),
	Rect2i(40, 15, 3, 9),
]

## Standing columns, one in the middle of each crossing where two corridors meet.
## A single tile in a three-by-three crossing leaves every arm of the crossing
## reachable without squeezing, so the columns read as a colonnade and never as a
## wall, and no column stands on the entry tile, on the stair or on a trap plate.
const PILLARS: Array[Vector2i] = [
	Vector2i(2, 2), Vector2i(13, 2), Vector2i(25, 2), Vector2i(38, 2),
	Vector2i(2, 13), Vector2i(13, 13), Vector2i(25, 13), Vector2i(38, 13),
	Vector2i(2, 25), Vector2i(13, 25), Vector2i(25, 25), Vector2i(38, 25),
]

## Worn and flooded floor, drawn as dirt: the undercroft is stone, so the only
## ground texture this zone has is damp. Painted before the masonry so a patch can
## only ever be covered by a wall, never the other way round.
const DIRT_PATCHES: Array[Rect2i] = [
	Rect2i(2, 1, 7, 3),
	Rect2i(28, 1, 8, 3),
	Rect2i(30, 12, 6, 3),
	Rect2i(5, 24, 7, 3),
	Rect2i(37, 16, 3, 6),
]

## Chokepoints. Each stub is one tile thick and grows off the face of a block into
## the corridor beside it, which takes that corridor from three tiles wide to two
## and never to one: a stub floating in the middle of a three-tile passage would
## leave two one-tile slits, and a one-tile slit is a file, not a corridor. The
## traps go on these stretches, where the player can see the far side of the
## narrow part and step back, rather than in an alcove he has to walk into blind.
const CHOKEPOINT_STUBS: Array[Rect2i] = [
	Rect2i(16, 14, 2, 1),
	Rect2i(26, 9, 1, 3),
	Rect2i(12, 16, 1, 2),
	Rect2i(37, 19, 1, 2),
]

## Dead-end pockets, carved into a block after the masonry is down and painted as
## damp ground, so each reads as a room the water reached rather than a bend in a
## road. Every one is open on exactly one side: the corridor it hangs off, with
## the block closing it on the other three. They are the reason the map is not
## only roads, and they are all reachable from a crossing, so none of them is a
## place a player can be trapped in.
const ALCOVES: Array[Rect2i] = [
	Rect2i(16, 4, 2, 5),
	Rect2i(30, 19, 2, 5),
	Rect2i(4, 18, 5, 2),
]

## The two trap plates, one on each of the two chokepoints a player has to pass to
## cross the zone end to end: the narrowed stretch of the middle corridor and the
## narrowed stretch of the second vertical one. Both anchors are inside a
## two-tile passage, so the plate covers one side of it and the other side stays
## walkable — the trap is something to read and walk past, not a wall. Neither is
## in an alcove, and neither is anywhere near the arrival tile.
const TRAP_A_ANCHOR := Vector2i(17, 12)
const TRAP_B_ANCHOR := Vector2i(24, 10)
const TRAP_SCAN_RADIUS := 1
const TRAP_CLEAR_FROM_ENTRY := 5

## Posts. Every one of them is down a corridor and away from the crossing the
## player arrives on, so the undercroft announces itself by what is further in
## rather than by something standing on the stair. The three guards hold the
## long reaches, the two bowmen the lit ends of the north and east corridors, and
## the two wisps the middle of the zone, where a caster that kites has room to
## keep its distance. Each tile is snapped by `_find_prop_tile`, so a block or a
## column edited later moves the post with it instead of swallowing it.
const SKELETON_A_ANCHOR := Vector2i(19, 25)
const SKELETON_B_ANCHOR := Vector2i(32, 2)
const SKELETON_C_ANCHOR := Vector2i(38, 13)
const SKELETON_ARCHER_A_ANCHOR := Vector2i(8, 2)
const SKELETON_ARCHER_B_ANCHOR := Vector2i(38, 25)
const WISP_A_ANCHOR := Vector2i(13, 7)
const WISP_B_ANCHOR := Vector2i(25, 20)

## The undercroft's own three types, all of them down a long corridor and well past
## the six-tile ring the zone asks of every hostile: the crawlers take the south
## road at either end of it and once more between, where a fast melee enemy has the
## longest run at a player walking the undercroft end to end, and the bearers take
## the north road and the west end of the south one, so a corpse pool falls on the
## widest stretch of floor in the zone and on the road back out of it. Three
## crawlers and two bearers rather than two and one: the undercroft was the thinnest
## zone in the game at eleven live instances, and a single carrier made the hazard
## that owns this place a one-off instead of a rule the player has to plan around.
## The hound pair takes the east of the middle corridor, two tiles apart so the pack
## bonus is real and the pair runs the central crossing the way the hall's pair used
## to; they came down from the ruins so the undercroft introduces three kinds rather
## than two. Each post is snapped by `_find_prop_tile` against the reserved set the
## plates and the first wave already claimed, so none of them can sit on a trap, a
## stair or a post.
const BONE_CRAWLER_A_ANCHOR := Vector2i(7, 25)
const BONE_CRAWLER_B_ANCHOR := Vector2i(34, 26)
const BONE_CRAWLER_C_ANCHOR := Vector2i(28, 26)
const PLAGUE_BEARER_A_ANCHOR := Vector2i(21, 2)
const PLAGUE_BEARER_B_ANCHOR := Vector2i(16, 26)
const GRAVE_HOUND_A_ANCHOR := Vector2i(30, 13)
const GRAVE_HOUND_B_ANCHOR := Vector2i(32, 13)

## The Bell Ringer's post (spec §11), deep in the south corridor past both trap
## plates and clear of every post, plate, column and the two stairs. It keeps ten
## tiles from the arrival crossing — past the six the guards keep — so the boss that
## owns the undercroft is well down the longest road, exactly where a bell that rings
## the whole crypt should stand. Snapped by `_find_prop_tile`, so it cannot land on a
## trap, a stair or another post.
const BELL_RINGER_ANCHOR := Vector2i(32, 25)
const BELL_RINGER_SCAN_RADIUS := 2
const BELL_RINGER_CLEAR_FROM_ENTRY := 10

## The undercroft's one quest-giver (spec §12/§13): Нела, the watchwoman who holds
## the stair and will not go down into the dark herself. She is a `Villager` built
## in code exactly like the forest's herbwife, carrying `q11_light_the_way`. She is
## deliberately NOT a landmark (the map marks the way out, the two plates and the
## boss, and a watchwoman is not a hazard to find) and she carries NO schedule: the
## undercroft has no day sky and no clearing to pace, so she stands her post on one
## tile. Her tile is the north alcove — walkable ground carved into the masonry,
## reachable from the crossing, and eight tiles from the arrival stair so arriving
## never opens her prompt under the player's feet.
const VILLAGER_SCRIPT := "res://scripts/npcs/villager.gd"
const NPC_SPRITE := "res://assets/sprites/npc.png"
const NELA_ANCHOR := Vector2i(16, 6)
const NELA_SCAN_RADIUS := 0
const NELA_CLEAR_FROM_ENTRY := 8

## The pilgrim (spec §12), the same grey stranger the zones above hold, now at the
## crossing where the middle corridor meets the west one — the first place down here
## that is wide enough to stand in without blocking a two-tile road, and nine tiles
## from the arrival stair so arriving never opens his prompt. He is snapped by
## `_find_prop_tile` against the reserved set the plates, the posts, the bell and the
## watchwoman already claimed, so he cannot land on a trap, a stair, a guard or Нела.
const PILGRIM_ANCHOR := Vector2i(12, 12)
const PILGRIM_SCAN_RADIUS := 2
const PILGRIM_CLEAR_FROM_ENTRY := 6

## How wide each post scans for a free tile, and how far every one of them has to
## stay from the tile the player arrives on. Six tiles is 96 px against the 96 px
## sight line of a plain enemy: at that Chebyshev distance a post can see the
## arrival crossing but cannot have been standing close enough to be on top of the
## player the frame the zone finished building. Same rule the ruins spawn with.
const ENEMY_SCAN_RADIUS := 2
const ENEMY_CLEAR_FROM_ENTRY := 6

## Points of interest kept as live node references, as in `Forest` and `Ruins`.
## The stair and the two plates all outlive everything else in the zone: none of
## them frees itself, so all three stay marked for the life of the zone.
var _exit_node: Node2D
var _trap_a_node: Node2D
var _trap_b_node: Node2D
var _bell_ringer_node: Node2D


## Cold dark blue-grey: the undercroft is the darkest floor band in the game
## (CRITIC-P1-01).
func tile_atlas_path() -> String:
	return "res://assets/sprites/tiles_dungeon.png"


## Readability (CRITIC-P1-18): the dungeon floor is near-black blue masonry, so
## the dark silhouette that works in the forest would vanish here. The outline
## flips to light and the body is brightened (value > 1) so both separate from
## the dark floor; the body's own near-black shading pixels are framed by the
## light outline, which is what keeps the silhouette readable.
func enemy_outline_color() -> Color:
	return Color(0.910, 0.933, 0.965)


func enemy_body_tint() -> Color:
	return Color(2.6, 2.6, 2.6)


func zone_id() -> String:
	return "dungeon"


func zone_name() -> String:
	return "Подземелье под руинами"


func music_track() -> String:
	return "music_dungeon"


func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Array in [
		# The stair back up. Marked like any other gate so the way out is findable
		# on the map once the player has walked near it, which is the whole point of
		# marking it: a one-tile exit in a dark undercroft is otherwise easy to walk
		# past on the way back.
		["RuinsExit", "gate", _exit_node],
		# Both plates stay marked. A trap the player sprang is still a trap on the
		# road back, and the map is where he will look for it.
		["TrapA", "trap", _trap_a_node],
		["TrapB", "trap", _trap_b_node],
		# The Bell Ringer is marked so the player can find the undercroft's boss on
		# the map. It stays marked for the life of the zone: the boss outlives the
		# plates on the road to it, and a cleared crypt is still the room he came for.
		["BellRinger", "boss", _bell_ringer_node],
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

	# The order is the layout: damp ground first, then the masonry that buries it,
	# then the columns, then the stubs that narrow the roads, then the pockets
	# carved back out of the masonry. Reversing the last two would erase the
	# alcoves rather than open them.
	for patch: Rect2i in DIRT_PATCHES:
		_paint_rect(grid, patch, ",")
	for block: Rect2i in WALL_BLOCKS:
		_paint_rect(grid, block, "#")
	for pillar: Vector2i in PILLARS:
		if _is_interior(pillar):
			grid[pillar.y][pillar.x] = "#"
	for stub: Rect2i in CHOKEPOINT_STUBS:
		_paint_rect(grid, stub, "#")
	for alcove: Rect2i in ALCOVES:
		_paint_rect(grid, alcove, ",")

	_map.clear()
	for y in range(MAP_H):
		_map.append("".join(PackedStringArray(grid[y])))


## Paints one rect with a character, clipped to the interior so the border wall
## stays solid no matter how the constants are edited later. Used for both the
## walls and the floor, which is what lets an alcove be carved by painting it.
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
	# cell so a hand-edited `entry_tile` that lands on a column still spawns a
	# player standing on floor.
	var entry := ZoneManager.entry_tile(zone_id())
	if entry == Vector2i.ZERO:
		entry = FALLBACK_ENTRY_TILE
	var spawn_tile := _entry_spawn_tile(entry)
	player = _instantiate(PLAYER_SCENE, _tile_center(spawn_tile.x, spawn_tile.y), "Player")
	player.name = "Player"
	player.add_to_group("player")
	player.set("spawn_point", player.global_position)

	# The way back is placed first, so its tile is already reserved while the
	# plates and the posts are still being snapped and nothing can be parked on
	# the stair.
	var exit_tile := _find_walkable_near(RUINS_EXIT_TILE, 0)
	var exit := ZoneExit.new()
	exit.name = "RuinsExit"
	exit.target_zone = "ruins"
	exit.prompt = "Вернуться в руины"
	exit.position = _tile_center(exit_tile.x, exit_tile.y)
	add_child(exit)
	_exit_node = exit

	var reserved := {spawn_tile: true, exit_tile: true}
	_spawn_traps(spawn_tile, reserved)
	_spawn_enemies(spawn_tile, reserved)
	_spawn_new_posts(spawn_tile, reserved)
	# The Bell Ringer is placed after every plate and post so it inherits the reserved
	# set they claimed and cannot be parked on a trap or a guard, and before the door
	# to the fortress so its tile is visible to the collision check that door makes.
	_spawn_bell_ringer(spawn_tile, reserved)
	# The watchwoman is placed after every plate and post so she inherits the
	# reserved set they claimed and cannot be parked on a trap, a stair or a guard,
	# and before the door to the fortress so her tile is visible to the collision
	# check that door makes. Her tile is the north alcove, snapped by
	# `_find_prop_tile` against that reserved set with the eight-tile clearance the
	# zone asks of a prop that is not a hazard.
	_spawn_nela(spawn_tile, reserved)
	# Last, after every plate and post has had its turn at the reserved set. The
	# door's tile is a fixed constant rather than a scan, so the order cannot move
	# it, but the reserved set is the only thing here that knows which tiles the
	# props ended up on, and reading it after they are placed means an edit to an
	# anchor that walks a skeleton onto the door shows up as a collision this
	# function can see instead of two props sharing one tile in silence. Same
	# position in the flow as the ruins' descent, for the same reason.
	_spawn_fortress_gate(spawn_tile, reserved)
	# The pilgrim is placed after every plate, post, stair and the watchwoman so he
	# inherits the whole reserved set they claimed and cannot be parked on a trap, a
	# stair, a guard or Нела. His tile is the west/middle crossing, snapped by
	# `_find_prop_tile` against that set with the six-tile clearance the zone asks of
	# a prop that is not a hostile.
	_spawn_pilgrim(spawn_tile, reserved)
	# Arriving in the undercroft is itself the `visit` objective of q06. Reported once
	# the zone is fully built and the player is standing in it, so the quest manager
	# advances a `visit` quest aimed at this zone and nothing else; a quest that is not
	# active, or aimed at another zone, is left untouched.
	QuestManager.notify_zone_visited(zone_id())


## The door up to the fortress, at the far end of the longest walk the undercroft
## asks for. Built in code like the stair back to the ruins: a `ZoneExit` has no
## sprite of its own and draws itself, so a node assembled here cannot drift away
## from the tile constant that places it, and the ascent cannot be edited out of
## existence by a scene edit. It is deliberately not a landmark, exactly as the
## ruins leave their own descent unmarked: the map marks the way out and the two
## hazards, and the door to the fifth area of the world is the reward for walking
## the undercroft rather than a waypoint handed to the player before he starts.
func _spawn_fortress_gate(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		FORTRESS_GATE_TILE, FORTRESS_GATE_SCAN_RADIUS, entry, reserved, 0)
	reserved[tile] = true
	var gate := ZoneExit.new()
	gate.name = "FortressGate"
	gate.target_zone = "fortress"
	gate.prompt = "Войти в крепость"
	gate.position = _tile_center(tile.x, tile.y)
	add_child(gate)


## Two plates on the two narrowed stretches. Each takes the first free tile of its
## own little scan, marks it reserved, and so hands the second plate a map that
## already knows the first one is there. The scene is the forest's own
## `SpikeTrap`, reused rather than duplicated: the telegraph, the hit window and
## the cooldown are the same promise here, and a trap that warns before it hits is
## the only kind of hazard this zone should have had.
func _spawn_traps(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[TRAP_A_ANCHOR, "TrapA"],
		[TRAP_B_ANCHOR, "TrapB"],
	]:
		var tile := _find_prop_tile(
			post[0] as Vector2i, TRAP_SCAN_RADIUS, entry, reserved, TRAP_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		var trap := _instantiate(TRAP_SCENE, _tile_center(tile.x, tile.y), String(post[1]))
		trap.name = String(post[1])
		if String(post[1]) == "TrapA":
			_trap_a_node = trap
		else:
			_trap_b_node = trap


## Three guards, two bowmen and two wisps. Each tile is marked reserved as it is
## taken, so two posts whose anchors are close can never collapse onto the same
## tile once the grid nudges them, and none of them can land on the stair or on a
## plate.
func _spawn_enemies(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[SKELETON_SCENE, SKELETON_A_ANCHOR, "SkeletonA"],
		[SKELETON_SCENE, SKELETON_B_ANCHOR, "SkeletonB"],
		[SKELETON_SCENE, SKELETON_C_ANCHOR, "SkeletonC"],
		[SKELETON_ARCHER_SCENE, SKELETON_ARCHER_A_ANCHOR, "SkeletonArcherA"],
		[SKELETON_ARCHER_SCENE, SKELETON_ARCHER_B_ANCHOR, "SkeletonArcherB"],
		[WISP_SCENE, WISP_A_ANCHOR, "WispA"],
		[WISP_SCENE, WISP_B_ANCHOR, "WispB"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## The undercroft's own three types, on the same reserved-tile flow as the first wave
## and placed right after it, so every tile the plates and the seven originals took
## is already off limits and every tile these seven take is still visible to the
## collision check the door to the fortress makes when it is placed last. The hounds
## are listed as a pair and consecutively, so the second lands on the tile next to
## the first rather than somewhere the pack bonus would not reach.
func _spawn_new_posts(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[BONE_CRAWLER_SCENE, BONE_CRAWLER_A_ANCHOR, "BoneCrawlerA"],
		[BONE_CRAWLER_SCENE, BONE_CRAWLER_B_ANCHOR, "BoneCrawlerB"],
		[BONE_CRAWLER_SCENE, BONE_CRAWLER_C_ANCHOR, "BoneCrawlerC"],
		[PLAGUE_BEARER_SCENE, PLAGUE_BEARER_A_ANCHOR, "PlagueBearerA"],
		[PLAGUE_BEARER_SCENE, PLAGUE_BEARER_B_ANCHOR, "PlagueBearerB"],
		[GRAVE_HOUND_SCENE, GRAVE_HOUND_A_ANCHOR, "GraveHoundA"],
		[GRAVE_HOUND_SCENE, GRAVE_HOUND_B_ANCHOR, "GraveHoundB"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## The undercroft's boss (spec §11), snapped against the reserved set the plates and
## the posts already claimed and kept ten tiles from the arrival crossing. Its node is
## kept as a live landmark reference so the map can mark the boss.
func _spawn_bell_ringer(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		BELL_RINGER_ANCHOR, BELL_RINGER_SCAN_RADIUS, entry, reserved, BELL_RINGER_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	_bell_ringer_node = _instantiate(BELL_RINGER_SCENE, _tile_center(tile.x, tile.y), "BellRinger")


## The undercroft's quest-giver. Built in code like the forest's villagers (a
## `Villager` with a `Sprite2D` child added before `add_child` so the base `Npc`'s
## `@onready` sprite resolves on the first frame), placed on the north alcove by
## `_find_prop_tile` and marked reserved so nothing later claims her tile. She
## carries `q11_light_the_way` and no schedule — the undercroft has no day sky to
## pace by, so she stands her post. The grey tint is set after `add_child` because
## `Villager._ready` paints every herbwife the same green.
func _spawn_nela(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		NELA_ANCHOR, NELA_SCAN_RADIUS, entry, reserved, NELA_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	var script: GDScript = load(VILLAGER_SCRIPT)
	if script == null:
		push_error("Dungeon: cannot load %s" % VILLAGER_SCRIPT)
		return
	var nela: Node2D = script.new() as Node2D
	nela.name = "Nela"
	nela.set("display_name", "Смотрящая Нела")
	nela.set("speaker_id", "nela")
	nela.set("sprite_texture", load(NPC_SPRITE))
	# Нела now carries two quests: the bell she needs silenced below the stair (q08,
	# moved off the tablet so the stone no longer hands out most of the chain) and her
	# own light-the-way (q11). Only q11 is a spoken conversation — it is the one with a
	# dialogue tree of hers — so `dialogue_quest_id` names it and q08 is offered and
	# turned in through the plain quest flow.
	nela.set("quest_ids", PackedStringArray(["q08_the_bell", "q11_light_the_way"]))
	nela.set("dialogue_quest_id", "q11_light_the_way")
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load(NPC_SPRITE)
	nela.add_child(spr)
	nela.position = _tile_center(tile.x, tile.y)
	add_child(nela)
	spr.modulate = Color(0.70, 0.74, 0.82)


## The grey stranger at the crossing. Built in code like the forest's villagers (a
## `Sprite2D` child added before `add_child` so the base `Npc`'s `@onready` sprite
## resolves on the first frame); the grey tint is applied by `Pilgrim._ready`
## itself. He carries no quest and no schedule and is deliberately not a landmark —
## the map keeps its markers for the way out, the two plates and the boss, and a
## figure who is in every zone is not a fixed point of interest in this one.
func _spawn_pilgrim(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		PILGRIM_ANCHOR, PILGRIM_SCAN_RADIUS, entry, reserved, PILGRIM_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	var pilgrim := Pilgrim.new()
	pilgrim.name = "PilgrimDungeon"
	pilgrim.zone_id = "dungeon"
	pilgrim.sprite_texture = load(NPC_SPRITE)
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load(NPC_SPRITE)
	pilgrim.add_child(spr)
	pilgrim.position = _tile_center(tile.x, tile.y)
	add_child(pilgrim)


## The outward row-major scan of `ZoneBase._find_walkable_near` with two rules
## added: a tile a prop already stands on is not free, and neither is a tile
## closer than `clear_from_entry` to the tile the player arrives on (Chebyshev, so
## the diagonal counts as close too). Deterministic for the same reason the base
## scan is — the order depends only on the anchor and the grid. Same rule the
## ruins use; the two zones keep their own copy rather than sharing one, because
## the base class owns the shared plumbing and this is content.
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
## unless that cell turns out to be solid, in which case the nearest walkable one.
##
## `ZoneBase._find_walkable_near` cannot simply be handed the entry tile with a
## radius, because it returns the first walkable cell of its scan box in
## row-major order rather than preferring the anchor. The declared tile is where
## the player is meant to arrive, so it is used whenever it is walkable, and the
## base scan is only reached as the fallback for data that put an entry point
## inside a column.
func _entry_spawn_tile(entry: Vector2i) -> Vector2i:
	if _is_walkable(entry):
		return entry
	for radius in range(1, ENTRY_FALLBACK_SCAN_RADIUS + 1):
		var candidate := _find_walkable_near(entry, radius)
		if _is_walkable(candidate):
			return candidate
	return entry


## The undercroft has no villagers and therefore no schedule to serve, but the day
## cycle is world-owned state the HUD reads through the `day_clock` group, so the
## zone runs its own clock. There is no sky down here, and the clock line is not
## the sky: without a clock it would simply go blank for as long as the player
## stood in this zone.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
