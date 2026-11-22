class_name Pilgrim
extends Npc
## The ninth named NPC of spec §12: Пепельный Паломник — a masked figure in a grey
## cloak who turns up in every zone, almost never speaks, and is a fragment of the
## king's ritualist consciousness held inside the seal. His memory is incomplete,
## so each zone gives him one more piece back: he is the cross-zone story thread
## and the only source of information about the final boss.
##
## He is deliberately NOT a quest giver. The base `Npc` is a single-quest giver and
## `Villager` is a multi-quest one; the pilgrim hands out neither quests nor
## rewards — only a flag-gated fragment of the truth, one per zone, in story order.
## So he overrides the whole interaction: the data-driven conversation is the only
## thing he does, and when he has nothing new he simply says one short line.

## Which zone this instance stands in, so `interact()` and `prompt_text()` can name
## the right conversation (`pilgrim_<zone_id>`). Set by the world that spawns him;
## the default keeps a bare `Pilgrim` pointed at the forest fragment.
@export var zone_id: String = "forest"

## The flag that marks this zone's fragment as heard, and the flag the PREVIOUS
## zone's fragment must have set before this one becomes available. The chain is
## forest -> ruins -> dungeon -> fortress; the forest has no prerequisite. The
## fortress fragment additionally sets `pilgrim_truth_known` (see below) — that is
## the flag the ending reads, and it is set by the dialogue data, not here.
const MET_FLAG_PREFIX := "pilgrim_met_"
const PREREQ_FLAGS := {
	"forest": "",
	"ruins": "pilgrim_met_forest",
	"dungeon": "pilgrim_met_ruins",
	"fortress": "pilgrim_met_dungeon",
}

## The flag the fortress fragment sets and the ending choice later reads. Named
## here so the silence lines and the prompt agree with the dialogue data on the one
## string that means "the player now understands what the crown is".
const TRUTH_FLAG := "pilgrim_truth_known"


func _ready() -> void:
	# Identity is fixed by the character, not by the spawner, so a bare `Pilgrim`
	# built anywhere is already the pilgrim. Assigned before `super()` because the
	# base `_ready` builds the marker bubble and the prompt reads the name.
	display_name = "Пепельный Паломник"
	speaker_id = "pilgrim"
	super()
	# A grey cloak on the one shared NPC sprite (no new sprite file): distinct from
	# the herbwife's green, the merchant's blue, the smith's forge orange and the
	# undercroft watchwoman's cool grey. Guarded because a bare `Pilgrim` built
	# without the world's sprite has none.
	if sprite != null and is_instance_valid(sprite):
		sprite.modulate = Color(0.62, 0.62, 0.66)


## The conversation this instance owns: `pilgrim_<zone_id>`.
func dialogue_id() -> String:
	return "pilgrim_%s" % zone_id


func prompt_text() -> String:
	# He only invites speech when he actually has a new fragment for the player;
	# otherwise the prompt says he is silent, which is the whole character.
	return "Заговорить" if has_something_new() else "Молчит"


func interact(_player: Node) -> void:
	# Story only. The runner is built with the live state injected, exactly like the
	# base `Npc`, so the same object a test constructs is the one the game uses. It
	# consumes the interaction only when a HUD can show it.
	var runner := DialogueRunner.new(GameState, QuestManager)
	if runner.start(dialogue_id()):
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("open_dialogue_runner"):
			hud.open_dialogue_runner(runner)
			return

	# The runner refused — the previous zone's fragment is not heard yet (he is not
	# ready and stays silent), or this zone's is already heard (he has nothing left
	# to remember) — or there is no HUD to show it. Either way he says one short
	# line through the existing dialogue panel. He never starts a quest here.
	var text := "Он молчит."
	if _is_heard():
		text = "Он уже сказал всё, что помнит."
	var lines: Array = [{"speaker": display_name, "text": text}]
	EventBus.dialogue_requested.emit(lines)


## True when this zone's fragment is available to hear right now: the previous
## zone's flag is set (or there is no previous zone) and this zone's own flag is
## not yet set. This is the same rule the dialogue's `condition` encodes, kept here
## so the prompt and the silence lines never disagree with what the runner accepts.
func has_something_new() -> bool:
	return _prereq_met() and not _is_heard()


func _prereq_met() -> bool:
	var prereq := _prereq_flag()
	if prereq == "":
		return true
	return GameState.get_flag(prereq, false) == true


func _is_heard() -> bool:
	return GameState.get_flag(_met_flag(), false) == true


func _met_flag() -> String:
	return MET_FLAG_PREFIX + zone_id


func _prereq_flag() -> String:
	return String(PREREQ_FLAGS.get(zone_id, ""))


## The pilgrim gives no quest, so the marker over his head is always off. The base
## `Npc` would light it for whatever `quest_id` it defaults to (Edrik's hunt), which
## would be a lie on a character who offers nothing.
func _refresh_bubble() -> void:
	if _bubble != null:
		_bubble.visible = false
