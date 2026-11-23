class_name Fortress
extends ZoneBase
## The fourth zone: the ancient fortress at the end of the road, reached through
## the door at the far north-east corner of the undercroft. The dungeon is what
## the player pays a key for; this is what the whole route was walking towards,
## so the zone is built as a progression rather than a place to get lost in —
## outer yard, barracks, archive, throne hall, and the broken sanctum behind it.
##
## Like the two zones before it, the layout is written out as constants instead of
## rolled from a seed: a fixed list of wall rects, pillars and floor patches is
## deterministic by construction, so there is no generator to keep in step and no
## seed to pin. Unlike them, the shape here is a row of rooms rather than a hall or
## a network: four dividing walls cut the grid into five named areas, and each wall
## leaves one opening two tiles tall on the two rows of the spine.
##
## The spine is the promise this zone makes about itself. Rows 14..15 are kept free
## of masonry from the west border to the east one — no wall rect, no pillar and no
## dirt-free gap ever lands there — so the road from the entry to the sanctum is
## always two tiles wide, every doorway lines up with it, and a player who walks
## east can always walk back west. Nothing in this zone is one-way: there is no
## door, no lever, no drop and no collapse. The fortress was sealed by other
## people, long ago; the walk through it is the player's own.
##
## The last room is the exception in a specific way. The sanctum beyond the throne
## hall is left empty on purpose — see `BOSS_ARENA` — because the final boss of the
## game is meant to be fought there and nothing may be standing in the ring when he
## arrives. That is the one piece of geometry in this zone written for content that
## does not exist yet, and it is the reason the sanctum's own doorway has no
## flanking pillars on its east side.

const SKELETON_SCENE := "res://scenes/enemies/skeleton.tscn"
const SKELETON_ARCHER_SCENE := "res://scenes/enemies/skeleton_archer.tscn"
const WISP_SCENE := "res://scenes/enemies/wisp.tscn"
const BOAR_SCENE := "res://scenes/enemies/boar.tscn"
## The two new garrison types (spec §10). The ash knight is the elite of the zone:
## the heaviest pool and swing on the map outside the boss, and it soaks 45 % of
## anything that comes at it from the front, so the only honest way to kill it is
## to get behind it. The crawler is the opposite trade — a sixteenth of the health
## and 1.35x the speed, meant to close a room before the player reads the room.
const ASH_KNIGHT_SCENE := "res://scenes/enemies/ash_knight.tscn"
const BONE_CRAWLER_SCENE := "res://scenes/enemies/bone_crawler.tscn"
## The garrison the finale is built out of (spec §10). The fortress used to field
## one kind the player had not already met and a boar borrowed from the forest, so
## the last hour of the world introduced less than the first one did. These three
## types come up from the ruins — the shield that soaks the lane, the caster that
## keeps the room alive behind its pack, the hound pair that only works in twos —
## and they change what the rooms ask of a player: the archive needs a line of
## sight broken, the barracks need flanking, the throne approach needs a healer
## killed before the elite it supports is touched.
const SHIELDBEARER_SCENE := "res://scenes/enemies/shieldbearer.tscn"
const CULTIST_CASTER_SCENE := "res://scenes/enemies/cultist_caster.tscn"
const GRAVE_HOUND_SCENE := "res://scenes/enemies/grave_hound.tscn"
## The final boss (spec §11.4) and the throne that ends the run. The King is the only
## enemy the arena was kept empty for; the altar is the choice the death unlocks. The
## altar is built in code (`EndingAltar.new()`) exactly like the zone exit, so it needs
## no scene file of its own.
const KING_SCENE := "res://scenes/enemies/king_without_crown.tscn"

const MAP_W := 48
const MAP_H := 30

## The zone's own entry tile, used only as the fallback when the data table has
## nothing usable for this zone. It is the same tile `data/zones.json` names, and
## it sits in the west end of the spine, inside the outer yard, where the road back
## down to the dungeon is three tiles away and every room is down the same road.
const FALLBACK_ENTRY_TILE := Vector2i(4, 14)

