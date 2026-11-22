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

## One-line description of each fate, shown next to its name on the choice panel so the
## player reads what he is picking rather than three bare titles. The names themselves
## live with the victory screen (`Hud.ENDING_NAMES_RU`); these are the glosses.
const ENDING_DESCRIPTIONS := {
	"dawn": "Отпустить пепел и встретить новый рассвет",
	"memory": "Сохранить память о короле и его печати",
	"crown": "Принять пепельный венец и власть Короля",
}

## The reason a locked fate stays shut, shown on the panel and toasted when a player
## confirms it anyway. `dawn` is never locked; `memory` needs the pilgrim's truth, and
## `crown` needs that truth plus the King's own seal (`rusted_seal`, his guaranteed
## drop) — the hidden fate stays hidden until the player actually earned it (spec §4.4).
const LOCK_MEMORY := "Нужно узнать правду о печати"
const LOCK_CROWN := "Нужна печать короля"


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


## The in-world affordance. Before the King falls and once a fate is committed it only
## answers with a toast; once the throne is open it hands the screen to the HUD's real
## choice panel (`open_ending_choice`), which reads availability back from this altar and
## commits through `choose()` — so the panel never disagrees with the altar about what is
## a valid, unlocked, not-yet-taken ending. The fallback toast stays for a scene with no
## HUD (a bare test arena), where there is no panel to open.
func interact(_player: Node) -> void:
	if not _king_defeated():
		EventBus.toast.emit("Сначала победите короля")
		return
	if _ending_taken():
		EventBus.toast.emit("Судьба уже решена")
		return
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("open_ending_choice"):
		hud.call("open_ending_choice", self)
	else:
		EventBus.toast.emit("Трон ждёт: рассвет, память или венец")


## Commits an ending. Accepts only one of `dawn`, `memory`, `crown`, only once the King
## is dead, only while no ending has been taken, and only if that fate is unlocked
## (`_lock_reason`): `memory` needs the pilgrim's truth, `crown` needs the truth plus the
## King's seal. A locked fate is refused with `false` and a toast naming what is missing,
## changing nothing — the panel keeps the player on the throne so he can pick another.
## On success it records the ending in `GameState` (a persisted `ending` field plus an
## `ending_<id>` flag) and opens the victory screen.
func choose(ending_id: String) -> bool:
	if not ENDINGS.has(ending_id):
		return false
	if not _king_defeated():
		return false
	if _ending_taken():
		return false
	var reason := _lock_reason(ending_id)
	if reason != "":
		EventBus.toast.emit(reason)
		return false
	GameState.set_flag("ending_" + ending_id, true)
	GameState.ending = ending_id
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("show_victory"):
		hud.call("show_victory", ending_id)
	Telemetry.event(&"ending_chosen", {"ending": ending_id})
	return true


# --- availability (the single source of truth the choice panel reads) -----------

## The three ids in display order, so the panel lists exactly what `choose()` accepts
## without hardcoding the set a second time.
func ending_ids() -> Array[String]:
	return ENDINGS


func ending_description(ending_id: String) -> String:
	return String(ENDING_DESCRIPTIONS.get(ending_id, ""))


## Whether a fate can be chosen right now. `dawn` is free once the King is dead; `memory`
## needs `pilgrim_truth_known`; `crown` needs that truth and the `rusted_seal` in the
## inventory. Read-only: it never writes state, so the panel can ask every frame.
func ending_is_available(ending_id: String) -> bool:
	return _lock_reason(ending_id) == ""


## The player-facing reason a fate is locked, or "" when it is available.
func ending_lock_reason(ending_id: String) -> String:
	return _lock_reason(ending_id)


func _lock_reason(ending_id: String) -> String:
	match ending_id:
		"dawn":
			return ""
		"memory":
			return "" if _truth_known() else LOCK_MEMORY
		"crown":
			if _truth_known() and GameState.count_item("rusted_seal") > 0:
				return ""
			return LOCK_CROWN
		_:
			return ""


func _truth_known() -> bool:
	return bool(GameState.get_flag("pilgrim_truth_known", false))



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
