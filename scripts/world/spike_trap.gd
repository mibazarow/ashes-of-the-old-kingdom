class_name SpikeTrap
extends Area2D
## Telegraphed trap: the plate flashes for `telegraph_time`, then the hitbox
## opens for `active_time`. Never damages without the warning phase.

@export var telegraph_time: float = 0.55
@export var active_time: float = 0.18
@export var cooldown: float = 1.6
@export var damage: int = 12

## --- warning readability (CRITIC-P1-10) ---------------------------------------
## The old plate was a warm brown ColorRect at alpha 0.35 ramping to a warm red
## at 0.75 — 1.06..1.53:1 against every floor, i.e. invisible until the spikes
## were already out. Same rule as the enemy telegraph now: a hard dark outline
## that never fades, a saturated cool fill for the warning, and an alpha ramp
## that starts where the fill alone already clears 3:1 on the darkest floor.
## The idle alpha stays at or below 0.5 on purpose: the debug bots read a plate
## alpha above 0.5 as "the warning is running", and idle must not trip them.
const IDLE_FILL := Color(0.10, 0.55, 0.65)
const WARNING_FILL := Color(0.0, 0.90, 1.0)
const ACTIVE_FILL := Color(1.0, 0.35, 0.95)
const OUTLINE_COLOR := Color(0.02, 0.03, 0.05, 1.0)
const IDLE_ALPHA := 0.5
const WARNING_ALPHA_START := 0.6
const WARNING_ALPHA_PEAK := 0.95
const ACTIVE_ALPHA := 0.95

@onready var visual: ColorRect = $Visual
@onready var hitbox: CollisionShape2D = $CollisionShape2D

var _timer := 0.0
var _phase := 0  # 0 idle, 1 telegraph, 2 active, 3 cooldown
var _hit_id := ""
var _swing := 0


func _ready() -> void:
	hitbox.disabled = true
	# The outline is a child drawn behind the plate (show_behind_parent), so it
	# keeps its full opacity through the plate's alpha ramp — the ramp rides on
	# `visual.color`, which children do not inherit.
	if visual.get_node_or_null("Outline") == null:
		var outline := ColorRect.new()
		outline.name = "Outline"
		outline.color = OUTLINE_COLOR
		outline.offset_left = -1.0
		outline.offset_top = -1.0
		outline.offset_right = visual.offset_right - visual.offset_left + 1.0
		outline.offset_bottom = visual.offset_bottom - visual.offset_top + 1.0
		outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		outline.show_behind_parent = true
		visual.add_child(outline)
	visual.color = Color(IDLE_FILL.r, IDLE_FILL.g, IDLE_FILL.b, IDLE_ALPHA)
	_timer = cooldown * 0.5


func _physics_process(delta: float) -> void:
	_timer -= delta
	match _phase:
		0:
			if _timer <= 0.0:
				_phase = 1
				_timer = telegraph_time
				_swing += 1
				_hit_id = DamageResolver.make_hit_id(get_instance_id(), _swing)
		1:
			var t := 1.0 - clampf(_timer / telegraph_time, 0.0, 1.0)
			visual.color = Color(WARNING_FILL.r, WARNING_FILL.g, WARNING_FILL.b,
				WARNING_ALPHA_START + (WARNING_ALPHA_PEAK - WARNING_ALPHA_START) * t)
			if _timer <= 0.0:
				_phase = 2
				_timer = active_time
				hitbox.disabled = false
				visual.color = Color(ACTIVE_FILL.r, ACTIVE_FILL.g, ACTIVE_FILL.b, ACTIVE_ALPHA)
				_apply_hits()
		2:
			if _timer <= 0.0:
				hitbox.disabled = true
				_phase = 3
				_timer = cooldown
				visual.color = Color(IDLE_FILL.r, IDLE_FILL.g, IDLE_FILL.b, IDLE_ALPHA)
		3:
			if _timer <= 0.0:
				_phase = 0


func _apply_hits() -> void:
	for body in get_overlapping_bodies():
		if body.has_method("receive_damage"):
			DamageResolver.resolve_hit(self, body, {
				"damage": damage,
				"hit_id": _hit_id,
				"damage_type": "trap",
			})