## How far the spawn scan widens when the entry tile named in the data turns out
## to sit on something solid. Three tiles clears a single pillar or a one-tile wall
## stub without wandering out of the yard.
const ENTRY_FALLBACK_SCAN_RADIUS := 3

## The two rows of the spine. The invariant of this zone is that every tile of
## these rows, from the west border to the east one, is walkable: the four dividing
## walls open onto them, the four room markers stand on them, and the road back is
## the same road going the other way. `_generate_map` paints the masonry after the
## floor and the tests measure the rows, so an edit that breaks the spine shows up
## as a red check rather than as a corridor a player finds out about alone.
const SPINE_TOP_ROW := 14
const SPINE_BOTTOM_ROW := 15

## The stair back down, in the yard three tiles north-west of the arrival tile:
## close enough that a player who came up to look around can leave without walking
## the fortress, far enough that arriving never opens the prompt under his feet.
## Same distance and same reasoning as the ruins' `ForestGate` and the dungeon's
## `RuinsExit`. A radius-0 scan checks the declared tile rather than snapping it to
## the nearest free one, because a wide row-major scan would answer with the
## top-left corner of its box and move the only exit in the zone.
const DUNGEON_EXIT_TILE := Vector2i(2, 11)

## The masonry, in the order it is painted. The four dividing walls come first:
## each is one tile thick, runs the whole interior height, and is written as two
## rects so the two rows of the spine stay open through it — that opening is the
## doorway, two tiles tall against a two-tile road, which is what keeps the zone
## walkable in both directions without a single door in it. The rest are the rooms
## each wall creates: hut stubs and a curtain stub in the yard, four bunk bars in
## the barracks, six racks in the archive, two daises in the throne hall. Every one
## of them is an island — clear of the border, of the dividing walls and of each
## other — so none of them can seal a pocket, and the yard, the barracks, the
## archive and the throne hall each stay one connected room.
const INNER_WALLS: Array[Rect2i] = [
	# Dividers: yard | barracks | archive | throne hall | sanctum.
	Rect2i(13, 1, 1, 13), Rect2i(13, 16, 1, 13),
	Rect2i(24, 1, 1, 13), Rect2i(24, 16, 1, 13),
	Rect2i(34, 1, 1, 13), Rect2i(34, 16, 1, 13),
	Rect2i(41, 1, 1, 13), Rect2i(41, 16, 1, 13),
	# Outer yard: two hut foundations and the stub of the curtain that burned.
	Rect2i(3, 4, 6, 1), Rect2i(3, 24, 6, 1),
	Rect2i(10, 7, 1, 4), Rect2i(10, 19, 1, 4),
	# Barracks: four bunk bars, two north of the parade ground and two south.
	Rect2i(16, 3, 6, 1), Rect2i(16, 6, 6, 1),
	Rect2i(16, 22, 6, 1), Rect2i(16, 25, 6, 1),
	# Archive: four shelf runs and two fallen ones lying across the room.
	Rect2i(27, 3, 1, 4), Rect2i(31, 3, 1, 4),
	Rect2i(27, 21, 1, 4), Rect2i(31, 21, 1, 4),
	Rect2i(28, 9, 3, 1), Rect2i(28, 19, 3, 1),
	# Throne hall: the dais the king never left and the one below it.
	Rect2i(36, 4, 4, 2), Rect2i(36, 23, 4, 2),
]

## Standing columns. The twelve that flank the four doorways sit one tile either
## side of an opening and one row off a spine row, so they read as gateposts and
## never as a narrowed passage: the doorway stays two tiles wide, and the approach
## to it stays two tiles wide. The six hall columns are decorative and are all off
## the spine. The sanctum's doorway has gateposts on the throne-hall side only —
## the two that would stand on its east side are inside `BOSS_ARENA`, and a ring
## the final boss has to walk into cannot start with two columns in it.
const PILLARS: Array[Vector2i] = [
	Vector2i(12, 13), Vector2i(12, 16), Vector2i(14, 13), Vector2i(14, 16),
	Vector2i(23, 13), Vector2i(23, 16), Vector2i(25, 13), Vector2i(25, 16),
	Vector2i(33, 13), Vector2i(33, 16), Vector2i(35, 13), Vector2i(35, 16),
	Vector2i(40, 13), Vector2i(40, 16),
	Vector2i(6, 8), Vector2i(6, 21),
	Vector2i(19, 10), Vector2i(19, 19),
	Vector2i(29, 8), Vector2i(29, 21),
	Vector2i(37, 9), Vector2i(37, 20),
]

