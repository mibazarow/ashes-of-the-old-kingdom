class_name BossCaptain
extends Boss
## The Captain of the Funeral Guard (spec §11): the ruins' boss, met in the hall
## behind the locked door.
##
## Its identity in phase one is the shield: a heavy `frontal_block` soaks most of
## what lands inside its facing cone, so the honest answer to the Captain is to get
## behind it. Phase two is the moment that answer is taken away — below half health
## the Captain drops the guard for good (`frontal_block` to 0), abandons defence for
## offence (the base enrage makes it chase faster and swing sooner), starts landing
## its heavy swing on every second swing instead of every third, and reads its
## swings in a different telegraph colour so the change is legible rather than a
## silent number.
##
## The enrage multipliers themselves are the base `Boss` exports (`enraged_speed_-
## multiplier`, `enraged_cooldown_multiplier`), set on the scene to 1.35 and 0.7, so
## the speed and cooldown changes are the base one-way enrage and are not
## duplicated here. What this script owns is the shield drop, the heavier cadence,
## and the phase-two telegraph colour — none of which the base class expresses.

## Phase two lands the heavy swing on every second swing instead of the base three.
const HEAVY_EVERY_PHASE_TWO := 2
## A saturated violet for phase two, so a player who read the cyan ordinary and
## magenta heavy promises in phase one now reads a third, different one on every
## swing. Violet, not the old pale ice blue: the ruins floor it is read against
## separates from a dark outline at 5.3:1, and violet keeps that outline-plus-
## saturated-fill rule the Captain's swings now follow (CRITIC-P1-09).
const PHASE2_TELEGRAPH_COLOR := Color(0.55, 0.30, 1.0, 1.0)


func _enter_phase_two() -> void:
	super()
	# The guard is gone permanently. The base enrage has already multiplied speed
	# and cooldown exactly once; this only removes the defence and recolours.
	frontal_block = 0.0
	_base_telegraph_color = PHASE2_TELEGRAPH_COLOR
	if telegraph != null and state != State.ATTACK:
		telegraph.color = PHASE2_TELEGRAPH_COLOR


## Base decides the heavy swing on every third; the Captain, once enraged, decides
## it on every second. The base `_start_attack` has already counted the swing and
## set the heavy flag for the three-count; in phase two this overrides that decision
## and re-applies the matching wind-up and telegraph, so the borrowed wind-up hand-
## back in `_process_attack` still works untouched.
func _start_attack() -> void:
	super()
	if current_phase() < 2:
		return
	_heavy_swing = _swing_counter % HEAVY_EVERY_PHASE_TWO == 0
	windup_multiplier = current_swing_windup()
	if telegraph != null:
		telegraph.color = HEAVY_TELEGRAPH_COLOR if _heavy_swing else _base_telegraph_color
