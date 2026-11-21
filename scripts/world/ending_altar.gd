class_name EndingAltar
extends Area2D
## The throne at the heart of the broken sanctum (spec §11.4, §16.1): the place the
## whole route walked towards, and the only object that ends the run.
##
## It is an `interactable`, exactly like a zone exit or a chest — nothing more: it owns
## no overlap handler, so standing on it does nothing. The throne stays inert until the
## King is dead; until then its only answer is to say so. That gate is the difference
## between a throne and a door: the ending is something the player earns by finishing
## the fight, not a shortcut past it.
##
## The choice itself is committed through `choose(ending_id)`, the altar's public seam.
## `interact()` is the in-world affordance that refuses before the King has fallen and,
## once he has, tells the player the three fates are open; the commit lives in
## `choose()` so that whatever surface eventually presents the three options — a button
## row, a key, a test — calls the same one function and cannot disagree with it about
## what a valid ending is or whether one has already been taken. The altar writes the
## ending into `GameState` (both a persisted `ending` field and an `ending_<id>` flag)
## and hands the id to the HUD's victory screen; it owns no screen of its own.

## The three endings of spec §16.1, in the order the throne names them. An id outside
## this set is refused rather than guessed at, so a bad caller cannot invent a fourth.
const ENDINGS: Array[String] = ["dawn", "memory", "crown"]

## The line the HUD shows as `[E] <prompt>` while the player stands in reach, before
## and after the King falls. Two strings because the throne genuinely is a different
## object on the two sides of that death: a sealed seat, then a choice.
@export var prompt_locked: String = "Трон"
@export var prompt_open: String = "Выбрать судьбу"

const COLOR_FILL := Color(0.16, 0.13, 0.10, 0.95)
const COLOR_EDGE := Color(0.78, 0.66, 0.34, 0.95)
const COLOR_SEAT := Color(0.30, 0.25, 0.16, 0.95)


func _ready() -> void:
	add_to_group("interactable")
	# The interactable physics layer, and no mask at all: the throne reports no
	# overlap to anything, because nothing in the project masks this layer. The shape
	# is here so the area is a real area, not a trigger.
	collision_layer = 32
	collision_mask = 0
	var shape := CircleShape2D.new()
	shape.radius = 10.0
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	add_child(collision)


## The throne reads as a sealed seat until the King falls, and as a choice after. The
## player's interact scan calls this to decide what to show under `[E]`.
func prompt_text() -> String:
	return prompt_open if _king_defeated() else prompt_locked


func interact(_player: Node) -> void:
	if not _king_defeated():
		EventBus.toast.emit("Сначала победите короля")
		return
	if _ending_taken():
		EventBus.toast.emit("Судьба уже выбрана")
		return
	EventBus.toast.emit("Трон ждёт: рассвет, память или венец")


## Commits an ending. Accepts only one of `dawn`, `memory`, `crown`, and only once the
## King is dead and no ending has been taken yet; every other case is refused with
## `false` and changes nothing. On success it records the ending in `GameState` (a
## persisted `ending` field plus an `ending_<id>` flag) and opens the victory screen.
func choose(ending_id: String) -> bool:
	if not ENDINGS.has(ending_id):
		return false
	if not _king_defeated():
		return false
	if _ending_taken():
		return false
	GameState.set_flag("ending_" + ending_id, true)
	GameState.ending = ending_id
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("show_victory"):
		hud.call("show_victory", ending_id)
	Telemetry.event(&"ending_chosen", {"ending": ending_id})
	return true


func _king_defeated() -> bool:
	return bool(GameState.get_flag("king_defeated", false))


func _ending_taken() -> bool:
	return String(GameState.ending) != ""


## A plain stone throne, drawn rather than textured: the slice has no throne sprite,
## and a generated placeholder is easier to replace with real art than a node wired
## into a scene file would be.
func _draw() -> void:
	var back := Rect2(-7, -16, 14, 18)
	draw_rect(back, COLOR_FILL)
	draw_rect(Rect2(-5, -13, 10, 12), COLOR_SEAT)
	draw_rect(back, COLOR_EDGE, false, 1.0)