## Worn floor, drawn as dirt: the garrison's yard, the parade ground the barracks
## drilled on, the archive floor, the throne hall's approach, and two scorch marks
## in the sanctum where the ritual went wrong. Painted before the masonry so a
## patch can only ever be covered by a wall, never the other way round. Deliberately
## short of `BOSS_ARENA`: the ring the final boss is fought in is bare stone.
const DIRT_PATCHES: Array[Rect2i] = [
	Rect2i(2, 11, 5, 5),
	Rect2i(15, 12, 8, 5),
	Rect2i(26, 12, 7, 4),
	Rect2i(35, 12, 6, 5),
	Rect2i(43, 4, 3, 4),
	Rect2i(43, 21, 3, 4),
]

## The five named areas of spec §5, as the rectangles each dividing wall leaves
## between itself and the next. The sanctum is here because it is a real room the
## geometry defines, and it is deliberately not one of the markers below: the four
## marked areas are the ones a player is sent to look for, and the sanctum is the
## one he is supposed to walk into without being told.
##
## The markers take the centre of their rectangle, which for these rooms is always
## a tile of the spine, so a marker can never be dropped inside a wall by an edit
## to a rect: widening a room moves its marker along the road, not off it.
const ROOM_BOUNDS := {
	"fortress_yard": Rect2i(1, 1, 12, 28),
	"fortress_barracks": Rect2i(14, 1, 10, 28),
	"fortress_archive": Rect2i(25, 1, 9, 28),
	"fortress_throne": Rect2i(35, 1, 6, 28),
	"fortress_sanctum": Rect2i(42, 1, 5, 28),
}

## The four areas the map names, in the order a player walks them. Spelled out as
## a list rather than derived from `ROOM_BOUNDS` so the sanctum cannot join the
## markers by someone filling in the room table, and so the stable ids the map and
## the tests use are visible in one line.
const ROOM_MARKERS: Array[String] = [
	"fortress_yard", "fortress_barracks", "fortress_archive", "fortress_throne",
]

## The ring the final boss is meant to be fought in: the far end of the throne
## hall, inside the broken sanctum, entered through the last two-tile doorway on
## the spine. Reserved in the same pass that reserves the entry and the exit, so no
## enemy, no prop and no future spawn can be placed on it by `_find_prop_tile`, and
## kept free of masonry, of pillars and of dirt by the constants above. Every tile
## of it is walkable and reachable from the entry, which is the whole requirement:
## the fight is not here yet, but the ground it will need is, and a boss added
## later should have to be added, not cleared.
const BOSS_ARENA := Rect2i(42, 11, 5, 8)

## Posts. Two guards and a boar hold the yard, the two bowmen and the boar's
## parade ground hold the barracks, and the archive keeps the two lights and a
## bowman of its own, where a caster has the shelf runs to break a line of sight
## behind. Every anchor is in the half of the zone the player has to walk to reach,
## and every one of them is snapped by `_find_prop_tile`, so a wall or a column
## edited later moves the post with it instead of swallowing it.
const GUARD_A_ANCHOR := Vector2i(3, 6)
const GUARD_B_ANCHOR := Vector2i(11, 22)
const ARCHER_A_ANCHOR := Vector2i(17, 4)
const ARCHER_B_ANCHOR := Vector2i(21, 24)
const BOAR_A_ANCHOR := Vector2i(20, 18)
const WISP_A_ANCHOR := Vector2i(28, 6)
const WISP_B_ANCHOR := Vector2i(32, 22)
const ARCHER_C_ANCHOR := Vector2i(26, 19)

## The new garrison. The ash knight holds the barracks parade ground, where the
## bunk bars break a line of sight on both sides and an elite that only has to
## face one way has a road to be approached down; a second knight takes the throne
## approach, so the last corridor before the sanctum is guarded by the thing the
## sanctum was built to keep. The crawler takes the archive, where a low fast body
## can run the length of the shelf runs and come at a player from behind a rack.
## The shield comes to the barracks door, where its lane actually has a door to
## hold; the caster to the archive north run, where it can stand behind a rack and
## be unreachable until the player commits to the room; the two hounds to the
## archive south floor, two tiles apart so the pack bonus is real and the pair is
## the thing that makes the long southern run cost something. All of them are on
## the spine or off it by one room, all are well past the six-tile ring the zone
## asks of every hostile, and none is anywhere near the ring kept for the final
## boss. Each is snapped by `_find_prop_tile` against the reserved set the first
## wave already claimed, so none of them can sit on the stair, the entry or
## another post.
const ASH_KNIGHT_A_ANCHOR := Vector2i(19, 14)
const ASH_KNIGHT_B_ANCHOR := Vector2i(36, 12)
const BONE_CRAWLER_C_ANCHOR := Vector2i(29, 14)
const SHIELDBEARER_A_ANCHOR := Vector2i(17, 20)
const CULTIST_CASTER_A_ANCHOR := Vector2i(30, 7)
const GRAVE_HOUND_A_ANCHOR := Vector2i(32, 25)
const GRAVE_HOUND_B_ANCHOR := Vector2i(30, 25)
const BONE_CRAWLER_D_ANCHOR := Vector2i(20, 12)

## The fortress's one quest-giver (spec §12/§13): Орен, the officer who still holds
## the garrison and prints his orders with a seal the ash knight has cut him off
## from. He is a `Villager` built in code exactly like the forest's herbwife,
## carrying `q12_officers_seal`. He is deliberately NOT a landmark (the map marks
## the way back and the four named rooms, not a person) and carries NO schedule:
## the sanctum has no sky and an officer does not pace a barracks he is holding
## alone. His tile is the barracks parade ground north of the spine — walkable,
## reachable, off the road itself, and eight tiles from the arrival so arriving
## never opens his prompt under the player's feet.
const VILLAGER_SCRIPT := "res://scripts/npcs/villager.gd"
const NPC_SPRITE := "res://assets/sprites/npc.png"
const OREN_ANCHOR := Vector2i(21, 10)
const OREN_SCAN_RADIUS := 0
const OREN_CLEAR_FROM_ENTRY := 8

## The pilgrim (spec §12), the same grey stranger the zones before hold, now in the
## archive — the last room before the throne hall, where the fragment he carries
## about the king and the crown lands just before the player walks into the room the
## king never left. He stands off the spine in the archive floor, clear of the shelf
## runs and the fallen racks, twenty-five tiles from the arrival and well outside the
## ring kept for the final boss. Snapped by `_find_prop_tile` against the reserved
## set the arena, the entry, the stair and every post already claimed.
const PILGRIM_ANCHOR := Vector2i(29, 17)
const PILGRIM_SCAN_RADIUS := 2
const PILGRIM_CLEAR_FROM_ENTRY := 6

## The final boss and his throne, both placed by hand at the far end of the spine
## inside the ring the zone kept for exactly this. The King takes the centre of
## `BOSS_ARENA`; the throne stands two tiles east of him against the sanctum's back
## wall, so the player who has killed him walks a few steps past the body to the seat.
## Neither is snapped by `_find_prop_tile`: the ring is empty by construction, so the
## declared tiles are the tiles they get, and the two are far enough apart that the
## King's body and the throne's prompt never compete.
const KING_ANCHOR := Vector2i(44, 15)
const ALTAR_ANCHOR := Vector2i(46, 15)

## How wide each post scans for a free tile, and how far every one of them has to
## stay from the tile the player arrives on. Six tiles is 96 px against the 96 px
## sight line of a plain enemy: at that Chebyshev distance a post can see the entry
## but cannot have been standing close enough to be on top of the player the frame
## the zone finished building. Same rule the ruins and the dungeon spawn with.
const ENEMY_SCAN_RADIUS := 2
const ENEMY_CLEAR_FROM_ENTRY := 6

## The way back, kept as a live node reference as in the other zones. The four room
## markers need no node: they name ground, not objects, and ground cannot free
## itself, so they are built from `ROOM_BOUNDS` on every call rather than cached.
var _exit_node: Node2D

## The final boss and the throne, kept as live references the way the exit is. They
## are deliberately not landmarks: the sanctum is the one room the player is meant to
## walk into without being sent to it, and marking the throne would put the game's
## ending on the map before he has earned the walk.
var _king_node: Node2D
var _altar_node: Node2D


## Deep brown-grey: the old fortress sits between the pale ruins and the dark
## undercroft in its own warm-dark band (CRITIC-P1-01).
func tile_atlas_path() -> String:
	return "res://assets/sprites/tiles_fortress.png"


## Readability (CRITIC-P1-18): the fortress floor is a dark warm brown, brighter
## than the dungeon's, so it needs the strongest body brightening (3.4) of any
## zone to clear >=3:1; the outline is the same light one the dungeon uses.
func enemy_outline_color() -> Color:
	return Color(0.910, 0.933, 0.965)


func enemy_body_tint() -> Color:
	return Color(3.4, 3.4, 3.4)


func zone_id() -> String:
	return "fortress"


func zone_name() -> String:
	return "Древняя крепость"


func music_track() -> String:
	return "music_fortress"


## The stair down and the four named areas. The rooms are marked because the map is
## where a player looks to find out how far he still has to walk, and a fortress
## that is only a corridor between walls tells him nothing about what the walls are
## for; the stair is marked so the way out is findable on the map once he has
## walked near it, which is the same reason the dungeon marks its own.
func landmarks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _exit_node != null and is_instance_valid(_exit_node):
		out.append({
			"id": "DungeonExit",
			"kind": "gate",
			"tile": Vector2i(
				floori(_exit_node.global_position.x / float(TILE)),
				floori(_exit_node.global_position.y / float(TILE))
			),
		})
	for room_id: String in ROOM_MARKERS:
		out.append({"id": String(room_id), "kind": "room", "tile": _room_centre(String(room_id))})
	return out


## The marked tile of a named area: the centre of its rectangle, floored, which for
## these five rooms always lands on a spine row.
func _room_centre(room_id: String) -> Vector2i:
	var bounds: Rect2i = ROOM_BOUNDS.get(room_id, Rect2i())
	var center: Vector2 = bounds.get_center()
	return Vector2i(floori(center.x), floori(center.y))


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

	# The order is the layout: worn floor first, then the masonry that buries it,
	# then the columns. Reversing the last two would drop a pillar into a wall stub
	# rather than into a room, which is harmless, but painting the floor after the
	# walls would put scorch marks on top of the daises, which is not.
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

	# The way back is placed first, so its tile is already reserved while the posts
	# are still being snapped and nothing can be parked on the stair.
	var exit_tile := _find_walkable_near(DUNGEON_EXIT_TILE, 0)
	var exit := ZoneExit.new()
	exit.name = "DungeonExit"
	exit.target_zone = "dungeon"
	exit.prompt = "Вернуться в подземелье"
	exit.position = _tile_center(exit_tile.x, exit_tile.y)
	add_child(exit)
	_exit_node = exit

	# The arena goes into the reserved set tile by tile, before any post is placed,
	# so the ring is held for the boss by the same mechanism that keeps two enemies
	# off one tile rather than by a rule each future spawner has to remember.
	var reserved := {spawn_tile: true, exit_tile: true}
	for tile: Vector2i in _rect_tiles(BOSS_ARENA):
		reserved[tile] = true
	_spawn_enemies(spawn_tile, reserved)
	_spawn_new_posts(spawn_tile, reserved)
	# The officer is placed after every post so he inherits the reserved set they
	# claimed and cannot be parked on the stair, the entry or another post, and
	# before the final boss so his tile is visible to the reservation the ring keeps.
	# His tile is the barracks parade ground, snapped by `_find_prop_tile` against
	# that reserved set with the eight-tile clearance the zone asks of a prop that
	# is not a hostile.
	_spawn_oren(spawn_tile, reserved)
	# The pilgrim is placed after every post and the officer so he inherits the whole
	# reserved set they claimed — including the arena the boss needs — and cannot be
	# parked on the stair, the entry, a post or inside the ring. His tile is the
	# archive, snapped by `_find_prop_tile` against that set with the six-tile
	# clearance the zone asks of a prop that is not a hostile. The final boss is
	# placed by hand inside the reserved ring afterwards, so the two never meet.
	_spawn_pilgrim(spawn_tile, reserved)
	# The ring the reservation above held empty is filled last, by hand, with the one
	# enemy it was held for and the throne his death unlocks. Placed after every post
	# so the arena is the only ground they can take, and never via `_find_prop_tile`
	# so a future edit to an anchor cannot slide either one out of the sanctum.
	_spawn_final_boss()


## The final boss in the centre of the ring and the throne against the back wall. Both
## stand on tiles the map already proves walkable (every tile of `BOSS_ARENA` is bare
## stone), so they are placed at their declared centres directly rather than snapped.
func _spawn_final_boss() -> void:
	_king_node = _instantiate(KING_SCENE, _tile_center(KING_ANCHOR.x, KING_ANCHOR.y), "KingWithoutCrown")
	_king_node.name = "KingWithoutCrown"
	var altar := EndingAltar.new()
	altar.name = "EndingAltar"
	altar.position = _tile_center(ALTAR_ANCHOR.x, ALTAR_ANCHOR.y)
	add_child(altar)
	_altar_node = altar


## The new garrison, on the same reserved-tile flow as the eight originals and
## placed right after them, so every tile the first wave took is already off
## limits. The arena is in `reserved` before any of these calls run, so no post can
## be nudged into the ring the final boss needs even if an anchor is edited onto
## the sanctum side later. The hounds are listed as a pair and consecutively, so
## the second one lands on the tile next to the first rather than somewhere the
## pack bonus would not reach.
func _spawn_new_posts(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[ASH_KNIGHT_SCENE, ASH_KNIGHT_A_ANCHOR, "AshKnightA"],
		[ASH_KNIGHT_SCENE, ASH_KNIGHT_B_ANCHOR, "AshKnightB"],
		[BONE_CRAWLER_SCENE, BONE_CRAWLER_C_ANCHOR, "BoneCrawlerC"],
		[BONE_CRAWLER_SCENE, BONE_CRAWLER_D_ANCHOR, "BoneCrawlerD"],
		[SHIELDBEARER_SCENE, SHIELDBEARER_A_ANCHOR, "ShieldbearerA"],
		[CULTIST_CASTER_SCENE, CULTIST_CASTER_A_ANCHOR, "CultistCasterA"],
		[GRAVE_HOUND_SCENE, GRAVE_HOUND_A_ANCHOR, "GraveHoundA"],
		[GRAVE_HOUND_SCENE, GRAVE_HOUND_B_ANCHOR, "GraveHoundB"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## The fortress's quest-giver. Built in code like the forest's villagers (a
## `Villager` with a `Sprite2D` child added before `add_child` so the base `Npc`'s
## `@onready` sprite resolves on the first frame), placed on the barracks parade
## ground by `_find_prop_tile` and marked reserved so nothing later claims his tile.
## He carries `q12_officers_seal` and no schedule — the sanctum has no sky to pace
## by, so an officer holds one post. The brass tint is set after `add_child` because
## `Villager._ready` paints every herbwife the same green.
func _spawn_oren(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		OREN_ANCHOR, OREN_SCAN_RADIUS, entry, reserved, OREN_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	var script: GDScript = load(VILLAGER_SCRIPT)
	if script == null:
		push_error("Fortress: cannot load %s" % VILLAGER_SCRIPT)
		return
	var oren: Node2D = script.new() as Node2D
	oren.name = "Oren"
	oren.set("display_name", "Офицер Орен")
	oren.set("speaker_id", "oren")
	oren.set("sprite_texture", load(NPC_SPRITE))
	# Орен now carries two quests: the word he needs carried down to the watchwoman
	# (q07, moved off the tablet so the stone no longer hands out most of the chain)
	# and his own officer's seal (q12). Only q12 is a spoken conversation, so
	# `dialogue_quest_id` names it and q07 runs through the plain quest flow.
	oren.set("quest_ids", PackedStringArray(["q07_captain_guard", "q12_officers_seal"]))
	oren.set("dialogue_quest_id", "q12_officers_seal")
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load(NPC_SPRITE)
	oren.add_child(spr)
	oren.position = _tile_center(tile.x, tile.y)
	add_child(oren)
	spr.modulate = Color(0.85, 0.72, 0.40)


## The grey stranger in the archive. Built in code like the forest's villagers (a
## `Sprite2D` child added before `add_child` so the base `Npc`'s `@onready` sprite
## resolves on the first frame); the grey tint is applied by `Pilgrim._ready`
## itself. He carries no quest and no schedule and is deliberately not a landmark —
## the map keeps its markers for the way back and the four named rooms, and a figure
## who is in every zone is not a fixed point of interest in this one.
func _spawn_pilgrim(entry: Vector2i, reserved: Dictionary) -> void:
	var tile := _find_prop_tile(
		PILGRIM_ANCHOR, PILGRIM_SCAN_RADIUS, entry, reserved, PILGRIM_CLEAR_FROM_ENTRY)
	reserved[tile] = true
	var pilgrim := Pilgrim.new()
	pilgrim.name = "PilgrimFortress"
	pilgrim.zone_id = "fortress"
	pilgrim.sprite_texture = load(NPC_SPRITE)
	var spr := Sprite2D.new()
	spr.name = "Sprite2D"
	spr.texture = load(NPC_SPRITE)
	pilgrim.add_child(spr)
	pilgrim.position = _tile_center(tile.x, tile.y)
	add_child(pilgrim)


## Two guards, three bowmen, a boar and two lights. Each tile is marked reserved as
## it is taken, so two posts whose anchors are close can never collapse onto the
## same tile once the grid nudges them, and none of them can land on the stair, on
## the entry or inside the arena.
func _spawn_enemies(entry: Vector2i, reserved: Dictionary) -> void:
	for post: Array in [
		[SKELETON_SCENE, GUARD_A_ANCHOR, "GuardA"],
		[SKELETON_SCENE, GUARD_B_ANCHOR, "GuardB"],
		[SKELETON_ARCHER_SCENE, ARCHER_A_ANCHOR, "SkeletonArcherA"],
		[SKELETON_ARCHER_SCENE, ARCHER_B_ANCHOR, "SkeletonArcherB"],
		[BOAR_SCENE, BOAR_A_ANCHOR, "BoarA"],
		[WISP_SCENE, WISP_A_ANCHOR, "WispA"],
		[WISP_SCENE, WISP_B_ANCHOR, "WispB"],
		[SKELETON_ARCHER_SCENE, ARCHER_C_ANCHOR, "SkeletonArcherC"],
	]:
		var tile := _find_prop_tile(
			post[1] as Vector2i, ENEMY_SCAN_RADIUS, entry, reserved, ENEMY_CLEAR_FROM_ENTRY)
		reserved[tile] = true
		_spawn_enemy(String(post[0]), tile.x, tile.y, String(post[2]))


## Every tile of a rect, in row-major order. Used to hand the arena to the reserved
## set, which is keyed by tile rather than by shape.
func _rect_tiles(rect: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			out.append(Vector2i(x, y))
	return out


## The outward row-major scan of `ZoneBase._find_walkable_near` with two rules
## added: a tile a prop already stands on is not free, and neither is a tile
## closer than `clear_from_entry` to the tile the player arrives on (Chebyshev, so
## the diagonal counts as close too). Deterministic for the same reason the base
## scan is — the order depends only on the anchor and the grid. The same rule the
## ruins and the dungeon keep their own copy of; the base class owns the shared
## plumbing and this is content.
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


## The fortress has no villagers and therefore no schedule to serve, but the day
## cycle is world-owned state the HUD reads through the `day_clock` group, so the
## zone runs its own clock. The sanctum has no sky and the ritual broke whatever
## ceiling it had, but the clock line in the HUD is not the sky: without a clock it
## would simply go blank for as long as the player stood here.
func _setup_day_cycle() -> void:
	day_clock = DayClock.new()
	day_clock.name = "DayClock"
	add_child(day_clock)
