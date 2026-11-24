extends Node
## Debug bot. Drives the real Player through the same InputSource the human
## uses — no teleports, no direct writes to world state.
##
## Run: godot --headless --path . -- --bot=BOT-001
## Scenarios: BOT-001 talk, BOT-002 quest loop, BOT-003 combat arena,
##            BOT-004 magic, BOT-005 inventory/economy, BOT-006 quest chain,
##            BOT-007 traps/secrets, BOT-008 kill, BOT-009 save/load,
##            BOT-010 soak, BOT-011 take damage, BOT-012 dungeon descent,
##            BOT-013 fortress and the King without a Crown.
## Profiles: cautious, normal, aggressive, explorer, collector, novice, master.
##
## Run length: BOT-010 is bounded in simulated seconds (`--soak=<seconds>`,
## default SOAK_SECONDS_DEFAULT), every other scenario by its own wall-clock
## budget. The soak is the one scenario whose whole point is elapsed simulation.

const QUEST_ID := "q01_ash_wolves"
const SCENARIO_TIMEOUT := 75.0
## How long BOT-010 runs when nobody says otherwise, counted in simulated seconds
## (physics steps at 60 Hz), not in wall-clock ones. The spec's own table asks for a
## soak of half an hour to an hour; 75 s was a smoke test that had been allowed to
## call itself an endurance run. Six hundred seconds is the floor at which a soak can
## actually find a slow leak, and `--soak=` moves the number for a quick local check
## without touching the default a release gate runs on.
const SOAK_SECONDS_DEFAULT := 600.0
## The soak's own budget in the unit the other scenarios use, so the retreat budget
## below can be scaled against a run that is eight times longer without the constant
## the test suite pins having to move.
const SOAK_BUDGET_REFERENCE_SECONDS := 75.0

## The watchdog (spec §19.6 «BotWatchdog»). These four numbers are the whole
## detector; the test suite reads them off the live constant map, so a threshold
## cannot be quietly widened until it never fires.
##
## The watchdog never aborts a run. Its job is to make a stall visible in the log
## and counted in the verdict (`STUCK: N`), not to end the run that stalled — a bot
## that quits on its own anomaly reports nothing about it.
##
## A hero who holds a movement key and moves less than this far in
## `WATCHDOG_STUCK_MS` is against something. Eight pixels is half a tile: less than
## the distance a body-blocked player slides along a wall, more than the jitter of a
## collision resolution.
const WATCHDOG_STUCK_PX := 8.0
const WATCHDOG_STUCK_MS := 3000
## The same (goal, action) pair issued this many times with no change in the world
## between them is a loop rather than an attempt. Twelve is deliberately above the
## three-to-four presses a leg legitimately repeats (knock a gate twice, swing twice
## at the same wolf) and below the hundreds a stuck run would rack up.
const WATCHDOG_CYCLE_REPEATS := 12
## A streak shorter than this is a fast hand, not a cycle: twelve taps of the same
## key take half a second, and a hero mid-swing is not stuck.
const WATCHDOG_CYCLE_MIN_MS := 2000
## An active goal that has not moved the world at all for this long is reported even
## when the hero is walking, because «busy» and «making progress» are different facts
## and only the second one is what a soak is for.
const WATCHDOG_ZERO_PROGRESS_MS := 45000
## One observation per this many milliseconds, written by the same tick that samples
## the watchdog. `Telemetry.PERF_INTERVAL_MS` is the performance file's own beat.
const WATCHDOG_SAMPLE_MS := 1000
## Absolute physics frame every scenario parks to before it acts, so a run begins
## on the same simulation step regardless of how many frames the world's deferred
## load took. Comfortably past world build (the forest spawns its cast within the
## first few frames) yet early enough to leave the full budget to the scenario.
const RUN_START_FRAME := 120


class BotInput:
	extends RefCounted

	var _pressed: Dictionary = {}
	## The physics frame a press edge is armed to be delivered on, or -1 when no
	## edge is pending. The press is armed for the step *after* the one the bot's
	## coroutine observed (see `hold`), because that coroutine resumes in the idle
	## phase between steps and the frame it reads is sometimes the step then running
	## and sometimes the one about to run. Stamping the previous design's own frame
	## made the edge expire unread whenever the stamp and the player's
	## `_physics_process` poll landed a step apart, so one seed silently fired a
	## different number of attacks launch to launch. Targeting the next step pins
	## delivery to a single unambiguous step regardless of where in the frame the
	## resume happened.
	var _just: Dictionary = {}
	var _aim: Vector2 = Vector2.RIGHT

	func is_action_pressed(action: StringName) -> bool:
		return bool(_pressed.get(String(action), false))

	func is_action_just_pressed(action: StringName) -> bool:
		var key := String(action)
		# The bot arms a press for the step *after* the one it observed, because its
		# coroutine resumes in the idle phase between steps and the frame it reads is
		# sometimes the step then running and sometimes the one about to run. Targeting
		# the next step makes the delivery land on a single, unambiguous step no matter
		# where in the frame the resume happened, instead of the press expiring unread
		# when the stamp and the player's `_physics_process` poll landed a step apart —
		# the drop that made one seed fire a different number of attacks launch to launch.
		if int(_just.get(key, -1)) != Engine.get_physics_frames():
			return false
		# One press is one press. The engine's own `just_pressed` is true for the
		# whole physics tick, and a panel polled by `_process` can catch that tick
		# two, three times between two ticks — a human holding E in a shop buys one
		# potion per click, and the bot's tap must buy one potion per tap. The edge
		# is therefore disarmed the instant it is handed out.
		_just[key] = -1
		return true

	func get_vector(nx: StringName, px: StringName, ny: StringName, py: StringName) -> Vector2:
		var v := Vector2.ZERO
		if is_action_pressed(px):
			v.x += 1.0
		if is_action_pressed(nx):
			v.x -= 1.0
		if is_action_pressed(py):
			v.y += 1.0
		if is_action_pressed(ny):
			v.y -= 1.0
		return v.normalized()

	func aim_direction(from: Vector2) -> Vector2:
		if from.distance_to(_aim) < 0.5:
			return Vector2.RIGHT
		return from.direction_to(_aim)

	func set_aim(p: Vector2) -> void:
		_aim = p

	func hold(action: StringName, on: bool) -> void:
		var key := String(action)
		var was := bool(_pressed.get(key, false))
		if was == on:
			# Restating a held key is not an event. The walker calls `hold` on all
			# four movement keys every physics step, and a run that logged each of
			# those would write 240 identical lines a second to say the hero kept
			# walking east. The spec's §20.3 says input is recorded по событию, and
			# this is the one place that knows which of those calls was a change.
			return
		if on and not was:
			_just[key] = Engine.get_physics_frames() + 1
		_pressed[key] = on
		Telemetry.input({
			"action": key,
			"pressed": on,
			"frame": Engine.get_physics_frames(),
			"source": "bot",
		})

	func release_all() -> void:
		for key: String in _pressed.keys():
			if not bool(_pressed[key]):
				continue
			_pressed[key] = false
			Telemetry.input({
				"action": key,
				"pressed": false,
				"frame": Engine.get_physics_frames(),
				"source": "bot",
			})


## Behaviour profiles from the spec (§19.3). They change how the bot weighs
## risk: when it heals, how close it lets enemies get, whether it detours.
## The three profiles added with spec §19.5 bring behaviour keys the original
## four never had (`reaction_delay`, `use_ability`, `retreat_below`,
## `pickup_bias`, `merchant_stacks`). Every one of them defaults — through
## `_pf()` — to exactly what the original four did before the keys existed, so
## the four dicts above stay byte-for-byte what they were and their runs cannot
## drift. `collector` loots first, heals early and unloads a full bag at the
## merchant; `novice` hesitates, heals late and never casts; `master` reacts
## fast, fights with the ability on cooldown and breaks off below a quarter HP.
const PROFILES := {
	"cautious": {"heal_at": 0.75, "engage_range": 14.0, "dash_chance": 0.35, "detour": true},
	"normal": {"heal_at": 0.5, "engage_range": 16.0, "dash_chance": 0.15, "detour": true},
	"aggressive": {"heal_at": 0.25, "engage_range": 20.0, "dash_chance": 0.05, "detour": false},
	"explorer": {"heal_at": 0.6, "engage_range": 12.0, "dash_chance": 0.2, "detour": true},
	"collector": {"heal_at": 0.65, "engage_range": 10.0, "dash_chance": 0.25, "detour": true,
		"reaction_delay": 0.15, "use_ability": false, "retreat_below": 0.0,
		"pickup_bias": true, "merchant_stacks": 6},
	"novice": {"heal_at": 0.3, "engage_range": 16.0, "dash_chance": 0.0, "detour": true,
		"reaction_delay": 0.35, "use_ability": false, "retreat_below": 0.0,
		"pickup_bias": false, "merchant_stacks": 0},
	"master": {"heal_at": 0.6, "engage_range": 22.0, "dash_chance": 0.5, "detour": false,
		"reaction_delay": 0.05, "use_ability": true, "retreat_below": 0.25,
		"pickup_bias": false, "merchant_stacks": 0},
}

## Soak (BOT-010) survival tuning, kept out of PROFILES because the soak ignores
## the profile dict on purpose: it is a fixed 75 s endurance run, not a risk
## appetite. Named constants so the test suite reads the values the scenario
## actually uses instead of duplicating literals. The stage D boar hits for 13
## (the wolf managed 8) and the soak target picker has no retreat of its own, so
## the old 0.35 threshold left the bot one missed potion window from dead.
const SOAK_HEAL_AT := 0.5
## Distance at which an enemy counts as "already in melee" for the disengage
## rule. Enemy melee reach is 18 px, so this breaks out just before the swing.
const SOAK_MELEE_RANGE := 24.0
## How far the bot keeps putting between itself and the enemy it has broken off
## from, while it is still below the heal threshold. The burst only has to break
## contact; without a wider steer the bot stops running at 25 px, the enemy walks
## back into reach, and the whole disengage buys nothing.
const SOAK_DISENGAGE_RANGE := 60.0
## Longest single disengage burst, and the total the whole run may spend in those
## bursts. Both caps are load-bearing: without the per-burst cap the bot could
## drift through a whole attack cycle, and without the run-wide budget the bursts
## could eat the entire window and turn the soak into a run that never swings.
## Surviving does not depend on the budget, though — the free steering below is
## what keeps the bot out of reach once the bursts are spent.
const SOAK_RETREAT_TIME := 0.6
const SOAK_RETREAT_BUDGET := 25.0
## A distance change between two soak samples larger than this is not walking. The
## hero covers about 12 px between the loop's samples at a full run, and a disengage
## burst inside the same iteration adds another 40; a respawn puts him back on the
## zone's spawn point, which is hundreds. Anything past this is counted as a jump and
## kept out of the distance the movement term is judged on.
const SOAK_TELEPORT_PX := 80.0

## How far off a boss the soak hero keeps himself, and the reason the run stops
## dying on a timer. The forest posts two: the 180 HP `forest_warden` at (43,6)
## and the 260 HP `root_mother` at (24,24). Neither is stationary — the Root
## Mother walked out to (17,21) and met the hero there — so no patrol line can be
## drawn round them, and a hero who treats either as another wolf to swing at is
## feeding a 260 HP pool with a 112 HP bar. Measured on the fixed soak seed from
## `combat.jsonl`: the two bosses, plus the spiders the one of them summons, drank
## 545 of the run's 1108 damage, and a boss stood on the tile of three of its six
## deaths. The hero outpaces every melee hostile here, so steering is real safety
## bought with no teleport and no invulnerability, and the `boss` group the HUD bar
## and the map marker already read is what marks them — the game's own fact about
## who is a boss, not a name list the bot keeps for itself. This floor is what a
## boss with no ranged mechanic of its own gets; `_soak_boss_clearance` widens it
## for the one that does.
const SOAK_BOSS_AVOID_RANGE := 112.0
## Extra room laid on top of a boss's own ranged gate. See `_soak_boss_clearance`.
const SOAK_BOSS_AVOID_MARGIN := 36.0

## BOT-003 — which enemy kinds stand in for the three roles the spec's arena
## (§19.5: «ближний, дальний и поддерживающий враг») asks for. The list is a
## constant and not a guess made at runtime because the forest genuinely does not
## have a support enemy: `aura_heal_per_second` is set on exactly one scene in
## the game, `cultist_caster.tscn`, and that scene is placed in one place, the
## ruins hall behind the sealed door. So the arena names the roles by the trait
## that defines them and goes and finds each one, instead of quietly passing on
## two roles and a wolf.
##
## `cultist_caster` is listed under support and deliberately not under ranged
## even though its scene is `kind = 1`: the aura is the trait under test, and a
## caster counted as the ranged entry would let the arena pass without ever
## meeting a healer.
const ARENA_MELEE_KINDS: Array[String] = ["ash_wolf", "ash_boar", "spider", "slime", "tick",
	"lumberjack", "root_beast", "ruin_skeleton", "shieldbearer", "royal_guard",
	"grave_hound"]
const ARENA_RANGED_KINDS: Array[String] = ["ash_archer", "ash_wisp", "ruin_skeleton_archer"]
const ARENA_SUPPORT_KINDS: Array[String] = ["cultist_caster"]
## The arena spans two zones now, so it gets its own window instead of borrowing
## the 75 s single-map budget: the forest's archer and the gate are forty tiles
## east of the spawn, and the healer is a key, a lever and a hall further still.
const ARENA_TIMEOUT := 330.0
## How far the arena will detour for a role it has not yet traded blows with, and
## how close anything has to be before the arena stops marching and swings. The
## leash is short on purpose: a role the bot cannot walk to in a few seconds is a
## role the leg it is on will bring it to anyway.
const ARENA_HUNT_LEASH := 200.0
const ARENA_ENGAGE := 26.0
## Longest the arena walks without re-checking its own health. `_travel_to` is the
## walker; the arena only needs a chance to heal and to break off between legs.
const ARENA_CHUNK := 6.0
## Drink earlier than the profile says here. The arena crosses into ground with
## no safe zone in it — the forest village is the only place in the game nothing
## follows you into — so once the bot is past the ruins door a heal window it
## sleeps through is not recovered by breaking off. 0.6 buys one more potion than
## the profile's 0.5 and that is the whole margin between a hall and a corpse.
const ARENA_HEAL_AT := 0.65
## How long one break-off may last, and how soon another one is allowed after it
## ends. Both halves are load-bearing. Without the budget a hero who is hurt and
## out of medicine has nothing left to do but stand on the rally point and take
## arrows from the far end of the map until the scenario clock runs out — which is
## exactly how one run ended, at 23 HP, having done nothing at all for the last
## three minutes of its life. Without the cooldown the same low HP re-triggers the
## break on the very next frame and the run stalls in a different way instead.
const ARENA_BREAK_BUDGET := 12.0
const ARENA_BREAK_COOLDOWN := 20.0

## The radius a mini-boss is treated as a hazard to route around rather than a
## target to walk into. It is the same number the HUD reads to decide when a boss
## bar is worth drawing (`hud.gd` `BOSS_ENGAGE_RADIUS`): inside it the boss is
## engaged, so a leg that has no business fighting one should not be standing in
## it. The A* threat cost prices every tile inside this radius, so a route that
## can skirt the boss's yard does, and only a goal that genuinely sits inside the
## yard (the east sword chest, which the warden guards) pulls the lane back in.
## Named so the test suite reads the radius the path cost actually uses instead of
## duplicating a literal that could drift from the cost function.
const BOSS_AVOID_RADIUS := 200.0
## How close a boss must be, in melee reach, before a leg that is only trying to
## get somewhere breaks contact with it. The warden's own swing reaches 18 px; this
## is just past that, so the break happens before the hit, not after.
const BOSS_RETREAT_MELEE_RANGE := 26.0
## Below this share of HP a leg that has opted into boss avoidance will not stand
## in a boss's melee to reach its goal: it breaks contact, heals, and resumes. The
## east road to the chest is the lane this was written for — a hero who waits to
## 35 % is a hero the warden ends before the chest.
const BOSS_RETREAT_HEAL_BELOW := 0.5
## The whole run's budget for breaking off from a boss, and the cap on one break.
## Both are load-bearing and both bound the rule: without the per-burst cap one
## break could drift through a whole attack cycle, and without the run-wide budget
## a low-HP hero would kite the warden for the rest of the scenario and never open
## the chest. Surviving the east road must not cost the whole run.
const BOSS_RETREAT_BURST := 2.5
const BOSS_RETREAT_BUDGET := 8.0
## BOT-005's own drink threshold on the map-crossing legs. The profile's 0.5 is
## tuned for a duel the hero can walk away from; the east road to the chest is not
## a duel, it is a march past an archer's clearing and into a warden's yard, and a
## heal window slept through there is not recovered by breaking off. This is the
## number the walker obeys on those legs, named so the test suite reads the value
## the scenario actually sets rather than a literal retyped in two places. It must
## stay well above the old 0.35 that let a run reach the chest as a corpse.
const ECONOMY_TRAVEL_HEAL_AT := 0.7
## The PASS rule, written once here so the guide, the notes and the test suite all
## quote the same sentence the scenario actually enforces.
## An empty role list: a leg that is only about getting somewhere.
const NO_ROLES: Array[String] = []
const ARENA_CRITERION := "dealt damage to >=1 kind from each of melee/ranged/support, survived, no control lock >=1500ms, >=1 target switch, >=1 kill"

## BOT-012 — the kinds the undercroft is made of. Named as a constant for the same
## reason the arena names its three roles: "engaged two kinds of dungeon enemy" has
## to mean two kinds that live in the dungeon, and the nearest skeleton on the screen
## is not evidence of anything unless the list it was matched against is written down
## somewhere. `ruin_skeleton` and `ruin_skeleton_archer` patrol the undercroft too,
## and they count — they are what a hero meets first on the way down.
const DUNGEON_KINDS: Array[String] = ["ruin_skeleton", "ruin_skeleton_archer",
	"ash_wisp", "bone_crawler", "plague_bearer"]
## Three zones down and back again is the longest road a scenario in this file walks:
## the forest's supply run, the ruins' door, the undercroft, the stair back and the
## gate home. The budget is a ceiling on a route that normally finishes in half of
## it, and it is a ceiling rather than a wait because the legs exit as soon as the
## world answers.
const DUNGEON_TIMEOUT := 900.0
const FORTRESS_TIMEOUT := 1200.0

## How close the bot has to stand before walking toward an exit stops being the
## job and knocking becomes it. The interact reach of a `ZoneExit` is 26 px, so
## inside this radius the walk is over by definition; a travel loop that keeps
## calling a walker which answers «already there» without spending a frame does
## not wait for the world, it freezes the engine.
const GATE_KNOCK_RANGE := 22.0
const DUNGEON_CRITERION := "reached the dungeon through the ruins' door, dealt damage to >=2 distinct dungeon kinds, met a spike trap with its telegraph visible and took no unpreventable damage from it (or said so, when this seed's undercroft has no reachable ground to watch a plate from), travelled back to the forest, survived"
const FORTRESS_CRITERION := "reached the fortress through the undercroft, engaged the King without a Crown, survived past the phase 2 transition, and either won, broke off, or died and got back up — never stalled"

var scenario: String = ""
var profile: String = "normal"
## The seed this run is reporting. `Telemetry` is the one that actually puts a seed
## on the global RNG (it does so before the world exists, which is the only moment
## early enemy rolls can be caught); the bot reads the number back so the verdict
## line carries the seed it was reached on, and so `--seed=` can be re-run verbatim.
var run_seed: int = 0
var seed_source: String = ""
var _profile: Dictionary = {}
var bot_input: BotInput
var _world: Node = null
var _result := "FAIL"
var _notes: Array[String] = []
var _running := false
var _start_ms := 0
# The `HitStop` autoload, detached for a run and re-attached on finish. See
# `_neutralize_hit_stop`.
var _hit_stop_node: Node = null
# The engine's physics-steps-per-frame ceiling, saved before a run pins it to 1
# and restored on finish. See `_pin_physics_stepping`.
var _prev_max_physics_steps := 0
var _avoid_dir := Vector2.ZERO
var _avoid_frames := 0
var _avoid_sign := 1.0
# Combat sensors for the measurement scenarios (BOT-003/004). They count only
# what the EventBus already publishes — per-target damage payloads, typed kills
# and applied statuses — so the scenario notes are read off the same events the
# telemetry combat log is built from, not from a second bookkeeping path.
var _m_dmg_by_type: Dictionary = {}
var _m_taken_by_type: Dictionary = {}
var _potions_drunk := 0
var _m_kills_by_type: Dictionary = {}
var _m_status_hits := 0
var _m_sensors_connected := false
## Trap damage bookkeeping (BOT-007): the sensor counts only hits whose
## `attacker_id` is the trap node the scenario is watching, so a wolf that
## follows the bot around the plate can never be mistaken for the trap.
var _m_trap_id := -1
var _m_trap_damage := 0
## Tiles the bot learned to avoid by bumping into them. The zone's character
## grid and the tilemap's baked collision can disagree by a sub-tile corner
## (a walkable `.` with a collision nubbin on its edge), and a bot that walks
## like a player discovers exactly that: it pushes into the invisible corner,
## gets nowhere, remembers the tile and routes around it. The dictionary maps
## `Vector2i` tile to `true` and lives for the whole run, like a player's
## memory of a bad corner.
var _bumped: Dictionary = {}

## BOT-003 bookkeeping. The arena used to be one loop over one map, so its
## counters could live in local variables; it now crosses a zone line, and a
## counter that has to survive a travel cannot live inside the loop that travels.
## The control lock is measured from `_physics_process` while `_a_watch` is up, so
## the bound covers the whole run — including the walks, where a root spell lands
## just as happily as it does in the melee.
var _a_melee := 0
## Melee swings the walker made while an arena leg was running. `_travel_to`
## clears whatever is inside the lane, and those hits are the bot's own as much
## as the ones the arena issues itself; the arena reports the two apart.
var _a_walker_melee := 0
var _a_casts := 0
var _a_heals := 0
var _a_switches := 0
var _a_last_target := -1
var _a_spell := ""
var _a_spell_cost := 0
var _a_broken := false
var _a_break_started := 0
var _a_break_cooldown_until := 0
var _a_watch := false
## Drink threshold the walker obeys on the current leg, or -1.0 for the profile's
## own. A march across a whole zone is not a duel: the profile threshold is tuned
## for a fight the bot can walk away from, while a lane entered at 35 HP into a
## shooter's clearing is a lane the bot never reaches the far end of.
var _travel_heal_at := -1.0
## Whether the walker treats a boss as a hazard to break off from rather than a
## body to walk past. Off by default so only the scenarios that opt in (BOT-005's
## crossing to the guarded chest) change behaviour; the boss-fighting scenarios
## (BOT-013) never set it and keep walking straight at their boss.
var _avoid_boss_on_travel := false
## Seconds of boss break-off this run still has to spend. Reset at the start of the
## scenario that opts in; the walker spends it, so the rule is bounded per run.
var _boss_retreat_left := 0.0
var _a_control_since := -1
var _a_max_control_ms := 0

## BOT-010's window in simulated seconds. Read from `--soak=` when the operator names
## one, so a two-minute sanity check does not have to edit a constant and a release
## gate does not have to trust a flag.
var soak_seconds := SOAK_SECONDS_DEFAULT
## Every zone this run stood in, in the order it stood there, repeated entries
## included: `forest > ruins > dungeon > ruins > forest` is the sentence the verdict
## field ZONES exists to say, and a set would lose the part that matters.
var _zone_path: Array[String] = []
## The scenario's own checklist. A goal is declared when a leg starts and confirmed
## when the world answers it, so GOALS in the summary is "3/4" rather than a PASS or
## a FAIL, and a run that got most of the way says so.
var _goals_total := 0
var _goals_done := 0

## Watchdog state. The reference position and its frame are re-armed by any
## movement greater than `WATCHDOG_STUCK_PX`, so a stuck report is an episode and not
## a per-frame scream; the token is the world's own progress (zone, kills, gold, HP,
## level, tile, quest state), and a token that has not moved is the only thing that
## makes a cycle and a zero-progress stall distinguishable from ordinary work.
var _wd_enabled := false
var _wd_goal := ""
var _wd_ref_pos := Vector2.ZERO
var _wd_ref_frame := 0
var _wd_token := ""
var _wd_token_frame := 0
var _wd_action := ""
var _wd_action_frame := 0
var _wd_repeat := 0
var _wd_sample_frame := 0
var _wd_stuck := 0
var _wd_cycles := 0
var _wd_zero_progress := 0


func _physics_process(_delta: float) -> void:
	if _a_watch:
		_track_control_lock()
	if _wd_enabled:
		_watchdog_tick()


## One sample of the watchdog. Runs every physics step for the whole of every bot
## run, because the stall it is looking for is exactly the kind that happens while
## the scenario's own coroutine is busy waiting for something else.
##
## Nothing here aborts the run. A bot that stops on an anomaly hides it: the log
## ends at the interesting part. Every detection is instead written to
## `decisions.jsonl` with the evidence a human needs to tell a wall from a fight, and
## counted into the verdict's STUCK field.
func _watchdog_tick() -> void:
	# The watchdog keeps its own clock in physics frames, not on the wall clock, so
	# the stall notes it writes are a pure function of the seed: the same launch
	# fires the same stuck / cycle / zero_progress lines at the same frames on any
	# box, loaded or idle. The ms thresholds stay the tuning surface (and the test
	# reads them back as ms) and are converted to frames here. This still never
	# bounds a scenario loop's action count and never gates the verdict — it only
	# decides what gets logged and counted in STUCK.
	var now := Engine.get_physics_frames()
	var pos := _player_pos()
	var token := _wd_progress_token()
	if token != _wd_token:
		# The world moved — a kill, a coin, a zone line, a quest step, a tile. That
		# single fact retires every stall timer at once, which is what keeps a hero
		# trading blows (HP down, position down, enemy dead) from reading as stuck.
		_wd_token = token
		_wd_token_frame = now
		_wd_ref_pos = pos
		_wd_ref_frame = now
		_wd_repeat = 0
		_wd_action = ""
	elif pos.distance_to(_wd_ref_pos) > WATCHDOG_STUCK_PX:
		_wd_ref_pos = pos
		_wd_ref_frame = now
	elif _wd_movement_held() \
			and now - _wd_ref_frame >= _frames(WATCHDOG_STUCK_MS / 1000.0):
		_wd_stuck += 1
		_report_watchdog("stuck", _ms_of_frames(now - _wd_ref_frame))
		# Re-arm from this instant: the episode is over, the next one is a fresh
		# three seconds of pressing into something. Without the re-arm a single
		# corner would write one line per frame for the rest of the run.
		_wd_ref_frame = now
	if _wd_goal != "" \
			and now - _wd_token_frame >= _frames(WATCHDOG_ZERO_PROGRESS_MS / 1000.0):
		_wd_zero_progress += 1
		_report_watchdog("zero_progress", _ms_of_frames(now - _wd_token_frame))
		_wd_token_frame = now
	if now - _wd_sample_frame >= _frames(WATCHDOG_SAMPLE_MS / 1000.0):
		_wd_sample_frame = now
		_write_observation()


## The world's own progress, as one comparable string. Deliberately coarse: the tile
## rather than the pixel, so a hero sliding along a wall (real motion, no ground
## gained) does not count as progress, while a hero walking the map does.
func _wd_progress_token() -> String:
	var kills := 0
	for killed_type: String in GameState.kills:
		kills += int(GameState.kills[killed_type])
	return "%s|%d|%d|%d|%d|%s|%s" % [
		String(GameState.zone), kills, GameState.gold, GameState.hp, GameState.level,
		str(_tile_of(_player_pos())), str(QuestManager.state_of(QUEST_ID)),
	]


## Whether any movement key is currently down. A hero who is not pressing anything
## and standing still is resting, which is a decision, not a defect.
func _wd_movement_held() -> bool:
	for action: String in ["move_up", "move_down", "move_left", "move_right"]:
		if bool(bot_input._pressed.get(action, false)):
			return true
	return false


## One key press, counted against the current goal. Twelve of the same key with no
## change in the world between them is the loop the spec's «повторение одного и того
## же (цель, действие)» describes.
func _wd_note_action(action: String) -> void:
	if not _wd_enabled:
		return
	# The cycle detector's clock is physics frames too, so a cycle note lands on the
	# same frame every run. The ms threshold is the tuning surface, converted here.
	var now := Engine.get_physics_frames()
	if action == _wd_action:
		_wd_repeat += 1
	else:
		_wd_action = action
		_wd_repeat = 1
		_wd_action_frame = now
	if _wd_repeat > WATCHDOG_CYCLE_REPEATS \
			and now - _wd_action_frame >= _frames(WATCHDOG_CYCLE_MIN_MS / 1000.0):
		_wd_cycles += 1
		_report_watchdog("cycle", _ms_of_frames(now - _wd_token_frame))
		_wd_repeat = 0
		_wd_action = ""


## The evidence line a stall has to carry: how long nothing moved, where the hero
## stood, which keys he was holding, and which tiles the zone itself calls solid
## around him. Read off the grid with the bot's own bump memory switched off, so the
## report says what the world is, not what the bot has decided to believe.
func _report_watchdog(kind: String, no_progress_ms: int) -> void:
	var pos := _player_pos()
	var held: Array[String] = []
	for action: String in ["move_up", "move_down", "move_left", "move_right",
			"attack", "interact", "ability", "dash", "block", "quick_slot_1"]:
		if bool(bot_input._pressed.get(action, false)):
			held.append(action)
	var blocked: Array[String] = []
	var here := _tile_of(pos)
	for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		if not _walkable(here + offset, true):
			blocked.append(str(here + offset))
	Telemetry.decision({
		"action": "watchdog_" + kind,
		"reason": "scenario_" + scenario,
		"goal": _wd_goal,
		"no_progress_ms": no_progress_ms,
		"at": [int(pos.x), int(pos.y)],
		"tile": str(here),
		"held": ",".join(held),
		"blocked_tiles": ",".join(blocked),
		"frame": Engine.get_physics_frames(),
	})
	# The detail travels to FIRST ANOMALY because «stuck» alone does not localise
	# anything: the tile is what tells the reader which wall to go look at, and the
	# verdict is read on its own far more often than the log is opened.
	Telemetry.note_anomaly(kind, "%s (goal %s)" % [str(here), _wd_goal])
	_notes.append("watchdog_%s no_progress_ms=%d at=%s" % [kind, no_progress_ms, str(here)])


## One second of the world, as the bot sees it. Cheap by construction: the player's
## own position and pools, the nearest body and its distance, the zone, the goal. No
## scans beyond the enemy group the walker already iterates every step anyway.
func _write_observation() -> void:
	var pos := _player_pos()
	var foe := _nearest_enemy()
	Telemetry.observation({
		"goal": _wd_goal,
		"zone": String(GameState.zone),
		"at": [int(pos.x), int(pos.y)],
		"tile": str(_tile_of(pos)),
		"hp": GameState.hp,
		"mana": GameState.mana,
		"gold": GameState.gold,
		"nearest_enemy": String(foe.get("enemy_type")) if foe != null else "",
		"nearest_dist": int(pos.distance_to(foe.global_position)) if foe != null else -1,
		"frame": Engine.get_physics_frames(),
	})


## One sample of the stun-lock clock: how long the player has been under a
## control status without a free frame in between. Read off his own
## StatusComponent's public `effects`, the same dictionary the movement multiplier
## is computed from, so a root counts exactly as much as a stun does.
func _track_control_lock() -> void:
	# The control-lock clock is physics frames too, so the max_control_ms the arena
	# verdict reports is a pure function of the seed, not of how fast the machine
	# ran the frames the hero spent stunned. Converted to ms only for the report.
	var now := Engine.get_physics_frames()
	if _player_is_controlled():
		if _a_control_since < 0:
			_a_control_since = now
		_a_max_control_ms = maxi(_a_max_control_ms, _ms_of_frames(now - _a_control_since))
	else:
		_a_control_since = -1


## Start/stop the arena's control-lock watch. The bot's physics process is off for
## every other scenario, and this is the only place that turns it on.
func _set_control_watch(on: bool) -> void:
	_a_watch = on
	_a_control_since = -1
	set_physics_process(on or _wd_enabled)


## Start/stop the watchdog. On for every bot run, not only for the scenarios that
## ask: a stall in a scenario nobody instrumented is the stall that ships.
func _set_watchdog(on: bool) -> void:
	_wd_enabled = on
	if on:
		# Seeds the watchdog's frame baselines so its first thresholds are measured
		# from the moment it is armed, on the same clock it ticks on.
		var now := Engine.get_physics_frames()
		_wd_ref_pos = _player_pos()
		_wd_ref_frame = now
		_wd_token = _wd_progress_token()
		_wd_token_frame = now
		_wd_sample_frame = now
		_wd_action = ""
		_wd_repeat = 0
	set_physics_process(on or _a_watch)


## Declare the goal the watchdog measures progress against, and the checklist entry
## the verdict counts. An empty goal switches the zero-progress detector off (a leg
## that is only about getting somewhere has no goal to stall on) while the stuck and
## cycle detectors keep running.
func _wd_set_goal(goal: String) -> void:
	_wd_goal = goal


## One term of the scenario's checklist: counted, named in the notes, and reported
## either way, because a goal that was attempted and missed is information while a
## goal nobody checked is silence.
func _goal(label: String, ok: bool) -> void:
	_goals_total += 1
	if ok:
		_goals_done += 1
		_notes.append("goal_%s=ok" % label)
	else:
		_notes.append("goal_%s=missed" % label)


func _ready() -> void:
	process_priority = -100
	set_physics_process(false)
	bot_input = BotInput.new()


func start_from_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	var requested_seed := 0
	var has_requested_seed := false
	var requested_soak := -1.0
	for a in args:
		if a.begins_with("--bot="):
			scenario = a.substr("--bot=".length())
		elif a.begins_with("--profile="):
			profile = a.substr("--profile=".length())
		elif a.begins_with("--seed="):
			requested_seed = int(a.trim_prefix("--seed="))
			has_requested_seed = true
		elif a.begins_with("--soak="):
			requested_soak = float(a.trim_prefix("--soak="))
	if scenario == "":
		return
	# A soak window has to be a window. `--soak=0` would end the scenario before it
	# swung once, and a negative one would end it before it started; both read as a
	# PASS-shaped silence, so the flag is refused back to the default it came from
	# and the refusal is said out loud in the notes.
	soak_seconds = SOAK_SECONDS_DEFAULT
	if requested_soak > 0.0:
		soak_seconds = requested_soak
	elif requested_soak >= 0.0:
		_notes.append("soak_flag_ignored=%.1f" % requested_soak)
	# `Telemetry` already seeded the global RNG before the world was built, which is
	# the only point early enemy rolls can be caught. When the operator named a
	# seed, hand it back down so the process is genuinely running on the number the
	# log will print, not merely on a number the log happens to agree with.
	if has_requested_seed:
		Telemetry.set_run_seed(requested_seed, "cmdline")
	run_seed = int(Telemetry.seed_value)
	seed_source = String(Telemetry.seed_source)
	_silence_audio_rng()
	_neutralize_hit_stop()
	_pin_physics_stepping()
	_profile = PROFILES.get(profile, PROFILES["normal"])
	_world = get_parent().get_node_or_null("World")
	_running = true
	# Run-start wall clock, kept only so a duration can be reported if ever read; it
	# is not a deadline and bounds no scenario loop.
	_start_ms = Time.get_ticks_msec()
	InputSource.set_override(bot_input)
	# The watchdog is on for every scenario, not only for the ones that ask for it.
	# The stall it exists to catch is the one a scenario walks into while its own
	# coroutine is waiting on a timer, which is precisely where a per-scenario hook
	# would never be reached.
	_set_watchdog(true)
	_wd_set_goal("scenario_" + scenario)
	_note_zone()
	Telemetry.event(&"bot_start",
		{"scenario": scenario, "profile": profile, "seed": run_seed,
			"seed_source": seed_source, "soak_seconds": soak_seconds})
	_run()


## Record the zone the hero is standing in, if it is not the last one already
## written. Read off `GameState.zone` — the world's own answer after a travel — so
## the path in the verdict is the route the game took and not the route the scenario
## meant to walk.
func _note_zone() -> void:
	var zone := String(GameState.zone)
	if zone == "" or (_zone_path.size() > 0 and _zone_path[_zone_path.size() - 1] == zone):
		return
	_zone_path.append(zone)


func _run() -> void:
	# Start the scenario on a fixed absolute physics frame, not a fixed wait from
	# `_ready`. The bot node is added when the world scene instantiates, and that
	# instantiate completes on a frame that shifts by one or two between launches
	# (the deferred scene-change handoff and the world's own `_ready` chain do not
	# always take the same number of steps). A `_wait(0.6)` from `_ready` therefore
	# began the fight on frame 43 in one launch and 44 in the next, and that single
	# frame offset moved every later input edge against the enemy AI's fixed-delta
	# clock — the same seed then resolved the first simultaneous exchange the other
	# way and forked the whole run (48 attacks vs 68, a slime that lived vs died).
	# The global RNG is provably identical at scenario start across launches, so the
	# only thing that varied was this start frame. Parking to a fixed frame removes
	# the last wall-clock coupling: the fight now begins on the same step every time.
	_park_to_frame(RUN_START_FRAME)
	match scenario:
		"BOT-001":
			await _scenario_talk()
		"BOT-003":
			await _scenario_arena()
		"BOT-004":
			await _scenario_magic()
		"BOT-005":
			await _scenario_economy()
		"BOT-006":
			await _scenario_quest_chain()
		"BOT-007":
			await _scenario_traps()
		"BOT-008":
			await _scenario_kill()
		"BOT-009":
			await _scenario_save_load()
		"BOT-002":
			await _scenario_quest_loop()
		"BOT-010":
			await _scenario_soak()
		"BOT-011":
			await _scenario_take_damage()
		"BOT-012":
			await _scenario_dungeon()
		"BOT-013":
			await _scenario_fortress()
		_:
			_notes.append("unknown_scenario")
			_result = "FAIL"
	_finish()


func _finish() -> void:
	_set_watchdog(false)
	# Hand the engine's physics ceiling back before anything else: an in-process
	# bot test keeps running the suite after this scenario, and a leaked pin of 1
	# would slow every later group without changing its result.
	if _prev_max_physics_steps > 0:
		Engine.set("max_physics_steps_per_frame", _prev_max_physics_steps)
		_prev_max_physics_steps = 0
	# Re-attach hit-stop and make sure the scale is whole before handing the tree
	# back, so neither a detached autoload nor a leftover slow-motion scale leaks
	# into the next in-process scenario or the shutdown.
	if _hit_stop_node != null and is_instance_valid(_hit_stop_node):
		get_tree().root.add_child(_hit_stop_node)
	_hit_stop_node = null
	Engine.time_scale = 1.0
	InputSource.clear_override()
	_disconnect_combat_sensors()
	bot_input.release_all()
	# Un-park the audio pools for the same reason the physics ceiling and hit-stop
	# are handed back above: a standalone run quits a moment later and never notices,
	# but a bot that ever runs inside a live process must not leave the manager
	# parked, or the next scene to ask for music gets silence and a pool that was
	# emptied out from under it.
	var audio := get_tree().root.get_node_or_null("AudioManager")
	if audio != null and audio.has_method("unpark_for_bot"):
		audio.call("unpark_for_bot")
	var ok := _result == "PASS"
	Telemetry.event(&"bot_finish",
		{"scenario": scenario, "result": _result, "notes": _notes, "seed": run_seed})
	Telemetry.write_summary(_result, {
		"scenario": scenario,
		"profile": profile,
		"seed": run_seed,
		"seed_source": seed_source,
		"rerun": "godot --headless --path . -- --bot=%s --profile=%s --seed=%d"
			% [scenario, profile, run_seed],
		"notes": "; ".join(_notes),
		"hp": GameState.hp,
		"kills": GameState.kills,
		# The §20.5 verdict fields the bot owns. DEATHS, STUCK, WARNINGS, ERRORS and
		# FATAL are read from Telemetry's own counters by the builder, because a run
		# that died twice and a run that never died must not differ only in whether
		# the bot felt like mentioning it.
		"zones": " > ".join(_zone_path) if not _zone_path.is_empty() else "-",
		"goals": "%d/%d" % [_goals_done, _goals_total],
		"run_dir": String(Telemetry.run_dir),
	})
	# The seed rides on the verdict line rather than only in the log directory: the
	# line is what a human pastes into a report, and a PASS with no seed next to it
	# is a claim nobody can re-check tomorrow.
	print("[bot] %s -> %s (seed=%d %s; %s)"
		% [scenario, _result, run_seed, seed_source, "; ".join(_notes)])
	_running = false
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)


# --- scenarios ---------------------------------------------------------------

func _scenario_talk() -> void:
	# Edrik moved out of the forest when the village became its own zone, so the
	# first interactable of the forest is no longer the headman — it is the east
	# chest, and a key press on it pays a sword, not a quest. The talk bot now
	# walks the real road first: through `VillageGate` into the village, where
	# Edrik is again the first interactable, and only then asks.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_unreachable")
		return
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	var reached := await _move_to(npc.global_position, 18.0, 30.0)
	_notes.append("reached_npc" if reached else "npc_unreachable")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var state: String = QuestManager.state_of(QUEST_ID)
	_notes.append("quest_state=" + state)
	_result = "PASS" if state == QuestManager.STATE_ACTIVE else "FAIL"


## Parks the audio layer for the duration of a bot run.
##
## `AudioManager.play_sfx` rolls a random pitch for every sound effect off the same
## global RNG the simulation rolls crits, enemy wander and loot on. Which sounds are
## still audible when the next one is requested is a function of wall-clock audio
## progress, not of the simulation, so with the pool live the number of pitch rolls
## a run makes is not fixed by the seed — and every gameplay roll after it lands on
## a different position in the stream. Two runs on one seed then diverge in the
## world, not in the log, and the recorded seed stops being enough to re-create the
## run. And `play_sfx` loads the `.wav` through `_stream` before it ever looks at
## the pool, so even a pitch-less call cold-loads a file on first use: on the very
## first process that file is read off a cold disk, that read stalls a physics
## frame, the engine runs catch-up steps, and the render-delta status clock
## desynchronises from the fixed-delta world — so the first run of a seed is not the
## same run as the warm ones. A bot checks state, never sound, so the whole playback
## layer is parked for the run: `park_for_bot` stops and releases every live voice
## (the zone's music bed is already playing before the bot starts, and releasing it
## is also what keeps the process exit free of leaked audio objects), raises the
## parked flag so no entry point loads a stream or rolls a pitch, and empties the
## pools. The shipped game is untouched because this only ever runs under `--bot=`.
func _silence_audio_rng() -> void:
	var audio := get_tree().root.get_node_or_null("AudioManager")
	if audio == null or not audio.has_method("park_for_bot"):
		return
	audio.call("park_for_bot")
	_notes.append("audio_pool_parked")


## Take the process-wide hit-stop out of the tree for the run.
##
## Hit-stop is the one place where the render loop reaches into the fixed-delta
## simulation: every landed melee hit sets `Engine.time_scale = 0.12`, and the
## stop is counted down in `_process` off the render delta. Because `time_scale`
## scales the physics tick too, the number of physics steps that run at reduced
## speed inside a stop window is a function of how many rendered frames fit in
## that window — i.e. of wall-clock, not of the seed. A cold disk read on the
## first hit stretches one window, the player's attack cooldown advances by a
## different amount, and the same seed lands a different number of attacks and a
## different kill tally: the first launch after an idle gap stops matching the
## warm ones, which is exactly what a recorded seed is meant to prevent.
##
## A bot reads state, never the slow-motion flourish, so the autoload is removed
## for the run. `Player._hit_stop_autoload` resolves it with
## `root.get_node_or_null("HitStop")` and no-ops when it is absent, so removing
## the node switches hit-stop off cleanly with no script errors and without
## touching the player or the autoload. `_finish` puts it back for an in-process
## test that keeps running after the scenario.
func _neutralize_hit_stop() -> void:
	var hit_stop := get_tree().root.get_node_or_null("HitStop")
	if hit_stop == null:
		return
	_hit_stop_node = hit_stop
	get_tree().root.remove_child(hit_stop)
	Engine.time_scale = 1.0


## Pin the engine to one physics step per main-loop iteration for the run.
##
## The bot drives the world by holding an action for a couple of `physics_frame`
## awaits, and the player reads that action with `is_action_just_pressed`, which
## is true for only the first physics step after a press. The engine's default
## ceiling of eight physics steps per frame breaks the one-press-one-step link the
## moment a frame stalls: a cold disk read (a texture or `.tres` first touched on
## the first hit, before the OS page cache is warm) blocks the main thread, and on
## the next iteration the engine runs a catch-up burst of several fixed-delta steps
## inside that one iteration. The held press is consumed as "just pressed" on the
## first step of the burst and is no longer fresh on the rest, and the bot's
## `physics_frame` awaits are rescheduled once per iteration rather than once per
## step, so the same tap lands on a different physics step and the attack cadence
## shifts. Whether a burst happens at all depends on wall-clock stalls, so the run
## is no longer a function of the seed: the same launch replays as 29 attacks or 35
## depending on nothing the seed records, which defeats the whole point of pinning
## one.
##
## One step per frame restores the link: every iteration advances exactly one
## fixed-delta step, so a held press is fresh for exactly the steps the bot intends
## and each `physics_frame` await catches exactly one step. A stall now only costs
## wall-clock, never simulation state, and the run replays identically cold or warm.
## The shipped game is untouched — this runs only under `--bot=`, and `_finish`
## restores the saved ceiling.
func _pin_physics_stepping() -> void:
	_prev_max_physics_steps = int(Engine.get("max_physics_steps_per_frame"))
	Engine.set("max_physics_steps_per_frame", 1)


func _scenario_kill() -> void:
	# A collector walks the nearest find before it hunts: the bag gets filled
	# first and the fight is entered with the potion already banked. Every other
	# profile leaves this branch untouched (the key defaults to false).
	if bool(_pf("pickup_bias", false)):
		var loot := _nearest_pickup()
		if loot != null:
			await _move_to(loot.global_position, 10.0, 20.0)
	# The budget is counted in physics frames, not on the wall clock. A wall-clock
	# deadline makes the number of attacks this scenario lands a function of how
	# busy the machine was, so two launches on the same seed printed different
	# `attacks=` and different kill tallies — and a run whose numbers move under a
	# fixed seed cannot be re-checked, which is the only reason to record one.
	# Physics steps carry a fixed delta, so a frame budget makes the whole scenario
	# a pure function of the seed while keeping the same nominal 75 s at 60 Hz.
	var frame_budget := Engine.get_physics_frames() + int(SCENARIO_TIMEOUT * 60.0)
	var attacks := 0
	while Engine.get_physics_frames() < frame_budget:
		if GameState.hp < GameState.max_hp * float(_profile["heal_at"]):
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		var enemy := _nearest_enemy()
		if enemy == null:
			break
		var dist := _player_pos().distance_to(enemy.global_position)
		# A master breaks off while trading blows below this share of HP instead
		# of healing into the enemy's reach; 0.0 (every other profile) never runs
		# the branch, so their fights are the fights they always fought.
		var retreat_below := float(_pf("retreat_below", 0.0))
		if retreat_below > 0.0 and GameState.hp < int(GameState.max_hp * retreat_below) \
				and dist < 26.0:
			await _retreat_burst(enemy.global_position, 0.5)
			continue
		if dist > float(_profile["engage_range"]):
			if bool(_pf("use_ability", false)) and dist < 150.0 and _mana_ready():
				bot_input.set_aim(enemy.global_position)
				await _tap(&"ability")
			await _move_step(enemy.global_position)
			continue
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.25)
		var rd := float(_pf("reaction_delay", 0.0))
		if rd > 0.0:
			await _wait(rd)
	_notes.append("attacks=%d" % attacks)
	_notes.append("kills=%s" % str(GameState.kills))
	_result = "PASS" if GameState.kill_count("ash_wolf") > 0 else "FAIL"


func _scenario_save_load() -> void:
	var before_hp := GameState.hp
	var before_gold := GameState.gold
	GameState.add_gold(7)
	var save := SaveManager.save_game(3)
	if not bool(save.get("ok", false)):
		_notes.append("save_failed:" + String(save.get("error", "")))
		_clear_save_slot(3)
		return
	_notes.append("saved")
	GameState.add_gold(100)
	GameState.take_damage(25)
	var load := SaveManager.load_game(3)
	# Slot 3 belongs to this scenario. Drop the save and the backup the rewrite
	# produced: a leftover backup turns a later corrupt-primary check into a
	# successful recovery, so a bot run must never leave slot 3 populated.
	_clear_save_slot(3)
	if not bool(load.get("ok", false)):
		_notes.append("load_failed:" + String(load.get("error", "")))
		return
	var ok := GameState.gold == before_gold + 7 and GameState.hp == before_hp
	_notes.append("gold=%d hp=%d" % [GameState.gold, GameState.hp])
	_result = "PASS" if ok else "FAIL"


func _scenario_quest_loop() -> void:
	# 1. travel to the village and take the quest from the NPC. The headman
	# moved out of the forest when the village became its own zone, so the
	# first interactable here is the east chest and a bot pressing E on it gets
	# a sword instead of a job. The wolves the job asks for still live out in
	# the wild, so the loop is a round trip: gate west for the order, gate east
	# for the hunt, gate west for the gold.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_unreachable")
		return
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	if not await _move_to(npc.global_position, 18.0, 45.0):
		_notes.append("npc_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_ACTIVE:
		_notes.append("quest_not_started")
		return
	_notes.append("quest_taken")

	# 2. hunt until the objective is met — out in the forest, because the walled
	# village holds no wolves and an objective worked where the objective does
	# not live is no objective at all.
	if not await _goto_zone("forest", SCENARIO_TIMEOUT):
		_notes.append("forest_unreachable")
		return
	#
	# The budget is counted in physics frames rather than on the wall clock. A
	# wall-clock deadline makes the number of hunting iterations this run gets a
	# function of how loaded the machine was while it ran, so two launches on the
	# same seed ended with different kill counts and a PASS that could not be
	# reproduced — which is the whole point of recording a seed. Physics advances a
	# fixed delta per tick, so a frame budget makes the run a pure function of the
	# seed: same seed, same fight, same numbers, on any machine. The nominal wall
	# time at 60 Hz is unchanged.
	var frame_budget := Engine.get_physics_frames() + int(SCENARIO_TIMEOUT * 2.2 * 60.0)
	var attacks := 0
	# The bot's straight-line approach cannot always get around a tree that sits
	# between it and the nearest wolf, so it can pin itself against the obstacle
	# and grind for the whole budget without ever closing to attack range. When it
	# stops making progress on a target it abandons that wolf (for a while) and
	# works another one instead — there are more wolves than the objective needs.
	# This is target selection only: movement, aiming, attacking and healing are
	# untouched, and every kill is still earned by walking up and attacking.
	var abandoned: Dictionary = {}
	var cur_id := -1
	var cur_best := INF
	var stalled := 0
	while Engine.get_physics_frames() < frame_budget:
		if QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY:
			break
		if GameState.hp < GameState.max_hp * float(_profile["heal_at"]):
			await _tap(&"quick_slot_1")
			await _wait(0.2)
		_prune_abandoned(abandoned)
		var enemy := _nearest_quest_enemy(QUEST_ID, abandoned)
		if enemy == null:
			# Nothing left that we have not just abandoned: forget the
			# abandonments and retry once before declaring the objective impossible.
			if not abandoned.is_empty():
				abandoned.clear()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			# Honest failure: the objective still needs kills but no matching
			# enemy is left to fight, so report why instead of silently breaking
			# into a vague objective_not_met.
			if QuestManager.progress_of(QUEST_ID) < QuestManager.target_count(QUEST_ID):
				_notes.append("progress=%d/%d" % [QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
				_notes.append("no_quest_targets")
			return
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > float(_profile["engage_range"]):
			var eid := enemy.get_instance_id()
			if eid != cur_id:
				cur_id = eid
				cur_best = dist
				stalled = 0
			elif dist < cur_best - 2.0:
				cur_best = dist
				stalled = 0
			else:
				stalled += 1
			if stalled > 120:
				abandoned[eid] = Engine.get_physics_frames()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			# A profile that fights with the ability (master) softens the quest
			# target on the approach. The cast goes through the same `ability`
			# action the human right mouse uses; profiles without the key never
			# enter this branch and hunt exactly as they hunted before.
			if bool(_pf("use_ability", false)) and dist < 150.0 and _mana_ready():
				bot_input.set_aim(enemy.global_position)
				await _tap(&"ability")
			await _move_step(enemy.global_position)
			continue
		cur_id = -1
		cur_best = INF
		stalled = 0
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.22)
		var rd := float(_pf("reaction_delay", 0.0))
		if rd > 0.0:
			await _wait(rd)
	_notes.append("attacks=%d" % attacks)
	_notes.append("progress=%d/%d" % [QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_READY:
		_notes.append("objective_not_met")
		return

	# 3. walk back to the village and turn it in. The `npc` reference died with
	# the world it stood in the moment the hero crossed a gate, so the headman
	# is looked up again on his own side of the door rather than walked to by
	# the memory of a node that no longer exists.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_return_unreachable")
		return
	npc = _find_node("interactable")
	if npc == null:
		_notes.append("no_npc_on_return")
		return
	var gold_before: int = GameState.gold
	if not await _move_to(npc.global_position, 18.0, 60.0):
		_notes.append("return_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var done := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	_notes.append("state=%s" % QuestManager.state_of(QUEST_ID))
	_notes.append("gold=%d->%d" % [gold_before, GameState.gold])
	_result = "PASS" if done and GameState.gold > gold_before else "FAIL"


func _scenario_soak() -> void:
	var rng := RandomNumberGenerator.new()
	# Derived from the run seed rather than a constant of its own: a soak that mixes
	# its own private fixed number into a run whose seed is reported elsewhere is a
	# soak whose wander cannot be reproduced by re-running the seed it printed.
	rng.seed = run_seed
	# The window is counted in physics steps, not in wall milliseconds. A soak bounded
	# by the wall clock runs a different number of simulation steps on a busy machine
	# than on an idle one, which makes the run it reports a function of load and not
	# of the seed printed next to the verdict — the same coupling that made the kill
	# scenario diverge, and the reason `BOT-008` counts frames too.
	var frame_budget := Engine.get_physics_frames() + int(soak_seconds * 60.0)
	var heading := Vector2.RIGHT
	var segments := 0
	var last_pos := _player_pos()
	var stuck := 0
	var travelled := 0.0
	var teleports := 0
	var attack_attempts := 0
	var heals := 0
	var impulse_heals := 0
	var retreats := 0
	# The disengage budget scales with the window, because a budget sized for 75 s of
	# wandering buys the same safety eight times over and then runs out with nine
	# tenths of the run still to go. The constant the test suite pins stays what it
	# is; only its share of a longer run grows.
	var retreat_left := SOAK_RETREAT_BUDGET \
		* clampf(soak_seconds / SOAK_BUDGET_REFERENCE_SECONDS, 1.0, 8.0)
	# The ground the run has to cover, for the same reason: 300 px proved a hero was
	# walking during a 75 s window, and the same 300 px over ten minutes would prove
	# he stood still for nine of them. Capped rather than proportional, because the
	# forest is 52x32 tiles and a wander that crossed it four times over is a
	# different scenario, not a longer one.
	var travel_goal := 300.0 * clampf(soak_seconds / SOAK_BUDGET_REFERENCE_SECONDS, 1.0, 4.0)
	# Instance id of the enemy the bot has broken off from, or -1. Tracked by id so
	# the bot stops running from a corpse the moment that enemy dies.
	var fled_id := -1
	# Bank the map's only potion before the wandering starts. The forest carries a
	# single health_potion about 145 px east of the spawn, and a random walk almost
	# never crosses its tile again: measured runs asked for a heal dozens of times and
	# held a potion in none of them, so the raised threshold had nothing to fire on.
	# Walking there is real movement through the real input path, and the pickup is
	# taken by touching it, exactly as a player takes it.
	#
	# The forest does hold a second flask, at (20,30) behind the south rubble, and
	# fetching it was tried and measured: the only lane to that nook runs the hero
	# down through the tick pack at (12..18, 26) and past the spider at (13,25) at
	# the one moment in the run when he has no levels to absorb it. The first death
	# of the measured run landed at (18,28), two tiles from TickC, on the way to a
	# 40 HP flask that cost more than 40 HP to collect. A hero walks to the potion
	# that is on his road, not the one that is behind the wolves.
	var pickup := _find_node("pickup")
	if pickup != null:
		await _move_to(pickup.global_position, 10.0, 12.0)
	_notes.append("window=%.0fs goal_travel=%.0fpx" % [soak_seconds, travel_goal])
	_notes.append("potion_banked=%s" % str(_soak_has_potion()))
	while Engine.get_physics_frames() < frame_budget:
		# Heal the instant the threshold is crossed, ahead of the attack. Tapping
		# the potion after the swing spends two physics frames trading blows, and
		# that is exactly the window a 13-damage boar charge gets paid for out of
		# the HP the potion was supposed to cover.
		if _soak_needs_heal() and _soak_has_potion():
			await _tap(&"quick_slot_1")
			heals += 1
		elif _soak_needs_heal() and not _soak_has_potion():
			# Out of medicine on a run that is eight times longer than the map's
			# one potion can cover. The impulse is the second heal every hero learns
			# in the first minute, cast through the same select-and-tap path as any
			# other spell, and it is what a ten minute soak actually survives on: the
			# forest holds one flask and 60 mana, and both are spent by the third
			# minute of it.
			if await _heal_if_hurt(SOAK_HEAL_AT):
				impulse_heals += 1

		var enemy := _nearest_enemy()
		var enemy_dist := INF if enemy == null else _player_pos().distance_to(enemy.global_position)

		# The enemy this bot is avoiding, if it is still on the map.
		var threat: Node2D = null
		if fled_id != -1:
			threat = instance_from_id(fled_id) as Node2D
			if threat == null or not is_instance_valid(threat):
				threat = null
				fled_id = -1
		# Falling below the threshold with something already in reach makes that
		# something the fight to break off, whether or not one was picked before.
		if threat == null and _soak_needs_heal() and enemy != null and enemy_dist < SOAK_MELEE_RANGE:
			fled_id = enemy.get_instance_id()
			threat = enemy

		if threat != null and _soak_needs_heal():
			# Bounded disengage: one capped burst to break contact. The player
			# outpaces every melee enemy here, so 0.6 s of walking away is real
			# safety bought with no teleport and no invulnerability.
			if _player_pos().distance_to(threat.global_position) < SOAK_MELEE_RANGE and retreat_left > 0.0:
				retreat_left -= await _soak_retreat(threat.global_position, retreat_left)
				retreats += 1
				# The burst awaited several frames and the bot has usually just swung
				# at this enemy, so it may have died in the meantime. Re-resolve the
				# id before touching it again: reading a freed instance aborts the
				# scenario, and the run lands in `_finish` as a FAIL with no notes.
				threat = instance_from_id(fled_id) as Node2D
				if threat == null or not is_instance_valid(threat):
					threat = null
					fled_id = -1
				if _soak_needs_heal() and _soak_has_potion():
					await _tap(&"quick_slot_1")
					heals += 1
			# Keep pointing the wander heading away until the threat is well outside
			# its reach, not merely past the burst trigger radius. Stopping at 25 px
			# means the bot quits running, the enemy walks back into reach, and the
			# disengage bought nothing. Steering is free, so surviving does not run
			# out of budget the way the bursts do.
			if threat != null and _player_pos().distance_to(threat.global_position) < SOAK_DISENGAGE_RANGE:
				heading = (_player_pos() - threat.global_position).normalized()
				stuck = 0

		# A boss is terrain the hero walks around, not prey he swings at. Neither
		# of the forest's two stays in its authored clearing — the Root Mother came
		# out to (17,21) to meet him and killed him there — so no patrol line can be
		# drawn round them and only a steer keeps the run off them. The clearance is
		# the boss's own, read in `_soak_boss_clearance`, because standing just
		# outside a too-small ring is worse than standing inside a big one. And this
		# costs no budget at all, so unlike the retreat bursts it cannot run dry with
		# half the window still to go.
		var boss := _nearest_boss()
		if boss != null \
				and _player_pos().distance_to(boss.global_position) < _soak_boss_clearance(boss):
			heading = (_player_pos() - boss.global_position).normalized()
			stuck = 0

		bot_input.hold(&"move_right", heading.x > 0.35)
		bot_input.hold(&"move_left", heading.x < -0.35)
		bot_input.hold(&"move_down", heading.y > 0.35)
		bot_input.hold(&"move_up", heading.y < -0.35)
		bot_input.set_aim(_player_pos() + heading * 20.0)

		# Fight, unless the nearest thing in reach is the enemy this bot has broken
		# away from and is still too hurt to trade with, or is a boss. Any other
		# hostile that wanders into reach is still fair game, which is what keeps the
		# run swinging instead of turning it into a permanent flee — and what keeps
		# it killing, since a level is the only thing in this game that refills the
		# pools a long window has already drunk dry.
		var prey := _soak_nearest_prey()
		var prey_dist := INF if prey == null else _player_pos().distance_to(prey.global_position)
		if prey != null and prey_dist < 22.0 and not _soak_holds_off(prey, fled_id):
			await _tap(&"attack")
			attack_attempts += 1

		await _wait(0.12)

		var pos := _player_pos()
		var step := pos.distance_to(last_pos)
		# A step bigger than anything the hero can cover between two samples is not
		# walking: it is the respawn putting him back on the zone's spawn point after a
		# death. Counting it would let a run that died nine times report nine hundred
		# pixels of ground it never crossed, which is exactly the sort of number the
		# movement term exists to refuse.
		if step <= SOAK_TELEPORT_PX:
			travelled += step
		else:
			teleports += 1
			# Re-anchor on the arrival point, or the next sample measures the same
			# jump a second time and one death is reported as two.
			last_pos = pos
		if step < 0.4:
			stuck += 1
		else:
			stuck = 0
			last_pos = pos

		# Turn on a wall or after a while, so the run covers the whole map.
		if stuck >= 6 or rng.randf() < 0.04:
			var angles := [0.0, PI * 0.5, PI, PI * 1.5, PI * 0.25, PI * 0.75, PI * 1.25, PI * 1.75]
			var a: float = angles[rng.randi_range(0, angles.size() - 1)]
			heading = Vector2(cos(a), sin(a)).normalized()
			segments += 1
			stuck = 0

	bot_input.release_all()
	_notes.append("segments=%d" % segments)
	_notes.append("travelled=%.0fpx" % travelled)
	_notes.append("respawn_jumps=%d" % teleports)
	_notes.append("attacks=%d" % attack_attempts)
	_notes.append("heal_taps=%d" % heals)
	_notes.append("impulse_heals=%d" % impulse_heals)
	_notes.append("retreats=%d" % retreats)
	_notes.append("deaths=%d" % int(Telemetry.death_count))
	_notes.append("hp=%d/%d" % [GameState.hp, GameState.max_hp])
	_notes.append("kills=%s" % str(GameState.kills))

	# A soak run proves the game keeps running, not that the bot got lucky.
	# Passing here means: the player survived, actually moved around the map,
	# actually swung at things, and the state stayed coherent for the whole
	# window. The attack check is what stops the disengage rule above from being
	# quietly traded for a run that walks away from everything and survives by
	# never being hit.
	#
	# Dying inside a soak is reported, not hidden: `deaths` counts every fall the
	# world saw. A fall is content — the forest has boars in it on purpose — and the
	# hero gets back up, so the verdict asks whether the run was still standing when
	# the window closed and lets the number of falls be read next to it.
	var survived: bool = GameState.hp > 0 and GameState.hp <= GameState.max_hp
	var moved_enough: bool = travelled > travel_goal
	var fought: bool = attack_attempts > 0
	var state_coherent: bool = GameState.gold >= 0 and GameState.level >= 1
	_goal("survived", survived)
	_goal("moved", moved_enough)
	_goal("fought", fought)
	_goal("state_coherent", state_coherent)
	# A stall found here is reported through STUCK in the verdict and is not a term
	# of this verdict on its own. The soak wanders into corners on purpose — that is
	# what it is for — and a detector that also decided the pass mark would be a
	# detector nobody could tell a defect apart from a design.
	_result = "PASS" if survived and moved_enough and fought and state_coherent else "FAIL"


## The single place the soak heal threshold is evaluated, so the scenario and the
## test suite cannot drift apart over a duplicated literal.
func _soak_needs_heal() -> bool:
	return GameState.hp < GameState.max_hp * SOAK_HEAL_AT


## Whether the soak hero refuses to open a swing at `enemy` this iteration.
##
## Two refusals, and neither of them is a mercy. A boss is never prey: the forest
## posts a 180 HP Warden and a 260 HP Root Mother, and a hero with a 112 HP bar who
## swings at either is not fighting, he is donating — those two and the spiders the
## one summons drank 545 of this run's 1108 damage before the steer below was
## added, and a boss stood on the tile of three of its six deaths. The second
## refusal is the one the scenario has always had: while he is hurt he does not
## re-open the fight he just broke off from, or the disengage bought nothing.
##
## What deliberately is NOT here is any rule about running out of medicine. The
## obvious policy — stop swinging once the flasks and the mana are gone and save
## the HP — was tried and measured, and it is worse: this game has no regen, mana
## comes back on a level and on nothing else, so a hero who will not kill is a hero
## who will not level, and the run then stands still while three 3-damage ticks
## charge themselves out of its bar. Measured, that rule alone put 242 of a 453
## damage run into `tick` and cost three deaths in two minutes. Killing is the
## heal in this game; the bot is not allowed to refuse the medicine it is made of.
func _soak_holds_off(enemy: Node2D, fled_id: int) -> bool:
	if enemy.is_in_group("boss"):
		return true
	return _soak_needs_heal() and enemy.get_instance_id() == fled_id


## The radius the soak hero keeps off a particular boss: the wider of the flat
## floor and the boss's own ranged gate plus a margin. The floor alone was tried
## at seven tiles and it made things worse, not better — the Root Mother drops a
## spider into the ground every 4 s at anything inside her 220 px `summon_radius`,
## so a hero circling at 112 px sits outside his own safety line and inside her
## spawning one. Measured, that turned `spider` into the single biggest source of
## damage in the run — 420 of 879 — with twelve spider kills against the two the
## forest actually posts. The gate is read off the live boss rather than copied
## here, so a boss whose number moves moves the hero's clearance with it.
func _soak_boss_clearance(boss: Node2D) -> float:
	var raw: Variant = boss.get("summon_radius")
	var gate := float(raw) if raw != null else 0.0
	return maxf(SOAK_BOSS_AVOID_RANGE, gate + SOAK_BOSS_AVOID_MARGIN)


## The nearest thing the soak hero is willing to fight: a live enemy that is not a
## boss. `_nearest_enemy` is left exactly as every other scenario has always used
## it; this is the soak's own prey picker, so a boss drifting past a wolf cannot
## leave the run with nothing to swing at and quietly turn the endurance test into
## a walk that never fights. The boss itself is read by `_nearest_boss`, the same
## picker the walker already breaks contact with.
func _soak_nearest_prey() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("enemy"):
		var e := n as Node2D
		if e == null or not is_instance_valid(e) or e.is_in_group("boss"):
			continue
		var d := me.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Whether the item the first quick slot points at is actually in the bag, which
## is exactly the pair of checks the HUD makes before it heals anything. The map
## carries a single potion, so without this the bot spends its whole low-HP phase
## hammering an empty slot: three physics frames per loop, standing in melee, for
## the rest of the run. The tap itself is unchanged — a real potion still goes
## through the real quick-slot input path.
func _soak_has_potion() -> bool:
	var item_id := String(GameState.quick_slot_item(0))
	return item_id != "" and GameState.count_item(item_id) > 0


## Walk directly away from `threat` for at most `SOAK_RETREAT_TIME` seconds, or
## for whatever is left of `budget`, and report the seconds actually spent.
##
## Real movement through the same input path the human uses: no teleport, no
## invulnerability, and a wall or a corner cuts the burst short on its own. An
## exhausted budget returns immediately without moving, which is what hands
## control back to the attack loop instead of letting the bot stall out the run.
func _soak_retreat(threat: Vector2, budget: float) -> float:
	var away := _player_pos() - threat
	away = away.normalized() if away != Vector2.ZERO else Vector2.UP
	var cap_frames := _frames(minf(SOAK_RETREAT_TIME, maxf(budget, 0.0)))
	var started := Engine.get_physics_frames()
	while Engine.get_physics_frames() - started < cap_frames:
		bot_input.hold(&"move_right", away.x > 0.35)
		bot_input.hold(&"move_left", away.x < -0.35)
		bot_input.hold(&"move_down", away.y > 0.35)
		bot_input.hold(&"move_up", away.y < -0.35)
		# Keep facing the threat so the first swing after the burst is aimed.
		bot_input.set_aim(threat)
		await get_tree().physics_frame
	bot_input.release_all()
	return float(Engine.get_physics_frames() - started) / 60.0


func _scenario_take_damage() -> void:
	# Deliberately walk into a wolf and never attack: the enemy must be able to
	# hurt the player, and the damage must be visible in the combat log.
	var start_hp: int = GameState.hp
	var deadline := Engine.get_physics_frames() + _frames(SCENARIO_TIMEOUT)
	var enemy := _nearest_enemy()
	if enemy == null:
		_notes.append("no_enemy")
		return
	while Engine.get_physics_frames() < deadline:
		if GameState.hp < start_hp:
			break
		enemy = _nearest_enemy()
		if enemy == null:
			break
		await _move_step(enemy.global_position)
		await _wait(0.05)
	bot_input.release_all()
	_notes.append("hp=%d->%d" % [start_hp, GameState.hp])
	_result = "PASS" if GameState.hp < start_hp else "FAIL"


# --- extended scenarios (spec §19.5) -------------------------------------------

## BOT-003 — combat arena. The spec asks for «столкнуться с группой из ближнего,
## дальнего и поддерживающего врага» and for proof that the hero can dodge and
## change target rather than be stun-locked. The old version of this scenario
## could not have shown any of it: it fought whatever was nearest in the forest,
## and the forest has no support enemy at all — the only healing aura in the game
## belongs to `cultist_caster`, which lives in the ruins hall behind a locked
## door. A scenario that passes without meeting a healer is not testing the
## healer, so the arena now goes and meets all three roles:
##
##   1. the forest\'s own melee, which the march east walks past on the way out;
##   2. the forest\'s own ranged, `ArcherA`, on the clearing the same road ends at;
##   3. the forest gate two posts past him, the ruins key, the wall lever that
##      spends it, and the cultist caster behind the door it raises.
##
## Every leg is walked with the real movement actions and every door is opened
## with the real interact key: the bot writes no zone, no flag and no position,
## and travel only happens because `ZoneExit.interact` is what the player\'s E key
## calls. The proof is the damage sensor: `EventBus.damage_dealt` has to record
## the arena\'s own hits on at least one kind from each role, which cannot be
## faked by standing next to something or by being shot at.
##
## The control-lock bound is the spec\'s 1.5 s and is sampled every physics frame
## of the whole run, not only while the bot is swinging.
func _scenario_arena() -> void:
	_connect_combat_sensors()
	_set_control_watch(true)
	_a_melee = 0
	_a_walker_melee = 0
	_a_casts = 0
	_a_heals = 0
	_a_switches = 0
	_a_last_target = -1
	_a_broken = false
	_a_pick_spell()
	var deadline := Engine.get_physics_frames() + _frames(ARENA_TIMEOUT)
	var forest_rally := _player_spawn()

	# Leg 0 — supply. This is a two-zone march now, and the ruins hold no finds at
	# all, so the bot sets out the way a hero sets out: with the potion lying nine
	# tiles behind him already in the bag, and the next ones paid for in wolves'
	# teeth at the merchant two tiles from the spawn. The run that died in the
	# west passage of the ruins had one heal in it and nothing left to spend.
	await _arena_prep(deadline)

	# Leg 1 — the forest\'s own two kinds, on the one road that runs east. The wolf
	# posts sit along it and the archer\'s clearing is at its end, so a single march
	# meets the melee and the ranged without a detour, and leaves the bot standing
	# where the gate is.
	# Leg 1a — the forest's melee, on the spawn's own quarter, where a hurt bot
	# can still walk home. This is also where the arena earns its own swings and
	# its own target switches instead of leaving both to the walker.
	await _arena_pin_kind(ARENA_MELEE_KINDS, 30.0, deadline, forest_rally)
	# The melee leg fights the wolves whether or not the order was ever taken, so
	# it is the second chance to close it. A hero who has already killed three of
	# them walks back to the village head, takes his gold and his two potions, and
	# only then goes east — the alternative is a march into a second zone paid for
	# with nothing but the starting potion, which is how several of these runs
	# ended up dying in the hall behind the door.
	var village_head := _find_node("interactable")
	if village_head != null and QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY \
			and _player_pos().distance_to(village_head.global_position) < 420.0:
		await _travel_to(village_head.global_position, 18.0, 45.0)
		await _tap(&"interact")
		await _wait(0.5)
		await _dismiss_dialogue()
		_notes.append("quest_closed_after_melee")

	# Leg 1b — march east. The leg is walked with no role to chase on purpose: a
	# hunt leash on a march turns a 45-tile road into a tour of every bush between
	# here and the sea, and the run that did that ended up south of the map
	# trading blows with a wisp instead of standing at the gate.
	var archer := _named("ArcherA")
	if archer != null:
		await _arena_fight_toward(NO_ROLES, archer.global_position, 34.0,
				deadline, forest_rally)
	# The archer kites by design (he backs off to keep bowshot), so the arena stays
	# on him until the sensor has its own hit down on the archer\'s kind rather than
	# until the bot happens to stop next to him.
	# The budget is the widest of the three forest legs on purpose. A shooter is
	# the only kind here that answers without coming to the bot, and the one term
	# this scenario has ever lost at is the ranged one: a run that spends its
	# budget trading chips with something it never once hit comes back claiming a
	# role it did not earn, so the leg is given the time to actually land one.
	await _arena_pin_kind(ARENA_RANGED_KINDS, 45.0, deadline, forest_rally)

	# Leg 1c — the chest on the same clearing, and the sword out of it. A level
	# one hero carrying a five damage fist walks into a two-zone war and comes
	# back dead, which is what several of the first runs of this scenario did:
	# every kill was paid for in HP at half the speed it needed to be, and there
	# is no healing anywhere past the door.
	await _arena_arm(deadline, forest_rally)

	# Leg 2 — through the gate. The bot asks the exit to travel exactly the way the
	# interact key does and then waits for the zone to actually answer `ruins`.
	var in_ruins := await _arena_enter_ruins(deadline)

	# Leg 3 — the healer behind the door: the key on the floor, the lever that
	# spends it, then the cultist the door was keeping out of reach.
	var hall_rally := _player_spawn()
	if in_ruins:
		hall_rally = _named("ForestGate").global_position \
				if _named("ForestGate") != null else _player_pos()
		if await _arena_open_ruins_door(deadline, hall_rally):
			# The door is the beginning of the hall, not an invitation into it.
			# Opening it wakes every post inside at once, so the arena opens it,
			# walks back out to the landing and gives the hall a few seconds to
			# lose what it heard, then goes in to meet the guards one at a time
			# instead of all of them at once. A hero fights on ground he chose.
			await _travel_to(hall_rally, 26.0, 25.0)
			await _wait(4.0)
			await _arena_pin_kind(ARENA_SUPPORT_KINDS, 130.0, deadline, hall_rally)
	_set_control_watch(false)
	bot_input.release_all()

	var kills_total := 0
	for killed_type: String in _m_kills_by_type:
		kills_total += int(_m_kills_by_type[killed_type])
	var melee := _a_melee + _a_walker_melee
	var casts := _a_casts
	var heals := _a_heals
	var switches := _a_switches
	var max_control_ms := _a_max_control_ms
	var melee_engaged := _arena_kind_engaged(ARENA_MELEE_KINDS)
	var ranged_engaged := _arena_kind_engaged(ARENA_RANGED_KINDS)
	var support_engaged := _arena_kind_engaged(ARENA_SUPPORT_KINDS)
	_notes.append("melee=%d (own=%d walker=%d)" % [melee, _a_melee, _a_walker_melee])
	_notes.append("casts=%d (spell=%s cost=%d mana=%d)" % [
		casts, _a_spell, _a_spell_cost, GameState.mana])
	_notes.append("heals=%d" % heals)
	_notes.append("switches=%d" % switches)
	_notes.append("zone=%s" % String(GameState.zone))
	_notes.append("dmg_by_type=%s" % _fmt_counts(_m_dmg_by_type))
	_notes.append("kills_by_type=%s" % _fmt_counts(_m_kills_by_type))
	_notes.append("roles melee=%s ranged=%s support=%s" % [
		str(melee_engaged), str(ranged_engaged), str(support_engaged)])
	_notes.append("max_control_ms=%d" % max_control_ms)
	var three_roles := melee_engaged and ranged_engaged and support_engaged
	var fought := melee > 0 and casts > 0
	var progressed := kills_total > 0 and switches >= 1
	var in_control := max_control_ms < 1500
	var verdict := {
		"alive": GameState.hp > 0, "melee_role": melee_engaged,
		"ranged_role": ranged_engaged, "support_role": support_engaged,
		"melee_swings": melee > 0, "ranged_casts": casts > 0,
		"kills": kills_total > 0, "switches": switches >= 1,
		"no_stunlock": in_control,
	}
	var failed_terms: Array[String] = []
	for term: String in verdict:
		if not bool(verdict[term]):
			failed_terms.append(term)
	if failed_terms.is_empty():
		_notes.append("terms=all_pass")
	else:
		_notes.append("failed=%s" % ",".join(failed_terms))
	_result = "PASS" if failed_terms.is_empty() else "FAIL"


## Choose the arena's ranged mode once, out of the spells the hero actually
## knows, and remember what it costs. The cost used to be read off whatever was
## selected at the moment of the fight, and for most of a run that is nothing at
## all: an unknown spell costs nothing, "nothing" is not affordable by the gate
## below it, and the arena then walked every archer off the map without throwing a
## single bolt — two of five runs failed their own ranged-mode term with the mana
## pool still full.
func _a_pick_spell() -> void:
	_a_spell = ""
	_a_spell_cost = 0
	for skill_id in GameState.known_skills:
		var skill := SkillDB.get_skill(skill_id)
		if skill.is_empty() or String(skill.get("shape", "")) == "self":
			continue
		var cost := int(skill.get("mana", 0))
		if cost <= 0:
			continue
		if GameState.select_skill(skill_id):
			_a_spell = skill_id
			_a_spell_cost = cost
			return


## Open the eastern chest and put on what it holds, through the same inventory
## panel a player uses. The chest is three tiles from the archer the leg before
## this one just fought, so it costs a few steps and nothing in the way of a
## detour, and the sword inside it more than doubles what a swing buys. The arena
## used to walk into the ruins with the same five damage it left the spawn with;
## the war ate it.
func _arena_arm(deadline: int, rally: Vector2) -> void:
	var chest := _named("Chest")
	var hud := _hud()
	if chest == null or hud == null:
		_notes.append("arm_no_chest")
		return
	await _arena_fight_toward(NO_ROLES, chest.global_position, 18.0, deadline, rally)
	await _wait_for_alive(10.0)
	await _wait(0.2)
	var attack_before := GameState.total_attack()
	await _tap(&"interact")
	await _wait(0.4)
	if GameState.count_item("iron_sword") == 0:
		_notes.append("arm_chest_empty hp=%d" % GameState.hp)
		return
	# Standing on the chest while tapping inventory keys invites its prompt back
	# under the panel, so the equip happens one pace off it — the same reason the
	# economy scenario steps off the merchant's mat before it opens the bag.
	await _travel_to(_player_pos() + Vector2(0.0, 44.0), 12.0, 15.0)
	if not await _equip_via_inventory(hud, "Железный меч"):
		_notes.append("arm_equip_failed hp=%d" % GameState.hp)
		return
	_notes.append("armed attack=%d->%d hp=%d" % [
		attack_before, GameState.total_attack(), GameState.hp])


## Walk the arena's supply run before it walks into a hall. The forest's own
## finds near the spawn go into the bag first — the potion at (13,10) is nine
## tiles of free healing — then the wolves at the edge of the clearing pay for
## the rest: their fangs are what Yorek buys, and the walk to him is two tiles.
## Everything here is the human route: walk, swing, sell through the merchant's
## own trade entry, buy off the open panel with the same key.
func _arena_prep(deadline: int) -> void:
	var spawn := _player_spawn()
	# Step one is the village's own first job. Edrik pays 60 gold, 50 xp and two
	# health potions for the three wolves at the spawn edge — the same three the
	# arena is about to swing at regardless — and a level in this game refills
	# both pools outright. The quest is therefore not a detour the bot takes on
	# the way to the fight; it is the only reason a level-one hero can afford a
	# second zone at all. Runs that skipped it went into the ruins carrying one
	# starting potion and a five damage fist, and died in the doorway.
	var edrik := _find_node("interactable")
	if edrik != null:
		await _travel_to(edrik.global_position, 18.0, 40.0)
		await _tap(&"interact")
		await _wait(0.5)
		await _dismiss_dialogue()
	# The finds worth a walk: the potion nine tiles east of the spawn, and
	# nothing that belongs to a boss's yard.
	var guard := 0
	while guard < 2 and Engine.get_physics_frames() < deadline:
		guard += 1
		var loot := _nearest_pickup()
		if loot == null or loot.global_position.distance_to(spawn) > 240.0 \
				or _near_boss(loot.global_position, 90.0):
			break
		await _travel_to(loot.global_position, 10.0, 30.0)
	# The hunt is the quest objective first and a purse second: it stops when the
	# job is ready to turn in and a few kills more are on the board, and it never
	# chases prey out of the spawn's own quarter, because a prep that wanders off
	# is a march that starts from the wrong end of the map.
	var kills_at_start := _kill_total()
	var hunt_until := mini(Engine.get_physics_frames() + _frames(70.0), deadline)
	while Engine.get_physics_frames() < hunt_until:
		var ready := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY
		var kills := _kill_total() - kills_at_start
		if kills >= (4 if ready else 7):
			break
		# The wolves the job counts, not whatever is closest: a spider beaten in
		# place of a wolf spends the same HP and leaves the order outstanding,
		# and an outstanding order is a run that walks into the ruins with one
		# potion in the bag.
		var prey := _nearest_quest_enemy(QUEST_ID)
		if prey == null:
			prey = _nearest_enemy()
		if prey == null or prey.is_in_group("boss") or _near_boss(prey.global_position, 110.0):
			break
		# Two different appetites, two different rings. While the order is still
		# open the wolf is followed wherever it patrols, because the reward behind
		# it is two potions, sixty gold and a level, and no ring drawn around the
		# spawn is worth walking away from that. Once the order is closed the hunt
		# is only topping a purse up, and a purse is not worth leaving the quarter
		# the east march is meant to start from.
		if ready and prey.global_position.distance_to(spawn) > 340.0:
			break
		if not ready and _player_pos().distance_to(spawn) > 520.0:
			break
		await _heal_if_hurt(ARENA_HEAL_AT)
		var prey_d := _player_pos().distance_to(prey.global_position)
		bot_input.set_aim(prey.global_position)
		if prey_d > 20.0:
			await _move_step(prey.global_position)
		else:
			await _tap(&"attack")
			await _wait(0.1)
	bot_input.release_all()
	# Turn it in. The turn-in is the payment: gold, xp and the two potions the
	# reward table carries all land on the same key press that closes the job.
	var quest_before := QuestManager.state_of(QUEST_ID)
	if edrik != null and quest_before == QuestManager.STATE_READY:
		await _travel_to(edrik.global_position, 18.0, 45.0)
		await _tap(&"interact")
		await _wait(0.5)
		await _dismiss_dialogue()
	var merchant := _named("Yorek")
	var hud := _hud()
	if merchant == null or hud == null:
		_notes.append("prep_no_merchant")
		return
	await _travel_to(merchant.global_position, 22.0, 40.0)
	var trade := ShopManager.new(GameState)
	var fangs := GameState.count_item("wolf_fang")
	if fangs > 0:
		trade.sell("wolf_fang", fangs)
	# The purchase is the panel's own: open it and every tap on the open frame
	# buys the row the cursor sits on, which is the merchant's first stock entry —
	# the potion. The bot writes no gold and no item; it presses the key.
	var price := trade.buy_price("health_potion")
	var taps := 0
	# The first press may draw Yorek's greeting rather than his till; the helper
	# advances that greeting to its flag-setting last node and presses again, so
	# the buy loop below always finds a real panel (or a clean no-open), never a
	# conversation under the keyboard.
	await _open_merchant_shop(hud)
	while bool(hud.call("is_shop_open")) and taps < 4:
		if GameState.gold < price:
			break
		await _tap(&"interact")
		await _wait(0.3)
		taps += 1
	await _tap(&"pause")
	await _wait(0.3)
	_notes.append("prep quest=%s->%s potions=%d gold=%d level=%d hp=%d fangs_sold=%d" % [
		str(quest_before), str(QuestManager.state_of(QUEST_ID)),
		GameState.count_item("health_potion"), GameState.gold, GameState.level,
		GameState.hp, fangs])


## Whether the arena has landed at least one of its own hits on any enemy wearing
## one of these roles. Read off the damage sensor, so "engaged" means the arena
## hit it — not that it walked past, and not that it got hit back.
func _arena_kind_engaged(kinds: Array[String]) -> bool:
	for kind in kinds:
		if int(_m_dmg_by_type.get(String(kind), 0)) > 0:
			return true
	return false


## The arena\'s march: walk a long leg in bounded chunks so the survival rules keep
## running between them, and stop to fight anything within the hunt leash that
## wears a role this leg still has to prove. `_travel_to` is the walker — A*,
## bump memory, fights inside the lane — and the arena adds the heal, the
## break-off and the bookkeeping.
func _arena_fight_toward(hunt: Array[String], dest: Vector2, arrive: float,
		deadline: int, rally: Vector2) -> void:
	await _wait_for_alive(10.0)
	while Engine.get_physics_frames() < deadline:
		if GameState.hp <= 0:
			bot_input.release_all()
			return
		if await _heal_if_hurt(ARENA_HEAL_AT):
			_a_heals += 1
		if await _arena_break_step(rally):
			continue
		var foe := _arena_pick_target(hunt)
		if foe == null:
			if _player_pos().distance_to(dest) <= arrive:
				break
			var left := float(deadline - Engine.get_physics_frames()) / 60.0
			var chunk := minf(ARENA_CHUNK, left)
			if chunk <= 1.0:
				break
			await _travel_to(dest, arrive, chunk)
			continue
		await _arena_strike(foe)
	bot_input.release_all()


## Stand on one role until the sensor has a hit of the arena\'s own down on it.
## The ranged enemy kites and the caster hides behind the guards of its own hall,
## so this re-finds the nearest live bearer of the role every round instead of
## following one node, and gives up on the budget rather than the role.
func _arena_pin_kind(kinds: Array[String], budget: float, deadline: int,
		rally: Vector2, min_exchanges := 3) -> void:
	await _wait_for_alive(10.0)
	var until := Engine.get_physics_frames() + _frames(budget)
	until = mini(until, deadline)
	var saw := 0
	var exchanges := 0
	var best_d := INF
	var since_gain := 0
	while Engine.get_physics_frames() < until:
		if GameState.hp <= 0:
			break
		# The leg is not finished just because somebody has already bled for this
		# role. The walker clears the lane on the way east and has been known to
		# kill the archer before the ranged leg ever started, which left the arena
		# with its bolt unfired and its own ranged-mode term unmet — so every pin
		# owes a few exchanges of its own before it may stand down.
		if _arena_kind_engaged(kinds) and exchanges >= min_exchanges:
			break
		if await _heal_if_hurt(ARENA_HEAL_AT):
			_a_heals += 1
		if await _arena_break_step(rally):
			continue
		var foe := _arena_role_target(kinds)
		if foe == null:
			await _wait(0.3)
			continue
		saw += 1
		var foe_d := _player_pos().distance_to(foe.global_position)
		if foe_d < best_d - 4.0:
			best_d = foe_d
			since_gain = 0
		else:
			since_gain += 1
		if foe_d > ARENA_HUNT_LEASH:
			await _travel_to(foe.global_position, 60.0, ARENA_CHUNK)
			continue
		# A caster that will not be closed is usually not refusing to be closed —
		# the bot is on the wrong side of something it has already agreed is a
		# wall. One run pinned the cultist through 1657 exchanges at a stand-off of
		# 54 px and died there with six potions in the bag: the walk kept sliding
		# along the same hall wall, which counts as motion, so no stuck timer ever
		# fired. Forty exchanges without four pixels of gain is therefore read as
		# a route problem rather than a fight, the learned walls are dropped, and
		# the way is rebuilt from the tile underfoot.
		if since_gain >= 40 and foe_d > ARENA_ENGAGE + 6.0:
			since_gain = 0
			_bumped.clear()
			await _travel_to(foe.global_position, ARENA_ENGAGE, ARENA_CHUNK)
			continue
		exchanges += 1
		await _arena_strike(foe)
	bot_input.release_all()
	# What the leg actually saw. A pin that failed with `saw=0` never found the
	# role at all, one with `best` stuck high never closed on it, and one with
	# `exchanges` but no damage is a fight the enemy refused to stand for — three
	# different defects that a bare FAIL cannot tell apart.
	_notes.append("pin[%s] saw=%d exchanges=%d best=%d engaged=%s hp=%d" % [
		",".join(kinds) if kinds.size() < 4 else "melee", saw, exchanges,
		0 if is_inf(best_d) else int(best_d),
		str(_arena_kind_engaged(kinds)), GameState.hp])


## The nearest live enemy wearing one of these roles, bosses except. The hall
## boss is never a role stand-in: the arena has no business trading blows with
## the Captain while it is still proving it can handle a bowman.
func _arena_role_target(kinds: Array[String]) -> Node2D:
	var here := _player_pos()
	var best: Node2D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e == null or not is_instance_valid(e) or e.is_in_group("boss"):
			continue
		if not kinds.has(String(e.get("enemy_type"))):
			continue
		var d := e.global_position.distance_to(here)
		if d < best_d:
			best_d = d
			best = e
	return best


## Target choice for a march: an enemy wearing a role the leg still has to prove
## wins over the nearest body, so the walk does not spend itself on wolves the
## arena has already blooded. Anything else is only worth stopping for once it is
## close enough to be in the way.
func _arena_pick_target(hunt: Array[String]) -> Node2D:
	var here := _player_pos()
	var best: Node2D = null
	var best_score := INF
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e == null or not is_instance_valid(e) or e.is_in_group("boss"):
			continue
		var etype := String(e.get("enemy_type"))
		if etype == "lumberjack":
			continue
		var d := e.global_position.distance_to(here)
		var unproven := hunt.has(etype) and int(_m_dmg_by_type.get(etype, 0)) == 0
		if unproven:
			if d > ARENA_HUNT_LEASH:
				continue
		elif d > ARENA_ENGAGE:
			continue
		var score := d if unproven else 100000.0 + d
		if score < best_score:
			best_score = score
			best = e
	return best


## One exchange with one enemy: cast while it is still at bowshot, walk the gap
## when the cast is spent, swing once it is in arm\'s reach. A cast only counts
## when it actually paid mana, so a recast blocked by a cooldown is not padded
## into the number, and a target freed by the bolt of the cast before it is
## re-resolved before the arena touches it again.
func _arena_strike(foe: Node2D) -> void:
	var eid := foe.get_instance_id()
	if _a_last_target != -1 and eid != _a_last_target:
		_a_switches += 1
	_a_last_target = eid
	var dist := _player_pos().distance_to(foe.global_position)
	var engage := float(_pf("engage_range", 16.0))
	if dist > engage + 6.0:
		# Anything outside arm's reach that the pool can pay for gets the bolt, and
		# nothing else. There was a band between the swing reach and the old cast
		# range where the arena neither shot nor arrived, and one run spent its
		# whole ranged budget in it: 911 exchanges of walking up to an archer who
		# walked back off, at the end of which the mana pool was still full.
		if _a_spell != "" and GameState.mana >= _a_spell_cost:
			var mana_before := GameState.mana
			bot_input.set_aim(foe.global_position)
			await _tap(&"ability")
			if GameState.mana < mana_before:
				_a_casts += 1
			await _wait(0.15)
		var still := instance_from_id(eid) as Node2D
		if still != null and is_instance_valid(still):
			await _move_step(still.global_position)
		return
	bot_input.set_aim(foe.global_position)
	await _tap(&"attack")
	_a_melee += 1
	await _wait(0.2)
	var rd := float(_pf("reaction_delay", 0.0))
	if rd > 0.0:
		await _wait(rd)


## The arena\'s survival rule, shared by every leg of both zones: out of medicine
## and bleeding, or three muzzles in a ring, the hero leaves the field for the
## rally point of the zone he is standing in and only comes back at 70 %. Returns
## true while the break is running, so the caller skips its own attack step.
func _arena_break_step(rally: Vector2) -> bool:
	if not _a_broken:
		if Engine.get_physics_frames() < _a_break_cooldown_until:
			return false
		if GameState.hp > int(GameState.max_hp * 0.40) and not _crowded():
			return false
		_a_broken = true
		_a_break_started = Engine.get_physics_frames()
	if GameState.hp >= int(GameState.max_hp * 0.70):
		_end_arena_break("recovered")
		return false
	if Engine.get_physics_frames() - _a_break_started > _frames(ARENA_BREAK_BUDGET):
		# No medicine and no recovery in sight, and a leg still to walk. Standing
		# still while an archer spends the whole map on the hero is the slower of
		# the two deaths, so the break is given up and the lane walked again.
		_end_arena_break("abandoned")
		return false
	if _player_pos().distance_to(rally) > 20.0:
		await _move_step(rally)
	else:
		await _wait(0.2)
	return true


## Close a break-off and say why, then hold the same rule off for a moment so the
## leg gets a real run at the lane instead of breaking off again next frame.
## Wait out a death. The hero picks himself up a few seconds after he falls, back
## on the zone's own spawn point, and one fall is not the end of the arena — but
## the legs used to carry straight on over a corpse, so the chest check read
## `hp=0`, the interact went nowhere, and the run then marched a dead man across
## the rest of the map and reported an empty chest.
func _wait_for_alive(seconds: float) -> void:
	if GameState.hp > 0:
		return
	var until := Engine.get_physics_frames() + _frames(seconds)
	while GameState.hp <= 0 and Engine.get_physics_frames() < until:
		await _wait(0.25)
	_a_broken = false
	_notes.append("respawned hp=%d at=%s" % [GameState.hp, str(_tile_of(_player_pos()))])


func _end_arena_break(reason: String) -> void:
	_a_broken = false
	_a_break_cooldown_until = Engine.get_physics_frames() + _frames(ARENA_BREAK_COOLDOWN)
	_notes.append("break_%s hp=%d" % [reason, GameState.hp])


## Walk to the forest gate and ask it for the ruins. Travel is the player\'s own
## `interact` on the `ZoneExit` — the bot writes no zone — and the leg is only
## over once `GameState.zone` actually answers `ruins`, because a gate the bot
## walked past without pressing E is a leg that never happened.
func _arena_enter_ruins(deadline: int) -> bool:
	var gate := _named("RuinsGate")
	if gate == null:
		_notes.append("ruins_gate_missing")
		return false
	await _arena_fight_toward(NO_ROLES, gate.global_position, 16.0, deadline,
		_player_spawn())
	for attempt in 4:
		if String(GameState.zone) == "ruins":
			return true
		# The press itself is three physics frames and is always allowed, even
		# after the leg's own clock has run out. One run spent its last seconds on
		# a break-off two tiles from the gate, came back at full health, and the
		# deadline check refused it the one key press that would have finished the
		# scenario — a bot out of time still knocks before it leaves.
		if Engine.get_physics_frames() >= deadline and attempt > 0:
			break
		# Stand on the gate's own tile rather than near it: the exit sits on a
		# tile the zone already called walkable, and the interact reaches 26 px,
		# so arriving "close" is the one way to miss it from the wrong side of a
		# tree line.
		await _travel_to(_tile_center(_tile_of(gate.global_position)), 6.0, 22.0)
		await _tap(&"interact")
		await _wait(0.8)
		if String(GameState.zone) == "ruins":
			# The old world and everything in it is gone now, including the tile
			# memory built up walking to the gate. A bump learned against a tree in
			# the forest must not become a wall in the ruins.
			_bumped.clear()
			_notes.append("entered_ruins at=%d" % Engine.get_physics_frames())
			return true
	_notes.append("ruins_gate_stuck zone=%s gate_dist=%d gate_tile=%s me=%s hp=%d" % [
		String(GameState.zone),
		int(_player_pos().distance_to(gate.global_position)),
		str(_tile_of(gate.global_position)),
		str(_tile_of(_player_pos())), GameState.hp])
	return false


## The ruins puzzle, driven through nothing but walking and the interact key: pick
## the key up off the floor by standing on it, spend it at the wall lever, and let
## the lever raise the flag the door answers to. Each step is confirmed by the
## world\'s own answer — the item in the bag, the flag on the state — because a
## lever that was merely walked up to opens nothing.
func _arena_open_ruins_door(deadline: int, rally: Vector2) -> bool:
	if bool(GameState.get_flag("ruin_door_open", false)):
		return true
	var lever := _named("RuinMechanism")
	if lever == null:
		_notes.append("ruins_lever_missing")
		return false
	var key := _named("RuinKey")
	if key != null and GameState.count_item("ruin_key") == 0:
		await _arena_fight_toward(NO_ROLES, key.global_position, 8.0, deadline, rally)
		await _wait(0.3)
	if GameState.count_item("ruin_key") == 0:
		_notes.append("ruins_key_missing")
		return false
	# The lever and the door are one tile apart and the player\'s interact picks the
	# nearest interactable in reach, so the approach is from the side the door is
	# not on. Coming in from the east would hand the tap to a locked door.
	var lever_tile := _tile_of(lever.global_position)
	var stand := _tile_center(lever_tile + Vector2i(-1, 0))
	for attempt in 4:
		if bool(GameState.get_flag("ruin_door_open", false)):
			_notes.append("ruin_door_open")
			return true
		if Engine.get_physics_frames() >= deadline:
			break
		if _walkable(lever_tile + Vector2i(-1, 0)):
			await _travel_to(stand, 8.0, 20.0)
		else:
			await _travel_to(lever.global_position, 10.0, 20.0)
		await _tap(&"interact")
		await _wait(0.5)
	_notes.append("ruin_door_stuck flag=%s key=%s" % [
		str(bool(GameState.get_flag("ruin_door_open", false))),
		str(GameState.count_item("ruin_key"))])
	return false


## The ground the hero wakes on wherever he currently stands. The forest's clearing is
## a constant, because every scenario that never leaves it can name it; a scenario
## that crosses a zone line needs the spawn of the zone it is in, and the player
## carries that number himself — every zone sets it the moment it places him.
func _rally_point() -> Vector2:
	var p := _player()
	if p != null:
		var spawn: Variant = p.get("spawn_point")
		if spawn is Vector2 and (spawn as Vector2) != Vector2.ZERO:
			return spawn as Vector2
	return _player_spawn()


## Get the hero moving again. A leg that spends two chunks inside the same eight
## pixels is not lost — the planner has a route and keeps walking it — it is held:
## a skeleton standing in the lane at a distance the walker's own thresholds do not
## cover (too far for the melee swing at 22 px, and not the waypoint, so not a
## target either), or a slide direction learned three tiles back and never
## forgotten, which keeps pressing the hero into a wall he has already touched.
## Both are answered the same way: let go of every key, drop the borrowed slide and
## the learned walls, hit whatever is close enough to be the reason, and take one
## honest step onto the neighbouring tile with the most ground beyond it. Nothing
## here teleports, heals, or writes state — it is what a player does when the
## character stops answering: wiggles out.
func _unstick(goal: Vector2 = Vector2.INF) -> void:
	bot_input.release_all()
	_avoid_frames = 0
	_avoid_dir = Vector2.ZERO
	_bumped.clear()
	var foe := _nearest_enemy()
	if foe != null and _player_pos().distance_to(foe.global_position) <= 48.0:
		bot_input.set_aim(foe.global_position)
		await _tap(&"attack")
	var here := _tile_of(_player_pos())
	var best := here
	var best_score := INF
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
		var candidate := here + offset
		if not _walkable(candidate, true):
			continue
		# With a goal in hand the escape is chosen by the one thing that matters:
		# whether the planner can see a road to that goal from the tile being
		# stepped onto, and how long it is. «Most open ground» sounds sensible and
		# is how one run spent ten minutes crossing the same corridor twice — the
		# escape walked out of the pocket and straight back into it, because the
		# pocket had more open tiles around it.
		var score := INF
		if goal != Vector2.INF:
			var route := _find_path(candidate, _tile_of(goal), true, false)
			if route.is_empty():
				continue
			score = float(route.size())
		else:
			var open_beyond := 0.0
			for probe: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if _walkable(candidate + probe, true):
					open_beyond += 1.0
			score = -open_beyond
		if score < best_score:
			best_score = score
			best = candidate
	if best == here:
		await _wait(0.5)
		return
	var step_to := _tile_center(best)
	for i in 60:
		if _player_pos().distance_to(step_to) < 6.0:
			break
		await _move_step(step_to)
	bot_input.release_all()


## Walk to a named `ZoneExit` and ask it for the far side, through the same
## `interact` the interact key uses. The leg is over when `GameState.zone` answers the
## zone on the other side, because a gate the bot walked up to without pressing E is a
## travel that never happened.
##
## This is the arena's entry leg generalised, and it was generalised the moment a
## second scenario needed it: two copies of «stand on the tile, knock, wait for the
## zone to answer» are two copies that can drift apart, and the one that drifts is the
## one that starts reporting a zone the hero never entered.
func _zone_travel(gate_name: String, target_zone: String, deadline: int, rally: Vector2) -> bool:
	var gate := _named(gate_name)
	if gate == null:
		_notes.append("gate_missing=%s zone=%s" % [gate_name, String(GameState.zone)])
		Telemetry.warning("gate %s is not in the zone called %s" % [gate_name, String(GameState.zone)])
		return false
	# Where the hero has to be to use the exit. The node's own position is the
	# obvious answer and sometimes a lie: an exit the world could not seat on floor
	# sits in a wall, and a wall has no route to it. Aim at the nearest ground
	# within three tiles and say in the log when that is not the node's own tile,
	# because `gate_stuck` two tiles from a column reads as a broken bot otherwise.
	var gate_tile := _tile_of(gate.global_position)
	var stand_tile := _nearest_walkable_tile(gate_tile, 3)
	var stand_point := _tile_center(stand_tile)
	if stand_tile != gate_tile:
		_notes.append("gate_off_ground=%s tile=%s stand=%s" % [gate_name, str(gate_tile), str(stand_tile)])
	# The long leg is walked by the planner with the threat price switched off, in
	# chunks long enough to cross a zone and short enough to re-plan from where the
	# hero actually got to. Fighting on the way is not skipped — `_travel_to` swings
	# at anything that comes into melee and closes on a shooter downrange of the
	# waypoint — but a route across a zone is not re-priced every time a skeleton
	# shifts its weight, which is what made a five-tile corridor cost the whole run.
	# A leg is also a fresh objective: walls learned leaning into a plate alcove
	# must not be the reason the road out of the undercroft cannot be found.
	_bumped.clear()
	# The knock itself is thrown from a little closer than the tile the planner
	# stopped on: an exit seated in a wall is one tile (32 px) from the nearest
	# ground, and the interact reach is 26 px, so standing dead centre on that
	# ground is too far to be heard. The nudge is only taken while the tile under
	# it is still ground the zone admits.
	var knock_point := stand_point
	var toward_gate := gate.global_position - stand_point
	if toward_gate.length() > 1.0:
		var nudged: Vector2 = stand_point \
				+ toward_gate.normalized() * minf(14.0, toward_gate.length())
		if _walkable(_tile_of(nudged), true):
			knock_point = nudged
	var unsticks := 0
	while Engine.get_physics_frames() < deadline and String(GameState.zone) != target_zone:
		if GameState.hp <= 0:
			await _wait_for_alive(12.0)
			bot_input.release_all()
			break
		# Standing within reach of the exit ends the walk. `_travel_to` answers
		# «already there» on the spot without spending a physics frame, so a loop
		# that kept asking it would run a million times a second and stop the
		# engine rather than wait for a zone that was never going to change.
		if _player_pos().distance_to(stand_point) <= GATE_KNOCK_RANGE:
			break
		if await _heal_if_hurt(ARENA_HEAL_AT):
			_a_heals += 1
		# Breaking off is reserved for a hero who is actually dying. On a full pool
		# the same call would read a crowded undercroft as a losing fight and walk
		# the leg back to the rally point every few seconds, which is a second way
		# to spend a run crossing the same corridor.
		if GameState.hp <= int(GameState.max_hp * 0.40) and await _arena_break_step(rally):
			continue
		var left := float(deadline - Engine.get_physics_frames()) / 60.0
		if left <= 1.0:
			break
		var before := _player_pos()
		await _travel_to(stand_point, GATE_KNOCK_RANGE, minf(30.0, left), false)
		await _wait(0.1)
		# A chunk that bought no ground is a chunk to learn from, not a chunk to
		# repeat: the same plan from the same eight pixels buys the same nothing for
		# the remaining eight minutes of the budget, which is exactly how one run
		# spent five hundred seconds being held by a skeleton at twenty-six.
		if _player_pos().distance_to(before) < 12.0:
			unsticks += 1
			if unsticks <= 5:
				_notes.append("leg_unstick=%s at=%s" % [gate_name, str(_tile_of(_player_pos()))])
			await _unstick(stand_point)
	for attempt in 4:
		if String(GameState.zone) == target_zone:
			return true
		# The press itself is three physics frames and is always allowed, even after
		# the leg's own clock has run out: a bot out of time still knocks before it
		# leaves, and one knock on the right tile is the difference between a zone
		# entered and a run that walked all this way for nothing.
		if Engine.get_physics_frames() >= deadline and attempt > 0:
			break
		# Stand on the exit's own tile rather than near it. The interact reaches 26 px,
		# which is exactly the distance at which arriving "close" from the wrong side
		# of a wall asks the wrong thing. The step is only taken while the hero is
		# still off that tile: an exit whose exact centre the body cannot occupy (a
		# gate node set into the wall line) would otherwise cost four full approach
		# budgets and still leave the key pressed from two tiles away.
		var stand_on := knock_point
		if _player_pos().distance_to(stand_on) > 8.0:
			await _travel_to(stand_on, 6.0, 15.0, false)
		await _tap(&"interact")
		await _wait(0.8)
		if String(GameState.zone) == target_zone:
			# The old world and everything in it is gone now, including the tile
			# memory built up walking to this gate. A bump learned against a tree in
			# the forest must not become a wall in the ruins.
			_bumped.clear()
			_note_zone()
			_notes.append("entered_%s at=%d" % [target_zone, Engine.get_physics_frames()])
			return true
	var detail := "gate_stuck=%s zone=%s dist=%d me=%s hp=%d" % [
		gate_name, String(GameState.zone),
		int(_player_pos().distance_to(gate.global_position)),
		str(_tile_of(_player_pos())), GameState.hp]
	_notes.append(detail)
	Telemetry.warning(detail)
	return false


## Walk the hero into `zone_id` through the world's own ZoneExit gates, or say
## in the log that the crossing failed. The forest and the village are joined by
## exactly one pair of doors — `VillageGate` on the forest's west clearing,
## `ForestGate` one tile inside the village wall — so this covers every crossing
## the village-era quest and economy bots make; the deeper zones keep their own
## named gates and call `_zone_travel` directly. Answering true at once when the
## hero already stands in the wanted zone lets a scenario ask for the leg it
## means to walk without reading the zone itself first. Every reference to a
## node of the old zone dies at the gate with that zone, so what a caller wanted
## from the far side must be looked up again after this returns true.
func _goto_zone(zone_id: String, timeout_seconds: float) -> bool:
	if String(GameState.zone) == zone_id:
		return true
	var gate_name := "VillageGate" if zone_id == "village" else "ForestGate"
	var deadline := Engine.get_physics_frames() + _frames(timeout_seconds)
	return await _zone_travel(gate_name, zone_id, deadline, _rally_point())


## The dungeon kinds this run has actually drawn blood from, read off the damage
## sensor. "Engaged" means the bot hit it — not that it walked past one, and not that
## it got hit back by one.
func _dungeon_blood() -> Dictionary:
	var blood: Dictionary = {}
	for kind in DUNGEON_KINDS:
		var dealt := int(_m_dmg_by_type.get(String(kind), 0))
		if dealt > 0:
			blood[String(kind)] = dealt
	return blood


func _dungeon_distinct_count() -> int:
	return _dungeon_blood().size()


## The nearest live dungeon kind this run has not yet hit. Nearest rather than first
## in the list, because the undercroft is a grid of corridors and the kind a hero can
## actually reach is the kind he is going to fight.
func _dungeon_unbled_kind() -> String:
	var here := _player_pos()
	var best := ""
	var best_d := INF
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e == null or not is_instance_valid(e) or e.is_in_group("boss"):
			continue
		var kind := String(e.get("enemy_type"))
		if not DUNGEON_KINDS.has(kind) or int(_m_dmg_by_type.get(kind, 0)) > 0:
			continue
		var d := e.global_position.distance_to(here)
		if d < best_d:
			best_d = d
			best = kind
	return best


## Draw blood from at least `wanted` distinct kinds of the undercroft, one kind at a
## time. The arena already knows how to hold onto one role until the sensor has a hit
## of its own on it; what it never needed was the plural, because its three roles are
## three different lists. Handing `_arena_pin_kind` a list one kind wide is what turns
## "engaged the nearest thing" into "engaged two things that are not the same thing".
##
## A pin that comes back with no new blood is given one more slice at the same kind
## before the run moves on, and the number reported at the end is the number the
## sensor holds, not the number of pins attempted.
func _dungeon_engage_distinct(wanted: int, budget_each: float, deadline: int,
		rally: Vector2) -> int:
	var engaged := _dungeon_distinct_count()
	var misses := 0
	while engaged < wanted and Engine.get_physics_frames() < deadline:
		var kind := _dungeon_unbled_kind()
		if kind == "":
			_notes.append("dungeon_no_unbled_kind engaged=%d" % engaged)
			break
		await _arena_pin_kind([kind], budget_each, deadline, rally)
		var now := _dungeon_distinct_count()
		if now <= engaged:
			misses += 1
			if misses >= 2:
				_notes.append("dungeon_kind_refused=%s engaged=%d" % [kind, engaged])
				break
			continue
		misses = 0
		engaged = now
	return engaged


## One of the undercroft's spike plates, watched the way BOT-007 watches the forest's:
## from the standoff, long enough for a whole cycle, counting only the plate's own
## hits. Then the lane past it, walked while the warning is still on the record.
##
## The promise being tested is the same one and it matters more here than it does in
## the forest: these plates sit on the two narrowed stretches of a zone that has
## nothing else, so a hazard that cannot be seen here is a hazard a hero cannot walk
## around at all.
func _dungeon_trap_lesson(deadline: int, rally: Vector2) -> Dictionary:
	var out := {"found": false, "telegraph_seen": false, "damage_at_distance": 0,
		"crossed": false, "damage_crossing": 0, "skipped": false}
	var plates: Array = []
	for plate_name: String in ["TrapA", "TrapB"]:
		var plate_node := _named(plate_name)
		if plate_node != null:
			plates.append(plate_node)
	if plates.is_empty():
		_notes.append("dungeon_trap_missing")
		Telemetry.warning("no spike plate in the undercroft")
		return out
	out["found"] = true
	_bumped.clear()
	var spot := _reachable_standoff(plates)
	if spot.is_empty():
		# Every plate in this seed's undercroft sits where no walkable, reachable
		# ground looks out on it. That is a fact about the generated map, not a
		# broken warning, and the run says which of the two it is instead of
		# failing a promise it was never given the ground to keep.
		_notes.append("dungeon_trap_unreachable")
		out["skipped"] = true
		return out
	var trap: Node2D = spot["trap"]
	var trap_pos: Vector2 = trap.global_position
	_m_trap_id = trap.get_instance_id()
	_m_trap_damage = 0
	var watch_point: Vector2 = spot["point"]
	if not await _travel_to(watch_point, 10.0, 70.0, false) \
			and _player_pos().distance_to(trap_pos) > 60.0:
		_notes.append("dungeon_trap_watch_unreachable")
		out["skipped"] = true
		return out
	var telegraph_seen := false
	var watch_until := mini(Engine.get_physics_frames() + _frames(9.0), deadline + _frames(9.0))
	while Engine.get_physics_frames() < watch_until:
		var plate: ColorRect = trap.get("visual")
		if plate != null and plate.color.a > 0.5:
			telegraph_seen = true
			break
		var threat := _nearest_enemy()
		if threat != null and _player_pos().distance_to(threat.global_position) < 20.0:
			bot_input.set_aim(threat.global_position)
			await _tap(&"attack")
		await _wait(0.1)
	out["telegraph_seen"] = telegraph_seen
	out["damage_at_distance"] = _m_trap_damage
	# The lane past the plate, on whichever side of it the zone calls ground two
	# tiles out. Walking to it either steps over the plate or goes around it, and the
	# scenario accepts either — what it does not accept is damage from a plate that
	# gave no warning, which is the half the watch above is there to settle.
	var here_tile := _tile_of(trap_pos)
	var beyond := Vector2.INF
	var from_here := _tile_of(_player_pos())
	for offset in [Vector2i(0, 2), Vector2i(2, 0), Vector2i(0, -2), Vector2i(-2, 0),
			Vector2i(2, 2), Vector2i(-2, 2), Vector2i(2, -2), Vector2i(-2, -2)]:
		if not _walkable(here_tile + offset, true):
			continue
		if _find_path(from_here, here_tile + offset, true, false).is_empty():
			continue
		beyond = _tile_center(here_tile + offset)
		break
	if beyond != Vector2.INF and GameState.hp >= int(GameState.max_hp * 0.4):
		_m_trap_damage = 0
		out["crossed"] = await _travel_to(beyond, 8.0, 45.0, false)
		out["damage_crossing"] = _m_trap_damage
	else:
		_notes.append("dungeon_plate_skipped hp=%d" % GameState.hp)
	bot_input.release_all()
	_notes.append("trap telegraph=%s dmg_at_distance=%d crossed=%s dmg_crossing=%d hp=%d" % [
		str(bool(out["telegraph_seen"])), int(out["damage_at_distance"]),
		str(bool(out["crossed"])), int(out["damage_crossing"]), GameState.hp])
	_m_trap_id = -1
	return out


## Phases of the King this run has seen, straight off his own `phase_changed`.
var _king_phases: Array[int] = []


func _on_king_phase(phase: int) -> void:
	if _king_phases.has(phase):
		return
	_king_phases.append(phase)
	# What the bot has paid into the King's pool by the moment the phase changed, read
	# off the bot's own damage sensor. The verdict is the signal's, never a number the
	# bot computed for itself — this line is here so a reader can see how much of the
	# 600 the transition cost, not so it can be argued with.
	_notes.append("king_phase_%d at=%d hp=%d dealt=%d" % [
		phase, Engine.get_physics_frames(), GameState.hp,
		int(_m_dmg_by_type.get("king_without_crown", 0))])


## The King's own fight loop. The arena's role machinery refuses bosses on purpose,
## which is right for an arena and wrong for the one scenario whose verdict is a boss.
## This loop keeps the same survival rules — drink early, break off when the ring
## closes, cast at bowshot, close, swing — and points them at one named body.
##
## It ends the moment phase 2 has been seen, because that is the term. Grinding the
## King's last 396 HP out for the sake of a kill the scenario never promised spends
## the rest of the run's budget on a fight nobody is measuring.
func _fortress_fight_king(deadline: int, rally: Vector2) -> Dictionary:
	var out := {"found": false, "phase2": false, "outcome": "king_missing"}
	var king := _named("KingWithoutCrown")
	if king == null:
		_notes.append("king_missing zone=%s" % String(GameState.zone))
		Telemetry.warning("the fortress has no King in it")
		return out
	out["found"] = true
	_bumped.clear()
	_king_phases = []
	if king.has_signal("phase_changed"):
		king.connect("phase_changed", _on_king_phase)
	var march_rally := rally
	# The spine is forty tiles and the yard at the end of it is where the King stands.
	# The approach is a planned walk, not a straight line: the spine has a wall down
	# its middle, and a bot that prices its route around every guard in the yard
	# re-prices it the moment one of them steps, which reads as a change of mind and
	# costs the run its budget two tiles at a time. The fight itself is the arena's
	# own — heal, break off to the zone's spawn, answer what is in the lane.
	while Engine.get_physics_frames() < deadline \
			and _player_pos().distance_to(king.global_position) > 40.0:
		if GameState.hp <= 0:
			await _wait_for_alive(12.0)
			bot_input.release_all()
			break
		if await _heal_if_hurt(ARENA_HEAL_AT):
			_a_heals += 1
		var march_left := float(deadline - Engine.get_physics_frames()) / 60.0
		if march_left <= 1.0:
			break
		var march_before := _player_pos()
		await _travel_to(king.global_position, 40.0, minf(30.0, march_left), false)
		if _player_pos().distance_to(march_before) < 12.0:
			await _unstick(king.global_position)
	await _wait_for_alive(12.0)
	while Engine.get_physics_frames() < deadline:
		if _king_phases.has(2) or _king_phases.has(3):
			break
		if GameState.hp <= 0:
			await _wait_for_alive(12.0)
			if GameState.hp <= 0:
				out["outcome"] = "no_respawn"
				return out
		if not is_instance_valid(king):
			# The King died without ever reaching his second phase — a kill bought
			# with the whole budget is still a fight the hero finished on his feet.
			out["outcome"] = "king_dead"
			break
		if await _heal_if_hurt(ARENA_HEAL_AT):
			_a_heals += 1
		if await _arena_break_step(march_rally):
			continue
		var dist := _player_pos().distance_to(king.global_position)
		if dist > 44.0:
			await _travel_to(king.global_position, 36.0, 10.0, false)
			continue
		await _arena_strike(king)
	out["phase2"] = _king_phases.has(2) or _king_phases.has(3)
	if GameState.hp <= 0:
		# The budget ran out with the hero on the ground. Whether the world gives him
		# back is the whole difference between a hard fight and a broken one, so it is
		# waited for rather than assumed.
		await _wait_for_alive(20.0)
		out["outcome"] = "respawned" if GameState.hp > 0 else "no_respawn"
	elif String(out["outcome"]) != "king_dead":
		out["outcome"] = "alive"
	if king.has_signal("phase_changed"):
		king.disconnect("phase_changed", _on_king_phase)
	_notes.append("king fight outcome=%s phases=%s dmg=%d hp=%d" % [
		String(out["outcome"]), str(_king_phases),
		int(_m_dmg_by_type.get("king_without_crown", 0)), GameState.hp])
	return out




## BOT-004 — magic. Every skill in `GameState.known_skills` is selected through
## the public selection API and cast through the same `ability` action the human
## right mouse uses. Three facts are measured per skill: the mana pool drops by
## exactly the data cost (the pool has no passive regen, so the drop is exact
## and not a race), an immediate recast is refused by the cooldown and spends
## nothing, and at least one cast across the run lands a status on a live enemy
## — counted on `EventBus.status_applied`, the same event the combat telemetry
## writes to `combat.jsonl`.
func _scenario_magic() -> void:
	_connect_combat_sensors()
	var skills: Array[String] = GameState.known_skills.duplicate()
	if skills.is_empty():
		_notes.append("no_known_skills")
		return
	# A status needs a live target in bolt range; the wolves east of the spawn
	# are the nearest ones, and the bot walks to one instead of firing at empty
	# road. Without any enemy the status check is honestly reported as unmet.
	var target := _nearest_enemy()
	if target != null:
		await _move_to(target.global_position, 55.0, 25.0)
	var exact_costs := 0
	var cooldown_blocks := 0
	var casts := 0
	for skill_id in skills:
		if GameState.hp <= 0:
			break
		if not GameState.select_skill(skill_id):
			_notes.append("select_failed:" + skill_id)
			continue
		var skill := SkillDB.get_skill(skill_id)
		var cost := int(skill.get("mana", 0))
		target = _nearest_enemy()
		if String(skill.get("shape", "")) != "self" and target != null:
			bot_input.set_aim(target.global_position)
		if GameState.mana < cost:
			_notes.append("out_of_mana:" + skill_id)
			continue
		var status_before := _m_status_hits
		var mana_before := GameState.mana
		await _tap(&"ability")
		if GameState.mana == mana_before - cost:
			exact_costs += 1
			casts += 1
		else:
			_notes.append("mana_mismatch:%s=%d->%d" % [skill_id, mana_before, GameState.mana])
		# The recast is immediate by design: every skill cooldown in the data is
		# well above the three physics frames a tap takes, so a cast that paid
		# mana here would mean the cooldown gate is gone.
		var recast_before := GameState.mana
		await _tap(&"ability")
		if GameState.mana == recast_before:
			cooldown_blocks += 1
		else:
			_notes.append("cooldown_leak:" + skill_id)
		if String(skill.get("status", "")) != "" and target != null:
			await _wait(0.8)
			if _m_status_hits > status_before:
				_notes.append("status_landed:" + skill_id)
		await _wait(0.15)
	_notes.append("casts=%d/%d" % [casts, skills.size()])
	_notes.append("exact_costs=%d/%d" % [exact_costs, skills.size()])
	_notes.append("cooldown_blocks=%d" % cooldown_blocks)
	_notes.append("statuses=%d" % _m_status_hits)
	var all_cast := casts == skills.size()
	var statuses_ok := _m_status_hits > 0
	_result = "PASS" if all_cast and exact_costs == skills.size() \
		and cooldown_blocks >= 1 and statuses_ok and GameState.hp > 0 else "FAIL"


## BOT-005 — inventory and economy. The whole route is walked: the east sword
## chest pays for the trip, the merchant Yorek is opened by walking up to him
## and pressing the real interact key, and the purchase is made by moving the
## shop cursor and pressing E — the human path end to end. Equipping goes
## through the inventory panel the same way (the panel reads the same
## InputSource, so arrows and E drive it). Selling is the one leg the UI cannot
## offer a bot: the buy/sell toggle is the Tab key, which the HUD edge-detects
## from the raw keyboard because it has no InputMap action, so the bot sells
## through `ShopManager.sell` — the very function the panel's E handler calls,
## with the same gold, stock and stack rules. No item is ever added or removed
## by the bot itself; the checks only count what the trades left behind.
func _scenario_economy() -> void:
	var hud := _hud()
	if hud == null:
		_notes.append("no_hud")
		return
	# The chest is in the forest and the till is in the village now: the two
	# actors this route needs live on opposite sides of a zone line, so only the
	# chest can be checked on the starting side. Yorek is looked up after the
	# first crossing, and a till that is not where the world says it is fails
	# the run by the same note name it always failed it by.
	var chest := _named("Chest")
	if chest == null:
		_notes.append("economy_actors_missing")
		return
	_connect_combat_sensors()
	# Every leg of this scenario is a crossing of the map rather than a duel, and
	# the crossings are where the runs died: at the profile's own threshold the bot
	# walks into the east clearing on a sliver of HP, and that clearing holds both an
	# archer and the warden. So the walker drinks at `ECONOMY_TRAVEL_HEAL_AT` (well
	# above the old 0.35 that arrived at the chest as a corpse) and treats the
	# mini-boss as a hazard to break off from, not a body to walk through: the A*
	# prices the warden's whole engagement radius, and a leg that meets it in melee
	# while hurt retreats to safe ground, heals, and resumes. The chest and its
	# ledger are still earned by walking, picking up, opening, buying, selling and
	# equipping through real input — only the dying part changes.
	_travel_heal_at = ECONOMY_TRAVEL_HEAL_AT
	_avoid_boss_on_travel = true
	_boss_retreat_left = BOSS_RETREAT_BUDGET

	# The village's own first job is taken before anything else, and not as one
	# more lesson on the shelf: three wolves at the spawn edge, which this prep is
	# about to kill regardless, pay 60 gold, 50 xp and two health potions, and a
	# level in this game refills both pools outright. Runs that set out east on
	# the strength of the one starting potion arrived at the chest as a corpse,
	# and an economy scenario that dies on the road reports nothing about the
	# economy. The headman who writes the order lives in the village zone now and
	# the wolves it is worked on live at the forest spawn edge, so the job is
	# taken behind `VillageGate` and the purse is filled back out in the wild —
	# the route of this run is a crossing route: village for the order, forest
	# for the hunt, village for the turn-in and the till, forest for the chest,
	# village for the shop legs, and every crossing is a real ZoneExit.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_unreachable")
		return
	var edrik := _find_node("interactable")
	if edrik != null:
		await _travel_to(edrik.global_position, 18.0, 40.0)
		await _tap(&"interact")
		await _wait(0.5)
		await _dismiss_dialogue()
	# Back out through `ForestGate` for the sweep and the hunt: the walled
	# village holds nothing to kill and nothing to loot, and every leash below
	# is measured from the forest spawn the gate drops the hero onto.
	if not await _goto_zone("forest", SCENARIO_TIMEOUT):
		_notes.append("forest_unreachable")
		return

	# Prep is part of the economy lesson, not a cheat around it. First the
	# close finds are swept — a find across the map belongs to whatever
	# guards it, and the bot walks past both the eastern herb and the southern
	# coin. Then the pouch is filled the way the world fills it: wolves at the
	# spawn edge carry fangs, fangs carry gold at Yorek, and the kills carry
	# the xp that buys the level the east road actually asks for. A `collector`
	# hunts two more before setting the trap of its own trade.
	var sweep_limit := 3 if not bool(_pf("pickup_bias", false)) else 5
	var collected := 0
	while collected < sweep_limit:
		var loot := _nearest_pickup()
		if loot == null:
			break
		if loot.global_position.distance_to(_player_spawn()) < 240.0 \
				and not _near_boss(loot.global_position, 90.0):
			if await _travel_to(loot.global_position, 10.0, 30.0):
				collected += 1
			continue
		break
	_notes.append("prep_pickups=%d" % collected)
	var hunt_target := 4 if not bool(_pf("pickup_bias", false)) else 6
	var hunt_deadline := Engine.get_physics_frames() + _frames(75.0)
	var kills_at_start := _kill_total()
	while Engine.get_physics_frames() < hunt_deadline:
		# The job decides when the hunt is over, not a kill count picked in the
		# abstract: three wolves are what the village asked for, and the purse
		# wants a couple more on top of them.
		var quest_ready := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY
		if _kill_total() - kills_at_start >= (hunt_target if quest_ready else hunt_target + 2):
			break
		if _player_pos().distance_to(_player_spawn()) > 240.0:
			break
		var prey := _nearest_enemy()
		if prey == null or prey.is_in_group("boss") or _near_boss(prey.global_position, 110.0):
			break
		# The leash is measured from the spawn, not from the bot's own nose. From
		# the nose it ended the hunt before it began — the nearest wolf sat just
		# past the reach, the job never reached its turn-in state, and the run
		# went east on one potion and a five damage fist anyway.
		if prey.global_position.distance_to(_player_spawn()) > 340.0:
			break
		await _heal_if_hurt()
		var prey_d := _player_pos().distance_to(prey.global_position)
		bot_input.set_aim(prey.global_position)
		if prey_d > 20.0:
			await _move_step(prey.global_position)
		else:
			await _tap(&"attack")
			await _wait(0.1)
	bot_input.release_all()
	_notes.append("prep_hunts=%d" % (_kill_total() - kills_at_start))
	# The turn-in is what pays for the trip east, and it lands on a key press at
	# the same NPC who handed the job out. Counted before the purse is weighed so
	# the reward gold is part of the run's own money, never a write of the bot's.
	# The `edrik` the order was taken from was freed with the village the moment
	# the hero walked out through its gate, so the headman is looked up again on
	# the far side of this crossing rather than trusted from a stale reference.
	var quest_before := QuestManager.state_of(QUEST_ID)
	if quest_before == QuestManager.STATE_READY and await _goto_zone("village", SCENARIO_TIMEOUT):
		edrik = _find_node("interactable")
		if edrik != null:
			await _travel_to(edrik.global_position, 18.0, 45.0)
			await _tap(&"interact")
			await _wait(0.5)
			await _dismiss_dialogue()
	_notes.append("prep_quest=%s->%s" % [str(quest_before), str(QuestManager.state_of(QUEST_ID))])
	# The till stands in the village now, so the merchant is fetched on this side
	# of the door; a hunt that ended before the turn-in state leaves the hero in
	# the forest, and the crossing below answers for both cases with one call.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("prep_merchant_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	var merchant := _named("Yorek")
	if merchant == null:
		_notes.append("economy_actors_missing")
		return
	if not await _travel_to(merchant.global_position, 22.0, 120.0):
		_notes.append("prep_merchant_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	var prep_trade := ShopManager.new(GameState)
	var fangs := GameState.count_item("wolf_fang")
	var fang_price := prep_trade.sell_price("wolf_fang")
	var fangs_sold := 0
	var fang_gold_moved := 0
	if fangs > 0:
		var gold_pre_fangs := GameState.gold
		var fang_sale: Dictionary = prep_trade.sell("wolf_fang", fangs)
		if bool(fang_sale.get("ok", false)):
			fangs_sold = fangs
			fang_gold_moved = GameState.gold - gold_pre_fangs
	# The first exact-delta trade of the run, weighed at its own counter with no
	# walk in between: the whole fang stack leaves the bag and the merchant pays
	# his own published rate for every one of them.
	var fangs_exact := fangs_sold == 0 or (GameState.count_item("wolf_fang") == 0 \
			and fang_gold_moved == fangs_sold * fang_price)
	if GameState.gold >= 25:
		if await _open_merchant_shop(hud):
			await _tap(&"interact")
			await _wait(0.3)
			await _tap(&"pause")
			await _wait(0.3)
		elif GameState.ui_blocking:
			# Belt and braces: never carry an open greeting into the east walk,
			# where ui_blocking would hold the hero still and lose the chest leg.
			await _dismiss_dialogue()
	_notes.append("prep_done gold=%d potions=%d level=%d" % [
		GameState.gold, GameState.count_item("health_potion"), GameState.level])

	# The books open after the prep walk: every delta below is measured from
	# the state the trades themselves are supposed to move.
	var attack_before := GameState.total_attack()
	var potion_before := GameState.count_item("health_potion")
	var drunk_before := _potions_drunk
	var gold_before := GameState.gold
	var min_gold := GameState.gold

	# The chest sits in the far east corner of the forest, on the other side of
	# the village wall from the till the prep just left, so the east march starts
	# with a crossing back through `ForestGate`. The chest and the archer that
	# marks the road died with the forest at the first gate of this run, so both
	# are looked up again on this side rather than walked to by a stale reference.
	if not await _goto_zone("forest", SCENARIO_TIMEOUT):
		_notes.append("chest_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	chest = _named("Chest")
	if chest == null:
		_notes.append("economy_actors_missing")
		return
	# One straight pull across the whole map is the lane these runs keep losing:
	# the grid draws a line through the open heath beyond the archer's clearing,
	# and the walk then spends its entire budget sliding along a fence line it
	# cannot see, arriving at nothing with almost no damage taken. The road the
	# arena marches east is already proven run after run — spawn to the archer's
	# clearing, and only then the corner — so the crossing is taken in the same
	# two hops. A missed waypoint is not a failed run, it is only a missed
	# shortcut.
	var road_end := _named("ArcherA")
	if road_end != null:
		await _travel_to(road_end.global_position, 44.0, 120.0)
	if not await _travel_to(chest.global_position, 18.0, 200.0):
		_notes.append("chest_unreachable hp=%d taken=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type)])
		return
	# The chest is weighed on the frame it opens. The sword it holds has to
	# arrive exactly once, and the coin it holds has to be in the purse. The
	# coin bound is `>=` and not `==` because a swing still finishing on the way
	# in can pay a kill inside the same few frames, and that coin is the hero's
	# by right; the item delta, which nothing else in the world can move, is the
	# exact half of this check.
	var sword_before := GameState.count_item(String(chest.get("item_id")))
	var gold_at_chest := GameState.gold
	var chest_gold := int(chest.get("gold"))
	await _tap(&"interact")
	await _wait(0.3)
	var sword_ok := GameState.count_item("iron_sword") == 1
	var chest_exact := GameState.count_item("iron_sword") - sword_before == 1 \
			and GameState.gold - gold_at_chest >= chest_gold
	var gold_from_chest := GameState.gold - gold_before
	min_gold = mini(min_gold, GameState.gold)

	# The way back from the chest is the whole width of the forest to its west
	# gate and then the village road to the till, so this crossing gets the
	# widest budget of the run and the merchant is looked up once more on his
	# own side of the door.
	if not await _goto_zone("village", SCENARIO_TIMEOUT * 2.0):
		_notes.append("merchant_unreachable hp=%d taken=%s dealt=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type), _fmt_counts(_m_dmg_by_type)])
		return
	merchant = _named("Yorek")
	if merchant == null:
		_notes.append("economy_actors_missing")
		return
	if not await _travel_to(merchant.global_position, 22.0, 200.0):
		_notes.append("merchant_unreachable hp=%d taken=%s dealt=%s" % [
			GameState.hp, _fmt_counts(_m_taken_by_type), _fmt_counts(_m_dmg_by_type)])
		return
	var shop_open := await _open_merchant_shop(hud)
	# The till has to be proven open before a single coin is measured against it.
	# One key press at the end of a long walk is not proof: the merchant shares
	# the village square with three other villagers, and an interact that lands
	# on the wrong one opens a dialogue rather than a shop. The run then "bought"
	# a potion from a closed panel, reported the ledger as broken, and walked off
	# with a conversation still under the keyboard.
	var reopen := 0
	while not shop_open and reopen < 3:
		reopen += 1
		await _travel_to(merchant.global_position, 16.0, 35.0)
		shop_open = await _open_merchant_shop(hud)
	var shop := ShopManager.new(GameState)
	# Row 0 of the buy list is the merchant's first stock entry — the health
	# potion — and the cursor starts there every time the panel opens.
	# The road's fangs in the bag are the day's wages: they go to the merchant
	# through the same public sell entry before the panel purchase is measured,
	# so the buy leg tests the trade, not the bot's luck at counting gold.
	var road_fangs := GameState.count_item("wolf_fang")
	if road_fangs > 0:
		ShopManager.new(GameState).sell("wolf_fang", road_fangs)
	var potion_price := shop.buy_price("health_potion")
	var gold_pre_buy := GameState.gold
	var potion_pre_buy := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.3)
	var post_buy_gold := GameState.gold
	var post_buy_potions := GameState.count_item("health_potion")
	# Exact in both columns, and the price is read from the data rather than
	# retyped here: one potion into the bag, the merchant's own buy price out of
	# the purse, nothing else moved.
	var bought := post_buy_potions == potion_pre_buy + 1 \
		and post_buy_gold == gold_pre_buy - potion_price
	if not bought:
		_notes.append("buy_dbg open=%s pre=%d/%d post=%d/%d" % [
			str(shop_open), gold_pre_buy, potion_pre_buy,
			post_buy_gold, post_buy_potions])
	await _tap(&"pause")
	await _wait(0.3)
	var shop_closed := not bool(hud.call("is_shop_open"))
	min_gold = mini(min_gold, GameState.gold)

	# The sell leg through the shop's own public trade entry (see the note
	# above): same manager class, same rules, minus a key the bot has no way
	# to press through the input override.
	var sell_price := shop.sell_price("health_potion")
	var potions_pre_sell := GameState.count_item("health_potion")
	var gold_pre_sell := GameState.gold
	var sold: Dictionary = shop.sell("health_potion", 1)
	var sold_ok := bool(sold.get("ok", false)) \
		and GameState.count_item("health_potion") == potion_pre_buy
	var sell_exact := bool(sold.get("ok", false)) \
			and GameState.count_item("health_potion") == potions_pre_sell - 1 \
			and GameState.gold == gold_pre_sell + sell_price

	# The ledger is weighed at each counter, not against a bag total.
	#
	# The rule this replaces added the counted sips back to the closing count
	# and compared the sum with the count taken before the walk out to the
	# chest. It was wrong in a way worth writing down: the road between those
	# two readings is allowed to hand the hero potions. The herb and the coin
	# pouch lie on it, and a lumberjack carries a flask he leaves on the ground
	# three times out of ten. A find the world gave away is not a duplication by
	# the merchant, so the total drifted by exactly the loot nobody traded and a
	# healthy economy failed the scenario.
	#
	# What is actually under test is that no trade mints or eats something, and
	# a trade answers only for the delta across its own counter. Each leg below
	# is read on the frame it happens, with nothing but the trade between the
	# two readings, and each demands its exact delta: a whole fang stack for the
	# published rate, one sword out of one chest, one potion in for the buy
	# price, one potion out for the sell rate, and the sword still in the bag
	# once it is worn. The sips stay in the notes as what they are — the hero's
	# own spending, not the merchant's bookkeeping.
	var potions_after_trades := GameState.count_item("health_potion")
	var sips_under_way := _potions_drunk - drunk_before
	min_gold = mini(min_gold, GameState.gold)

	# Equip through the inventory panel: open it, walk the cursor to the sword
	# row the panel itself lists, press E, close it. The panel answers the same
	# InputSource the player uses, so this is the human equip path. The walk out
	# to the village's east road is deliberate: standing in a merchant's interact
	# radius while tapping keys invites his shop back under the panel, and the
	# lesson being measured here is the equip, not the door.
	# No panel may ride along under the keyboard into a walk. A leg asked to move
	# a hero who is still standing in a till spends its entire budget standing
	# still and comes back reporting a corner of the map nobody has ever failed
	# to reach. Esc is tried first because it is the key that shuts the shop;
	# only if something is still blocking does the bot fall back to advancing a
	# conversation, which is the one thing that must never be pressed at an open
	# till, since there it costs money.
	var unblock := 0
	while GameState.ui_blocking and unblock < 6:
		await _tap(&"pause")
		await _wait(0.2)
		if GameState.ui_blocking:
			await _tap(&"interact")
			await _wait(0.2)
		unblock += 1
	# What this leg is for is a step out of the merchant's own reach, so that is
	# what it proves. Chasing a pixel on the corner instead let the lane orbit
	# twenty-five pixels short of the tile until the budget ran out, while the
	# hero had long since been out of range of the till — the walk was reported
	# unreachable by a test of the wrong thing. The reach is read off the player's
	# own constant rather than repeated here, so a change to how close the hero
	# has to stand to talk cannot silently move this threshold. The authored east
	# road of the village is the till's own lane now: ten tiles of open dirt from
	# Yorek's post and four clear of `ForestGate`, so the panel is opened where
	# neither door nor till can steal a key press.
	var road_corner := _tile_center(Vector2i(34, 12))
	var reached_corner := await _travel_to(road_corner, 28.0, 60.0)
	var till_reach := float(load("res://scripts/player/player.gd")
		.get_script_constant_map().get("INTERACT_RADIUS", 26.0))
	var clear_of_till := _player_pos().distance_to(merchant.global_position) > till_reach
	if not reached_corner and not clear_of_till:
		# The note still says which of the two ways this leg fails: a hero still
		# standing in a till never moved, a hero who walked simply ran out of
		# road. Without the distance and the UI flag the two read the same.
		_notes.append("equip_walk_unreachable hp=%d ui=%s dist=%.0f till=%.0f taken=%s" % [
			GameState.hp, str(GameState.ui_blocking),
			_player_pos().distance_to(road_corner),
			_player_pos().distance_to(merchant.global_position),
			_fmt_counts(_m_taken_by_type)])
		return
	if not await _equip_via_inventory(hud, "Железный меч"):
		_notes.append("equip_ui_failed")
		return
	var attack_after := GameState.total_attack()
	var worn := String(GameState.equipped_slot_of("iron_sword"))

	# The collector's full bag goes back to the merchant it is already standing
	# next to; the threshold is the profile's own `merchant_stacks`.
	var unloaded := 0
	var stacks := int(_pf("merchant_stacks", 0))
	if stacks > 0 and _consumable_stacks() >= stacks:
		var trade := ShopManager.new(GameState)
		for slot in GameState.inventory.duplicate():
			var item_id := String(slot["id"])
			if not ItemDB.is_consumable(item_id):
				continue
			var result: Dictionary = trade.sell(item_id, GameState.count_item(item_id))
			if bool(result.get("ok", false)):
				unloaded += 1
		_notes.append("collector_unloaded=%d" % unloaded)

	_notes.append("chest_sword=%s chest_gold=%d" % [str(sword_ok), gold_from_chest])
	_notes.append("shop_open=%s bought=%s closed=%s sold=%s" % [
		str(shop_open), str(bought), str(shop_closed), str(sold_ok)])
	_notes.append("attack=%d->%d worn=%s" % [attack_before, attack_after, worn])
	_notes.append("potions=%d->%d gold=%d min_gold=%d" % [
		potion_before, GameState.count_item("health_potion"), GameState.gold, min_gold])
	var attack_ok := attack_after == attack_before + 6 and worn == "weapon"
	# Wearing the sword must not consume it. The same reading is what makes an
	# item unsellable while it is worn, so one look at the bag closes both rules.
	var equip_intact := GameState.count_item("iron_sword") == 1 and worn == "weapon"
	# Every term of the ledger is one transaction weighed at its own counter. A
	# term goes red only when a trade moved the wrong amount of item or of coin,
	# never because the road happened to hand out loot the merchant never touched.
	var ledger_balanced := fangs_exact and chest_exact and bought and sell_exact \
			and equip_intact
	_notes.append("ledger fangs=%s chest=%s buy=%s sell=%s equip=%s bag=%d sips=%d price=%d/%d" % [
		str(fangs_exact), str(chest_exact), str(bought), str(sell_exact),
		str(equip_intact), potions_after_trades, sips_under_way, potion_price, sell_price])
	# The verdict names its own terms. A FAIL used to print a row of trues and
	# leave whoever reads the tail to work out which of them the last line
	# disagreed with — which is how the ledger defect sat here unread for a run.
	var verdict := {
		"sword": sword_ok, "shop_open": shop_open, "bought": bought,
		"closed": shop_closed, "sold": sold_ok, "attack": attack_ok,
		"fangs": fangs_exact, "chest": chest_exact, "sell": sell_exact,
		"equip": equip_intact, "ledger": ledger_balanced,
		"gold_nonneg": min_gold >= 0, "alive": GameState.hp > 0,
	}
	var failed_terms: Array[String] = []
	for term: String in verdict:
		if not bool(verdict[term]):
			failed_terms.append(term)
	if failed_terms.is_empty():
		_notes.append("terms=all_pass")
	else:
		_notes.append("failed=%s" % ",".join(failed_terms))
	_result = "PASS" if failed_terms.is_empty() else "FAIL"


## BOT-006 — quest chain. The full arc on one quest: take it from Edrik, hunt
## the objective out in the world, walk back, turn it in, and talk to him once
## more. The turn-in must pay — gold, xp and any reward items land — and the
## repeat conversation must pay nothing at all: the reward-once rule is measured
## as a zero delta across the re-talk, not trusted from the quest state alone.
func _scenario_quest_chain() -> void:
	# Edrik lives in the village zone now and the wolves live in the forest, so
	# the arc is take → cross → hunt → cross → turn in, every crossing made
	# through a real ZoneExit gate rather than assumed. The first interactable
	# of the forest is the east chest, and a chain bot that mistook it for the
	# headman would hunt on a promise nobody made.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_unreachable")
		return
	var npc := _find_node("interactable")
	if npc == null:
		_notes.append("no_npc")
		return
	if not await _move_to(npc.global_position, 18.0, 45.0):
		_notes.append("npc_unreachable")
		return
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_ACTIVE:
		_notes.append("quest_not_started")
		return
	_notes.append("quest_taken")

	if not await _goto_zone("forest", SCENARIO_TIMEOUT):
		_notes.append("forest_unreachable")
		return

	var deadline := Engine.get_physics_frames() + _frames(SCENARIO_TIMEOUT * 2.2)
	var attacks := 0
	var abandoned: Dictionary = {}
	var cur_id := -1
	var cur_best := INF
	var stalled := 0
	while Engine.get_physics_frames() < deadline:
		if QuestManager.state_of(QUEST_ID) == QuestManager.STATE_READY:
			break
		if await _heal_if_hurt():
			pass
		_prune_abandoned(abandoned)
		var enemy := _nearest_quest_enemy(QUEST_ID, abandoned)
		if enemy == null:
			if not abandoned.is_empty():
				abandoned.clear()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			_notes.append("no_quest_targets")
			return
		var dist := _player_pos().distance_to(enemy.global_position)
		if dist > float(_profile["engage_range"]):
			var eid := enemy.get_instance_id()
			if eid != cur_id:
				cur_id = eid
				cur_best = dist
				stalled = 0
			elif dist < cur_best - 2.0:
				cur_best = dist
				stalled = 0
			else:
				stalled += 1
			if stalled > 120:
				abandoned[eid] = Engine.get_physics_frames()
				cur_id = -1
				cur_best = INF
				stalled = 0
				continue
			await _move_step(enemy.global_position)
			continue
		cur_id = -1
		cur_best = INF
		stalled = 0
		bot_input.set_aim(enemy.global_position)
		await _tap(&"attack")
		attacks += 1
		await _wait(0.22)
	_notes.append("attacks=%d" % attacks)
	if QuestManager.state_of(QUEST_ID) != QuestManager.STATE_READY:
		_notes.append("objective_not_met=%d/%d" % [
			QuestManager.progress_of(QUEST_ID), QuestManager.target_count(QUEST_ID)])
		return

	# The turn-in is at the headman's post in the village, and the `npc` the
	# chain took the order from was freed with the world it stood in at the
	# first crossing — the headman is looked up again after the gate.
	if not await _goto_zone("village", SCENARIO_TIMEOUT):
		_notes.append("village_return_unreachable")
		return
	npc = _find_node("interactable")
	if npc == null:
		_notes.append("no_npc_on_return")
		return
	if not await _move_to(npc.global_position, 18.0, 60.0):
		_notes.append("return_unreachable")
		return
	var gold_pre := GameState.gold
	var xp_pre := GameState.xp
	var potion_pre := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var turned_in := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	var reward_gold := GameState.gold - gold_pre
	var reward_xp := GameState.xp - xp_pre
	var reward_potion := GameState.count_item("health_potion") - potion_pre
	_notes.append("reward=gold+%d xp+%d potions+%d" % [reward_gold, reward_xp, reward_potion])

	# The re-talk: same NPC, same key, one more conversation. The quest is
	# already done, so this visit must change nothing about the player.
	var gold_retalk := GameState.gold
	var xp_retalk := GameState.xp
	var potion_retalk := GameState.count_item("health_potion")
	await _tap(&"interact")
	await _wait(0.8)
	await _dismiss_dialogue()
	var still_done := QuestManager.state_of(QUEST_ID) == QuestManager.STATE_DONE
	var paid_again := GameState.gold != gold_retalk or GameState.xp != xp_retalk \
		or GameState.count_item("health_potion") != potion_retalk
	_notes.append("retalk_state=%s paid_again=%s" % [
		QuestManager.state_of(QUEST_ID), str(paid_again)])
	_result = "PASS" if turned_in and reward_gold > 0 and reward_xp > 0 \
		and still_done and not paid_again and GameState.hp > 0 else "FAIL"


## BOT-007 — traps and secrets. Two honest proofs on the forest's own hazards,
## ordered so the bot spends as little standing time as possible in hostile
## country. The rubble first: the bot walks to the pile and smashes it with
## ordinary swings, and the shortcut flag must be the world's own doing — the
## bot never writes flags, it only reads the one `Breakable` raises when it
## falls. The spike trap second: the bot walks to a standoff just past its
## reach and watches the plate through a cycle (the telegraph is the plate's
## own public colour ramp, no private phase field is read), and only
## crosses onto the plate itself while it is healthy enough to afford the
## lesson. The scenario fails if the trap can hurt anyone it never warned
## (damage from out of reach, or damage with no warning ever seen).
func _scenario_traps() -> void:
	var trap := _named("Trap")
	var rubble := _named("Rubble")
	if trap == null or rubble == null:
		_notes.append("trap_or_rubble_missing")
		return
	_connect_combat_sensors()
	_m_trap_id = trap.get_instance_id()
	_m_trap_damage = 0
	var trap_pos: Vector2 = (trap as Node2D).global_position

	# Bank the road's potion before anything else: the profile heal rule can
	# only fire with a potion actually in the bag.
	var loot := _nearest_pickup()
	if loot != null:
		await _travel_to(loot.global_position, 8.0, 30.0)

	# The secret first — the long walk is the dangerous leg, and it is worth
	# making it with full HP.
	if not await _travel_to(rubble.global_position, 16.0, 110.0):
		_notes.append("rubble_unreachable hp=%d path=%d" % [
			GameState.hp, _find_path(_tile_of(_player_pos()), _tile_of(rubble.global_position)).size()])
		return
	var broke := false
	var swing_deadline := Engine.get_physics_frames() + _frames(45.0)
	while Engine.get_physics_frames() < swing_deadline:
		if not is_instance_valid(rubble) or bool(rubble.call("is_broken")):
			broke = true
			break
		var pile_threat := _nearest_enemy()
		if pile_threat != null and _player_pos().distance_to(pile_threat.global_position) < 18.0:
			bot_input.set_aim(pile_threat.global_position)
			await _tap(&"attack")
			await _wait(0.15)
			continue
		# The pile is a body, not a ghost: collision parks the player a few
		# pixels outside the swing if he only walks to the arrival ring. The
		# bot keeps pressing into the pile while he swings, so the hitbox is
		# always measured from touching distance.
		if _player_pos().distance_to(rubble.global_position) > 12.0:
			await _move_step(rubble.global_position)
		bot_input.set_aim(rubble.global_position)
		await _tap(&"attack")
		await _wait(0.25)
	if is_instance_valid(rubble):
		broke = bool(rubble.call("is_broken"))
	var flag_open := bool(GameState.get_flag("shortcut_forest_south_open", false))
	_notes.append("broke=%s shortcut_flag=%s hp=%d" % [
		str(broke), str(flag_open), GameState.hp])

	# The trap: the plate only runs its cycle while someone stands within its
	# attention, so the watch is taken from the standoff — 46 px out, past the
	# strike reach but inside the wake radius. The alpha of the plate is the
	# warning: idle sits at 0.35, the telegraph ramps past 0.5 into the 0.8
	# strike frame; seven seconds cover two full cycles (idle 0.8 + telegraph
	# 0.55 + active 0.18 + cooldown 1.6), and the watch ends the moment the
	# warning has been seen. Only the trap's own hits count — a wolf bite from
	# behind is not the plate's doing and must not poison the check.
	var watch_point := _standoff_point(trap_pos)
	# The watch sits in a corridor the forest patrols, and the first walk
	# there is the one that learns the bumps; a second walk runs on the map
	# the first one drew. Two tries, eighty seconds, same honest road.
	var reached_watch := await _travel_to(watch_point, 10.0, 80.0) \
		or await _travel_to(watch_point, 10.0, 80.0)
	if not reached_watch:
		_notes.append("trap_watch_unreachable")
		return
	var telegraph_seen := false
	var watch_deadline := Engine.get_physics_frames() + _frames(7.0)
	while Engine.get_physics_frames() < watch_deadline:
		var plate: ColorRect = trap.get("visual")
		if plate != null and plate.color.a > 0.5:
			telegraph_seen = true
			break
		var threat := _nearest_enemy()
		if threat != null and _player_pos().distance_to(threat.global_position) < 20.0:
			bot_input.set_aim(threat.global_position)
			await _tap(&"attack")
			await _wait(0.1)
		else:
			await _wait(0.1)
	bot_input.release_all()
	var damage_at_distance := _m_trap_damage
	_notes.append("telegraph_seen=%s trap_damage_at_distance=%d" % [
		str(telegraph_seen), damage_at_distance])

	# The crossing is taken only while healthy: standing on the plate proves
	# the trap is live, but the scenario's promise is about warning honesty,
	# and an avoided trap with a seen warning satisfies it too. A bot below
	# half HP skips the lesson and says so in the notes.
	var cross_damage := 0
	var on_plate := false
	if GameState.hp >= int(GameState.max_hp * 0.5):
		_m_trap_damage = 0
		on_plate = await _travel_to(trap_pos, 6.0, 30.0)
		cross_damage = _m_trap_damage
	else:
		_notes.append("plate_skipped_low_hp")
	_notes.append("on_plate=%s trap_damage_crossing=%d" % [str(on_plate), cross_damage])
	var trap_honest := telegraph_seen and damage_at_distance == 0 \
		and (cross_damage == 0 or telegraph_seen)
	_result = "PASS" if trap_honest and broke and flag_open and GameState.hp > 0 else "FAIL"


## BOT-012 — the descent, and the road back up it. The forest's supply run and the
## iron sword in its eastern chest, the gate at the end of the forest road, the key
## and the lever behind it, the stair down into the undercroft, two kinds of the
## things that live down there, one of the plates that guard the only two lanes the
## undercroft has — and then the whole route walked back to the forest, because a
## scenario that only ever goes down has never once proved that a zone line is
## something a hero can cross twice.
##
## Every leg is walked through the same `interact` a player uses and confirmed by the
## zone's own answer. Nothing here writes a zone, a position or an item: the bot
## arrives, knocks, and waits to be let in.
func _scenario_dungeon() -> void:
	_connect_combat_sensors()
	_set_control_watch(true)
	_a_melee = 0
	_a_walker_melee = 0
	_a_casts = 0
	_a_heals = 0
	_a_switches = 0
	_a_last_target = -1
	_a_broken = false
	_a_pick_spell()
	var deadline := Engine.get_physics_frames() + _frames(DUNGEON_TIMEOUT)
	var forest_rally := _player_spawn()

	# Supply first, for the same reason the arena takes it: the undercroft hands a
	# hero nothing, and a level-one fist walks into it exactly once.
	await _arena_prep(deadline)
	_wd_set_goal("dungeon_arm")
	await _arena_arm(deadline, forest_rally)

	var reached_dungeon := false
	var kinds_engaged := 0
	var trap := {}
	var back_in_forest := false
	_wd_set_goal("dungeon_gate")
	if await _zone_travel("RuinsGate", "ruins", deadline, forest_rally):
		var hall_rally := _named("ForestGate").global_position \
				if _named("ForestGate") != null else _player_pos()
		_wd_set_goal("dungeon_descent")
		if await _arena_open_ruins_door(deadline, hall_rally):
			if await _zone_travel("DungeonGate", "dungeon", deadline, hall_rally):
				reached_dungeon = true
				var undercroft_rally := _rally_point()
				_wd_set_goal("dungeon_fight")
				kinds_engaged = await _dungeon_engage_distinct(2, 70.0, deadline, undercroft_rally)
				_wd_set_goal("dungeon_traps")
				trap = await _dungeon_trap_lesson(deadline, undercroft_rally)
				# The way out is the way in. The door behind the lever stays open
				# because the world says it does (`ruin_door_open`), so the climb back
				# is a route, not a puzzle replayed.
				_wd_set_goal("road_home")
				if await _zone_travel("RuinsExit", "ruins", deadline, undercroft_rally):
					back_in_forest = await _zone_travel("ForestGate", "forest",
							deadline, _rally_point())
	_set_control_watch(false)
	bot_input.release_all()

	# The plate term is met when the bot watched a plate arm itself and paid nothing
	# for the privilege. It is also honestly met when this seed's undercroft has no
	# reachable ground to watch from at all — a fact about a generated map, said out
	# loud in the notes as `trap_skipped`, and not a warning that went unseen. What
	# it never accepts is silence read as success: a trap that was reachable, watched
	# from real ground, and hit the bot without arming first fails the run by name.
	var trap_skipped := bool(trap.get("skipped", false))
	var trap_met := bool(trap.get("found", false)) \
			and bool(trap.get("telegraph_seen", false)) \
			and int(trap.get("damage_at_distance", 0)) == 0 \
			and (int(trap.get("damage_crossing", 0)) == 0 or GameState.hp > 0)
	var trap_honest := trap_met or trap_skipped
	if trap_skipped:
		_notes.append("trap_skipped=no_reachable_watch_ground")
	_goal("reached_dungeon", reached_dungeon)
	_goal("two_dungeon_kinds", kinds_engaged >= 2)
	_goal("trap_honest", trap_honest)
	_goal("back_in_forest", back_in_forest)
	_goal("alive", GameState.hp > 0)
	_notes.append("kinds=%d dmg=%s kills=%s" % [
		kinds_engaged, _fmt_counts(_dungeon_blood()), _fmt_counts(_m_kills_by_type)])
	_notes.append("melee=%d (own=%d walker=%d) casts=%d heals=%d" % [
		_a_melee + _a_walker_melee, _a_melee, _a_walker_melee, _a_casts, _a_heals])
	_notes.append("max_control_ms=%d" % _a_max_control_ms)
	var verdict := {
		"reached_dungeon": reached_dungeon,
		"two_dungeon_kinds": kinds_engaged >= 2,
		"trap_honest": trap_honest,
		"back_in_forest": back_in_forest,
		"alive": GameState.hp > 0,
	}
	var failed_terms: Array[String] = []
	for term: String in verdict:
		if not bool(verdict[term]):
			failed_terms.append(term)
	_notes.append("criterion=%s" % DUNGEON_CRITERION)
	_notes.append("terms=all_pass" if failed_terms.is_empty()
			else "failed=%s" % ",".join(failed_terms))
	_result = "PASS" if failed_terms.is_empty() else "FAIL"


## BOT-013 — the fortress, and the King without a Crown. The longest road in the file
## and the only one that ends in a boss: three zone lines down and over, the spine of
## the fortress walked east the whole length of it, and the thing waiting at the end
## of that spine.
##
## The verdict stops at the phase 2 transition on purpose. The spec's §19.6 asks a
## boss scenario to prove the fight is survivable *through* the phase change, and the
## term that measures that is the boss's own `phase_changed(2)` — which needs 204 of
## the King's 600 HP spent first, on a hero who walked forty tiles to get there. What
## happens after that is the King's business; the scenario's business is that the
## hero was still standing, still swinging and still his own when the second phase
## began.
func _scenario_fortress() -> void:
	_connect_combat_sensors()
	_set_control_watch(true)
	_a_melee = 0
	_a_walker_melee = 0
	_a_casts = 0
	_a_heals = 0
	_a_switches = 0
	_a_last_target = -1
	_a_broken = false
	_a_pick_spell()
	var deadline := Engine.get_physics_frames() + _frames(FORTRESS_TIMEOUT)
	var forest_rally := _player_spawn()

	await _arena_prep(deadline)
	_wd_set_goal("fortress_arm")
	await _arena_arm(deadline, forest_rally)

	var reached_fortress := false
	var fight := {"found": false, "phase2": false, "outcome": "not_reached"}
	_wd_set_goal("fortress_gate")
	if await _zone_travel("RuinsGate", "ruins", deadline, forest_rally):
		var hall_rally := _named("ForestGate").global_position \
				if _named("ForestGate") != null else _player_pos()
		_wd_set_goal("fortress_descent")
		if await _arena_open_ruins_door(deadline, hall_rally):
			if await _zone_travel("DungeonGate", "dungeon", deadline, hall_rally):
				var undercroft_rally := _rally_point()
				_wd_set_goal("fortress_gate")
				if await _zone_travel("FortressGate", "fortress", deadline, undercroft_rally):
					reached_fortress = true
					_wd_set_goal("king_fight")
					fight = await _fortress_fight_king(deadline, _rally_point())
	_set_control_watch(false)
	bot_input.release_all()

	var king_engaged := int(_m_dmg_by_type.get("king_without_crown", 0)) > 0
	# `phase2` is the King's own signal, read off `phase_changed` — not an estimate
	# from a health bar. The hero does not have to finish the fight: he has to still
	# be in it, and swinging, when the second phase starts.
	var phase2 := bool(fight.get("phase2", false))
	var outcome := String(fight.get("outcome", ""))
	var survived := GameState.hp > 0
	# A death is legitimate when the world gave the hero back. It is a softlock when
	# it did not, and the difference between the two is the only thing this term is
	# about: dying to a boss is a story, dying and not coming back is a defect.
	var legitimate := survived or outcome.ends_with("respawned")
	_goal("reached_fortress", reached_fortress)
	_goal("king_engaged", king_engaged)
	_goal("phase2_seen", phase2)
	_goal("survived_or_legitimate_loss", legitimate)
	_notes.append("king dmg=%d phases=%s outcome=%s hp=%d" % [
		int(_m_dmg_by_type.get("king_without_crown", 0)),
		str(_king_phases), outcome, GameState.hp])
	_notes.append("melee=%d (own=%d walker=%d) casts=%d heals=%d" % [
		_a_melee + _a_walker_melee, _a_melee, _a_walker_melee, _a_casts, _a_heals])
	_notes.append("kills=%s" % _fmt_counts(_m_kills_by_type))
	_notes.append("max_control_ms=%d" % _a_max_control_ms)
	var verdict := {
		"reached_fortress": reached_fortress,
		"king_engaged": king_engaged,
		"phase2_seen": phase2,
		"survived_or_legitimate_loss": legitimate,
	}
	var failed_terms: Array[String] = []
	for term: String in verdict:
		if not bool(verdict[term]):
			failed_terms.append(term)
	_notes.append("criterion=%s" % FORTRESS_CRITERION)
	_notes.append("terms=all_pass" if failed_terms.is_empty()
			else "failed=%s" % ",".join(failed_terms))
	_result = "PASS" if failed_terms.is_empty() else "FAIL"


# --- helpers -----------------------------------------------------------------

func _player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D


## Delete every file the save manager keeps for a slot (primary, backup, temp),
## so a bot run never leaves residue a later run could mistake for its own save.
func _clear_save_slot(slot: int) -> void:
	var paths: Array[String] = [
		SaveManager.slot_path(slot),
		SaveManager.slot_backup_path(slot),
		SaveManager.slot_temp_path(slot),
	]
	for path in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _player_pos() -> Vector2:
	var p := _player()
	return p.global_position if p != null else Vector2.ZERO


## The clearing every run starts in — the yardstick for "a find close enough
## to be worth a walk".
func _player_spawn() -> Vector2:
	return Vector2(4 * TILE + TILE * 0.5, 9 * TILE + TILE * 0.5)


## Whether a point sits inside a boss's yard. The bot reads the same public
## "boss" group the HUD health frame and the map panel mark read, and treats
## the radius as a promise not to pick a fight it cannot pay for.
func _near_boss(pos: Vector2, radius: float) -> bool:
	for node in get_tree().get_nodes_in_group("boss"):
		if node is Node2D and is_instance_valid(node) \
				and pos.distance_to((node as Node2D).global_position) < radius:
			return true
	return false


## The nearest live boss, read off the same public "boss" group the HUD and the
## map mark. The walker uses it to decide whether the body crowding its lane is
## the one thing it must not trade blows with; a scenario that wants to fight its
## boss (BOT-013) never asks the walker to break from it, so this answers for the
## legs that opted into avoidance and nothing else.
func _nearest_boss() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	var me := _player_pos()
	for node in get_tree().get_nodes_in_group("boss"):
		var b := node as Node2D
		if b == null or not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		var d := me.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			best = b
	return best


## Break contact with a boss by walking back toward the ground the hero woke on,
## which is the direction that puts the boss's leash between the two of them: the
## warden turns back once it is `LEASH_RADIUS` from its post, and the hero heals on
## the safe ground past that line. Bounded by both the per-burst cap and whatever
## is left of the run's budget, and it stops early the moment the rally is reached,
## so a break is a pause to recover rather than a flight across the map. Real
## movement through the same input path the human uses — no teleport, no
## invulnerability — and a wall or a corner cuts the burst short on its own.
## Returns the seconds actually spent, so the caller can keep the run's ledger.
func _break_from_boss(rally: Vector2, budget: float) -> float:
	var cap := minf(BOSS_RETREAT_BURST, maxf(budget, 0.0))
	var started := Engine.get_physics_frames()
	var until := started + _frames(cap)
	while Engine.get_physics_frames() < until:
		if _player_pos().distance_to(rally) <= 40.0:
			break
		await _move_step(rally)
	bot_input.release_all()
	return float(Engine.get_physics_frames() - started) / 60.0


func _find_node(group: String) -> Node2D:
	var nodes := get_tree().get_nodes_in_group(group)
	if nodes.is_empty():
		return null
	return nodes[0] as Node2D


## Named world actor lookup: the forest builds Yorek, the trap and the rubble as
## direct children of `World` under fixed names, so a scenario can walk to one
## without hardcoding a tile. The world is resolved fresh off the scene root
## rather than from the cached `_world`, so the helper also answers when a test
## calls it before any cmdline start.
func _named(node_name: String) -> Node2D:
	var world := get_parent().get_node_or_null("World") as Node2D
	if world == null:
		world = _world as Node2D
	if world == null:
		return null
	return world.get_node_or_null(node_name) as Node2D


func _hud() -> CanvasLayer:
	return get_parent().get_node_or_null("HUD") as CanvasLayer


## One profile key with the pre-§19.5 behaviour as its default, so the four
## original profiles — which carry none of the new keys — keep running exactly
## the scenarios they always ran.
func _pf(key: String, fallback: Variant) -> Variant:
	return _profile.get(key, fallback)


## Whether the item the first quick slot points at is actually in the bag — the
## same pair of checks the HUD makes before it heals. The generic twin of the
## soak's own gate, for the scenarios that heal through the profile threshold.
func _has_potion() -> bool:
	var item_id := String(GameState.quick_slot_item(0))
	return item_id != "" and GameState.count_item(item_id) > 0


## Heal through the real quick slot when the profile threshold is crossed and a
## potion exists to spend. Reports whether it tapped, so a scenario can count
## its support actions without guessing.
func _heal_if_hurt(threshold: float = -1.0) -> bool:
	var heal_at := threshold if threshold > 0.0 else float(_profile.get("heal_at", 0.5))
	if GameState.hp >= int(GameState.max_hp * heal_at):
		return false
	if _has_potion():
		var potions_before_sip := GameState.count_item("health_potion")
		await _tap(&"quick_slot_1")
		await _wait(0.2)
		if GameState.count_item("health_potion") < potions_before_sip:
			_potions_drunk += 1
			return true
		return false
	# No potion in the bag: the impulse every hero knows from the first minute
	# is the second heal a human reaches for. Same public cast path as any
	# other skill — select, tap, mana paid — and the selection is handed back
	# so a scenario's own ability plan is not disturbed by the bot's medicine.
	# Profiles that refuse abilities (`novice`) refuse this medicine too.
	if not bool(_pf("use_ability", true)):
		return false
	if not GameState.known_skills.has("heal_impulse"):
		return false
	var impulse := SkillDB.get_skill("heal_impulse")
	var cost := int(impulse.get("mana", 0))
	if impulse.is_empty() or GameState.mana < cost:
		return false
	var previous := String(GameState.selected_skill)
	if not GameState.select_skill("heal_impulse"):
		return false
	var mana_before := GameState.mana
	await _tap(&"ability")
	var healed := GameState.mana == mana_before - cost
	GameState.select_skill(previous)
	await _wait(0.2)
	return healed


## Walk away from a threat for a bounded burst through the real movement
## actions. The generic counterpart of the soak's disengage, for profiles that
## break off on their own terms (`retreat_below`).
func _retreat_burst(threat: Vector2, seconds: float) -> void:
	var away := _player_pos() - threat
	away = away.normalized() if away != Vector2.ZERO else Vector2.UP
	var until := Engine.get_physics_frames() + _frames(seconds)
	while Engine.get_physics_frames() < until:
		bot_input.hold(&"move_right", away.x > 0.35)
		bot_input.hold(&"move_left", away.x < -0.35)
		bot_input.hold(&"move_down", away.y > 0.35)
		bot_input.hold(&"move_up", away.y < -0.35)
		bot_input.set_aim(threat)
		await get_tree().physics_frame
	bot_input.release_all()


func _nearest_pickup() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("pickup"):
		var p := n as Node2D
		if p == null or not is_instance_valid(p):
			continue
		var d := me.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	return best


## Whether the selected skill is castable right now as far as the mana pool is
## concerned. The cooldown itself stays the player's own gate — a tap that hits
## one simply spends nothing, which is exactly what BOT-004 measures.
func _mana_ready() -> bool:
	var skill := SkillDB.get_skill(GameState.selected_skill)
	if skill.is_empty():
		return false
	return GameState.mana >= int(skill.get("mana", 0))


## Whether a control status (stun, root, shock) currently owns the player. Read
## from his own StatusComponent's public `effects`, the same dictionary the DoT
## ticks and the movement multiplier are computed from.
func _player_is_controlled() -> bool:
	var p := _player()
	if p == null:
		return false
	var comp := p.get_node_or_null("StatusComponent")
	if comp == null:
		return false
	var effects: Dictionary = comp.get("effects")
	for control_status in ["stun", "root", "shock"]:
		if effects.has(control_status):
			return true
	return false


func _fmt_counts(counts: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in counts:
		parts.append("%s:%d" % [key, int(counts[key])])
	return ",".join(parts)


## How many inventory slots hold a consumable — the bag size a collector is
## willing to carry before it hauls the goods back to the merchant.
func _consumable_stacks() -> int:
	var stacks := 0
	for slot in GameState.inventory:
		if ItemDB.is_consumable(String(slot["id"])):
			stacks += 1
	return stacks


## Tile edge of the zone grids. The zones never publish the number, but every
## one of them places actors at `tile * 16 + 8`, and the map panel and the test
## suite make the same assumption, so the bot reads tiles the same way.
const TILE := 16.0


func _tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))


func _tile_center(tile: Vector2i) -> Vector2:
	return Vector2(tile.x * TILE + TILE * 0.5, tile.y * TILE + TILE * 0.5)


## A point to watch a hazard from: the first of eight standoffs around `center`
## (46 px, just past any trap reach) that sits on ground the zone calls
## walkable. The bot observes from real ground it can actually be walked to,
## never from a tile inside a tree line.
func _standoff_point(center: Vector2) -> Vector2:
	for offset in [
		Vector2(46, 0), Vector2(-46, 0), Vector2(0, 46), Vector2(0, -46),
		Vector2(40, 40), Vector2(-40, 40), Vector2(40, -40), Vector2(-40, -40),
	]:
		var candidate: Vector2 = center + offset
		if _walkable(_tile_of(candidate)):
			return candidate
	return center + Vector2(46, 0)


## The nearest plate the bot can actually get a sight of, and the ground it has to
## stand on to do it. Two things the undercroft refuses a fixed rule: it is
## generated per seed, so a standoff ring at one radius may land in a pillar, and
## a tile the grid calls ground is not necessarily ground the hero can be walked
## to. So every candidate is filtered by the planner itself — a watch point with
## no route to it is not a cautious vantage, it is the reason a run spends its
## whole budget pushing its shoulder into a wall.
func _reachable_standoff(trap_nodes: Array) -> Dictionary:
	var here := _tile_of(_player_pos())
	var best: Dictionary = {}
	var best_cost := 1.0e9
	for trap in trap_nodes:
		if not (trap is Node2D):
			continue
		var trap_pos: Vector2 = (trap as Node2D).global_position
		for ring in [46.0, 64.0, 84.0]:
			for unit in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
					Vector2(0.71, 0.71), Vector2(-0.71, 0.71), Vector2(0.71, -0.71),
					Vector2(-0.71, -0.71)]:
				var candidate: Vector2 = trap_pos + unit * ring
				var tile := _tile_of(candidate)
				if not _walkable(tile, true):
					continue
				var route := _find_path(here, tile, true, false)
				if route.is_empty():
					continue
				var cost := route.size() * 2 + int(_player_pos().distance_to(candidate) / 32.0)
				if cost < best_cost:
					best_cost = cost
					best = {"trap": trap, "point": candidate}
	return best


## The nearest tile the zone itself calls ground, scanning outward from `anchor`
## in rings. A `ZoneExit` is placed by the world, and a world that could not find
## floor at its anchor parks the node on the wall it wanted to be standing on:
## `ZoneExit` still answers an interact from 26 px away, but no route exists to a
## wall tile, so a bot that walks at the node's own position is walking at a
## column. The bot aims at the closest real ground instead, which is where a
## player would actually be standing to use the exit.
func _nearest_walkable_tile(anchor: Vector2i, radius: int) -> Vector2i:
	if _walkable(anchor, true):
		return anchor
	for ring in range(1, radius + 1):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var t := Vector2i(anchor.x + dx, anchor.y + dy)
				if _walkable(t, true):
					return t
	return anchor


## Whether a tile is ground the player can stand on, read from the zone's own
## public `cell_at` — the same character grid the map panel draws and the test
## suite walks. A world without that API (or a tile off the grid) reads as
## blocked, and the caller falls back to its straight-line steering.
func _walkable(tile: Vector2i, ignore_bumped := false) -> bool:
	if not ignore_bumped and _bumped.has(tile):
		return false
	var world := get_parent().get_node_or_null("World")
	if world == null or not world.has_method("cell_at"):
		return false
	var cell := String(world.call("cell_at", tile))
	return cell == "." or cell == ","


## A* over the zone's walkable grid, eight-directional with no corner cutting
## (a diagonal needs both neighbouring straights open, so the path never
## threads a tree line). The grid is at most 52x32, so the open list is a plain
## scanned array — the whole search is microseconds and changes no world state:
## the bot reads the map the way a player with the map panel reads it, then
## still walks every step through the real input path.
func _find_path(from_tile: Vector2i, to_tile: Vector2i, ignore_bumped := false,
		avoid_threats := true) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var world := get_parent().get_node_or_null("World")
	if world == null or not world.has_method("cell_at"):
		return path
	var grid: Variant = world.call("map_size")
	if not (grid is Vector2i):
		return path
	var size := grid as Vector2i
	if to_tile != from_tile and not _walkable(to_tile, ignore_bumped):
		return path
	var in_bounds := func(t: Vector2i) -> bool:
		return t.x >= 0 and t.y >= 0 and t.x < size.x and t.y < size.y
	if not in_bounds.call(from_tile) or not in_bounds.call(to_tile):
		return path
	var open_list: Array[Vector2i] = [from_tile]
	var came_from: Dictionary = {}
	var closed: Dictionary = {}
	var cost: Dictionary = {from_tile: 0}
	var steps := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var heuristic := func(t: Vector2i) -> int:
		return maxi(absi(t.x - to_tile.x), absi(t.y - to_tile.y))
	# Soft avoidance: a player who can see a pack bedded down in the clearing
	# takes the field at an angle instead of walking through the middle of it.
	# The penalty is perception-based (live enemy positions only) and never
	# hard — a road through camp is still walkable, just more expensive than
	# the treeline around it.
	var threat_points: Array = []
	# `avoid_threats` is off for a long leg through a zone the hero intends to cross
	# end to end: the penalty is computed from where enemies are standing *right
	# now*, and in a crowded undercroft they walk toward the hero while he walks, so
	# every re-plan prices a different route and the lane flips between two of them.
	# A player crossing a monster hall does not re-decide his road every ten steps.
	if avoid_threats:
		for node in get_tree().get_nodes_in_group("enemies"):
			if node is Node2D and not node.is_queued_for_deletion():
				threat_points.append([(node as Node2D).global_position, 1])
		for node in get_tree().get_nodes_in_group("boss"):
			if node is Node2D and not node.is_queued_for_deletion():
				threat_points.append([(node as Node2D).global_position, 6])
	var threat_penalty := func(t: Vector2i) -> int:
		if threat_points.is_empty():
			return 0
		var center := _tile_center(t)
		var penalty := 0
		for entry in threat_points:
			var d: float = (entry[0] as Vector2).distance_to(center)
			var weight := int(entry[1])
			if weight > 1 and _avoid_boss_on_travel:
				# A boss is priced across its whole engagement radius
				# (`BOSS_AVOID_RADIUS`), not just the 96 px it can be hit from: a
				# lane that can skirt the warden's yard takes the field at an
				# angle, and only a goal that genuinely sits inside the yard pulls
				# the lane back in. The outer ring is a nudge, the inner ring a
				# strong disincentive, so the detour is cheaper than the direct
				# road but a chest standing in the yard is still reachable. This
				# wider band is gated on the leg opting in (`_avoid_boss_on_travel`,
				# set only by BOT-005's crossing): a scenario that exists to walk
				# into its boss (BOT-013) and the arena legs must price the boss
				# exactly as before, or this routing change would quietly move
				# their whole route and the arrival it lands them on.
				if d < 56.0:
					penalty += 40 * weight
				elif d < BOSS_AVOID_RADIUS:
					penalty += 6 * weight
			elif d < 56.0:
				penalty += 40 * weight
			elif d < 96.0:
				penalty += 12 * weight
		return penalty
	var f_score := {from_tile: heuristic.call(from_tile)}
	var guard := 0
	# Two things a plain open-list scan needs and did not have. The closed set is
	# what makes each tile expand once instead of once per improvement — without
	# it the same corridor tile is popped again and again, and the budget below
	# burns on re-work rather than on ground. The budget is derived from the grid
	# instead of fixed: a ceiling that fits the forest's open clearings does not
	# fit a lane that has to wind the whole width of the undercroft to reach the
	# stair, and running out of budget returns an empty path. An empty path is not
	# the world saying «there is no route»; it is the search giving up, and the
	# walker reads it as a wall — which is how a run spent eight minutes walking
	# into the side of a room it could have left.
	var search_budget := maxi(4096, size.x * size.y * 4)
	while not open_list.is_empty() and guard < search_budget:
		guard += 1
		var best_index := 0
		for i in range(1, open_list.size()):
			if int(f_score[open_list[i]]) < int(f_score[open_list[best_index]]):
				best_index = i
		var current: Vector2i = open_list[best_index]
		open_list.remove_at(best_index)
		if closed.has(current):
			continue
		closed[current] = true
		if current == to_tile:
			var node := current
			while came_from.has(node):
				path.push_front(node)
				node = came_from[node]
			return path
		for step in steps:
			var next_tile: Vector2i = current + step
			if not in_bounds.call(next_tile) or not _walkable(next_tile, ignore_bumped):
				continue
			if step.x != 0 and step.y != 0:
				if not _walkable(current + Vector2i(step.x, 0), ignore_bumped) \
						or not _walkable(current + Vector2i(0, step.y), ignore_bumped):
					continue
			var step_cost := 14 if (step.x != 0 and step.y != 0) else 10
			var via: int = int(cost[current]) + step_cost + int(threat_penalty.call(next_tile))
			if via < int(cost.get(next_tile, 1 << 30)):
				came_from[next_tile] = current
				cost[next_tile] = via
				f_score[next_tile] = via + heuristic.call(next_tile)
				if not next_tile in open_list:
					open_list.append(next_tile)
	return []


## A long leg with a real route and self-defence. The route is A* over the
## zone's own walkable grid; each waypoint is walked with the same movement
## actions every other scenario uses, and the path is recomputed when the bot
## stops making progress (a wolf body-blocking the lane is a legitimate reason
## to re-route). Anything that closes inside 30 px gets answered with the
## sword instead of being walked past into a fight later. If the grid cannot
## answer at all, the leg degrades to the old straight-line steering with the
## obstacle slide, so a world without `cell_at` is still walkable.
func _travel_to(target: Vector2, arrive: float, timeout: float, avoid_threats := true) -> bool:
	var deadline := Engine.get_physics_frames() + _frames(timeout)
	var origin := _tile_of(_player_pos())
	var dest := _tile_of(target)
	var path := _find_path(origin, dest, false, avoid_threats)
	if path.is_empty():
		# Bump memory from an earlier leg can wall off the only corridor; a
		# second read that ignores it distinguishes "the world has no route"
		# from "the bot already bruised a corner on the way".
		path = _find_path(origin, dest, true, avoid_threats)
		# And when it is the second read that finds the route, the memory was
		# wrong rather than merely cautious. Carrying it down the rest of the run
		# is the bot forgetting the map it is walking on, so it is dropped here
		# instead of being worked around on every later leg.
		if not path.is_empty():
			_bumped.clear()
	var leg := 0
	var stuck := 0
	var no_gain := 0
	var best_waypoint_dist := INF
	var repath_cooldown := 0
	var last_stall_pos := Vector2(-1.0e6, -1.0e6)
	var straight_only := path.is_empty()
	var last_pos := _player_pos()
	# A stall against ground the grid says is walkable is usually the hero's
	# shoulder on a wall corner, not a wall — see `_recenter_in_tile`. The two
	# counters below let him square up and try the same step again before the
	# tile is charged as a real nubbin and learned.
	var recenter_spot := Vector2(-1.0e6, -1.0e6)
	var recenter_tries := 0
	# A lane fought at arm's length for the whole budget is the one way a walk can
	# spend ten minutes without moving an inch: the swing branch below never
	# presses a movement key, so an opponent that is neither dying nor stepping
	# back holds the leg in place while the stuck counter climbs, resets on the
	# repath, and climbs again. The counter is per opponent on purpose — a lane
	# with three wolves should still fight all three.
	var swing_target: Node = null
	var swings := 0
	var dodged: Dictionary = {}
	while Engine.get_physics_frames() < deadline:
		if GameState.hp <= 0:
			bot_input.release_all()
			return false
		var pos := _player_pos()
		if pos.distance_to(target) <= arrive:
			bot_input.release_all()
			return true
		await _heal_if_hurt(_travel_heal_at)
		# A mini-boss is a hazard to route around, not a body to walk through on the
		# way to a goal. When a leg that has opted into boss avoidance finds a boss
		# in its melee and is hurt enough that trading blows would be the last thing
		# it does, it breaks contact back toward the ground it woke on — the one
		# direction that puts the boss's own leash between the two of them — heals on
		# safe ground, and resumes. Bounded by the run's budget so this is a pause to
		# recover, never a permanent kite: once the budget is spent the lane is walked
		# again and the bot fights or dies on its own terms. The boss is never the
		# thing this attacks; it is only ever walked away from.
		if _avoid_boss_on_travel and _boss_retreat_left > 0.0 \
				and GameState.hp < int(GameState.max_hp * BOSS_RETREAT_HEAL_BELOW):
			var boss := _nearest_boss()
			if boss != null and pos.distance_to(boss.global_position) < BOSS_RETREAT_MELEE_RANGE:
				_boss_retreat_left -= await _break_from_boss(_rally_point(), _boss_retreat_left)
				await _heal_if_hurt(_travel_heal_at)
				continue
		# Out of medicine and bleeding out: a human breaks off for a moment,
		# even mid-errand. The burst is short by design — the lane is resumed
		# before the whole map notices the bot is walking.
		var retreat_below := float(_pf("retreat_below", 0.0))
		if retreat_below > 0.0 \
				and GameState.hp <= int(GameState.max_hp * retreat_below) \
				and not _has_potion() and GameState.mana < 12:
			var menace := _nearest_enemy()
			if menace != null and pos.distance_to(menace.global_position) < 90.0:
				await _retreat_burst(menace.global_position, 1.5)
				continue
		var waypoint := target
		if not straight_only and leg < path.size():
			waypoint = _tile_center(path[leg])
			if pos.distance_to(waypoint) < 7.0:
				leg += 1
				continue
		var enemy := _nearest_enemy()
		if enemy != null and not enemy.is_in_group("boss") \
				and not dodged.has(enemy.get_instance_id()):
			var edist := pos.distance_to(enemy.global_position)
			if edist <= 22.0:
				swings = swings + 1 if swing_target == enemy else 1
				swing_target = enemy
				if swings > 8:
					# Eight swings that neither killed it nor moved it: the bot is
					# not losing this fight, it is being held. Step around it and
					# let the lane decide whether it was worth the trip.
					dodged[enemy.get_instance_id()] = true
					swings = 0
					continue
				bot_input.set_aim(enemy.global_position)
				await _tap(&"attack")
				# The walker's own swing, counted so an arena leg that clears a
				# lane on the way to a role can still say honestly how many
				# times the bot hit something in melee.
				_a_walker_melee += 1
				await _wait(0.1)
				continue
			# A shooter at bowshot ahead on the lane keeps shooting for the
			# rest of the leg; a human turns and closes. The close is taken
			# only downrange of the waypoint — a kiter that drags the lane
			# into the wilderness is a worse fight than the chips it throws.
			elif edist < 55.0 and (waypoint - pos).length() > 1.0:
				var ahead := (waypoint - pos).normalized()
				var to_enemy := (enemy.global_position - pos).normalized()
				if ahead.dot(to_enemy) > 0.35:
					bot_input.set_aim(enemy.global_position)
					await _move_step(enemy.global_position)
					continue
		if pos.distance_to(last_pos) < 0.35:
			stuck += 1
		else:
			stuck = 0
			last_pos = pos
		# Sliding along an invisible fence counts as movement, so a plain
		# stuck timer never fires on it. The other half of bump learning is
		# therefore progress-based: if the waypoint is no closer than it was
		# a moment ago, the lane is walking into something the grid cannot
		# see, and the tile under the push joins the wall memory just the
		# same.
		var wd := pos.distance_to(waypoint)
		if wd < best_waypoint_dist - 3.0:
			best_waypoint_dist = wd
			no_gain = 0
		else:
			no_gain += 1
		if repath_cooldown > 0:
			repath_cooldown -= 1
		if (stuck >= 10 or no_gain >= 45) and repath_cooldown == 0:
			var repeat_stall := pos.distance_to(last_stall_pos) < 28.0
			stuck = 0
			no_gain = 0
			best_waypoint_dist = INF
			last_stall_pos = pos
			repath_cooldown = 40
			# A panel left open reads to this loop as terrain. The hero stops
			# taking input entirely while a modal owns the keyboard, so the
			# position repeats to the last decimal, every repath finds a route,
			# and nothing moves: the trace of one such run is a hero standing at
			# the same float for nine minutes in the middle of an open corridor.
			# Esc is the only key tried, and it is tried twice so that a first tap
			# which merely opened the pause menu is undone by the second. `interact`
			# is never pressed here: at a till it spends the player's money, and a
			# debug bot has no business doing that to get its own footing back.
			if GameState.ui_blocking:
				await _tap(&"pause")
				await _wait(0.2)
				if GameState.ui_blocking:
					await _tap(&"pause")
					await _wait(0.2)
				_notes.append("leg_ui_stuck=%s" % str(GameState.ui_blocking))
			# A tile the grid calls ground that still refuses the step is, more
			# often than not, the hero arriving at a doorway off-centre — low in
			# the tile after coming up a corridor — so his shoulder catches the
			# corner of the wall beside the opening and the straight step will
			# not go through. That is a squeeze, not a wall, and charging it to
			# the bump memory is what turned a three-pixel corner into a reroute
			# away from the door and a bot oscillating between the two. A person
			# squares up in the doorway and goes again; the recenter below does
			# the same. Only after two squares still refuse the tile is it
			# treated as the invisible nubbin the bump memory exists for.
			if repeat_stall and _walkable(_tile_of(waypoint), true) \
					and _bumped.size() < 60 and recenter_tries < 2:
				if pos.distance_to(recenter_spot) < 28.0:
					recenter_tries += 1
				else:
					recenter_tries = 1
				recenter_spot = pos
				await _recenter_in_tile()
				continue
			# Learning a wall is reserved for a spot that refuses the bot
			# twice — sliding a corner or orbiting a waypoint is steering
			# noise, and a memory that fills with fake walls is the bot
			# forgetting the map. A target whose own body refuses the last
			# pixels is likewise not a wall, and the dictionary is capped so
			# one bad evening cannot re-draw the whole zone.
			if repeat_stall and pos.distance_to(target) > 24.0 \
					and _bumped.size() < 60:
				_learn_bump(pos, waypoint, dest)
			var repath := _find_path(_tile_of(pos), _tile_of(target), false, avoid_threats)
			if repath.is_empty():
				repath = _find_path(_tile_of(pos), _tile_of(target), true, avoid_threats)
				if not repath.is_empty():
					_bumped.clear()
			if repath.is_empty():
				straight_only = true
			else:
				path = repath
				leg = 0
				straight_only = false
		elif straight_only and repath_cooldown == 0 \
				and Engine.get_physics_frames() % 90 < 2:
			# Sliding along a tree line counts as progress, so the stuck timer
			# never fires; ask the grid again on a slow tick in case a route
			# exists that the straight-line steering cannot see around.
			var retry := _find_path(_tile_of(pos), _tile_of(target), true, avoid_threats)
			if not retry.is_empty():
				path = retry
				leg = 0
				straight_only = false
				repath_cooldown = 40
		if OS.get_environment("PEPEL_BOT_DEBUG") != "" \
				and Engine.get_physics_frames() % 120 == 0:
			print("[travel] pos=%s leg=%d/%d stuck=%d straight=%s ui=%s paused=%s" % [
				str(pos), leg, path.size(), stuck, str(straight_only),
				str(GameState.ui_blocking), str(get_tree().paused)])
		await _move_step(waypoint)
	bot_input.release_all()
	return false


## Lift the hero clear of a wall corner he is pressing his shoulder into.
## The grid calls the tile ahead ground and the step is legal, but a body
## that arrived off-centre — low in the tile after coming up a corridor —
## catches the corner of the wall beside the doorway and cannot make the
## straight step. Pressing back to the centre of the tile he stands on
## moves the body off that corner, the way a person squares up before
## squeezing past a doorframe, and the step then goes through. The tile is
## real ground, so this is deliberately not recorded as a wall.
func _recenter_in_tile() -> void:
	var center := _tile_center(_tile_of(_player_pos()))
	for _i in range(10):
		if _player_pos().distance_to(center) <= 1.5:
			break
		await _move_step(center)
	bot_input.release_all()


## How many live enemies sit within `radius` of the player. The arena reads
## this to tell a duel from a pile-up.
func _nearby_count(radius: float) -> int:
	var here := _player_pos()
	var count := 0
	for node in get_tree().get_nodes_in_group("enemy"):
		var e := node as Node2D
		if e != null and is_instance_valid(e) and e.global_position.distance_to(here) < radius:
			count += 1
	return count


## The ring-closing alarm: three muzzles inside fifty pixels is where the
## arena stops being a fight and becomes a feeding.
func _crowded() -> bool:
	return _nearby_count(50.0) >= 3


## Kills counted by the combat sensor since it was connected, summed over all
## enemy types — the hunt legs need a number, not a per-type breakdown.
func _kill_total() -> int:
	var total := 0
	for key: String in _m_kills_by_type:
		total += int(_m_kills_by_type[key])
	return total


## Remember a tile that physically refused the bot. The tile pushed into (the
## dominant axis of the push, then the secondary axis on a repeat bump at the
## same corner) joins `_bumped`, and every later route on this run treats it
## as wall. This is the bot's own bump-and-detour learning: it reads no
## collision data, it just stops walking into the same corner twice. The
## destination tile is never remembered as wall — standing against a merchant
## who is wider than the arrival radius is a tight squeeze, not a dead end.
func _learn_bump(pos: Vector2, waypoint: Vector2, dest := Vector2i(0x600D, 0x600D)) -> void:
	var dir := waypoint - pos
	var here := _tile_of(pos)
	var primary := Vector2i.ZERO
	var secondary := Vector2i.ZERO
	if absf(dir.x) >= absf(dir.y):
		if dir.x != 0.0:
			primary = Vector2i(signi(dir.x), 0)
		if dir.y != 0.0:
			secondary = Vector2i(0, signi(dir.y))
	else:
		if dir.y != 0.0:
			primary = Vector2i(0, signi(dir.y))
		if dir.x != 0.0:
			secondary = Vector2i(signi(dir.x), 0)
	if primary != Vector2i.ZERO and here + primary != dest:
		_bumped[here + primary] = true
	if secondary != Vector2i.ZERO and here + secondary != dest \
			and absf(dir.x) > 1.0 and absf(dir.y) > 1.0:
		# A diagonal push that stopped lost to one of the two straights; the
		# bot cannot tell which, so it remembers both and lets the next A*
		# pick the gap that is really open.
		_bumped[here + secondary] = true


## Equip through the inventory panel exactly as a human does: open it, read the
## rows the panel itself publishes, walk the cursor with the movement actions
## to the row naming `row_part`, press the interact key, close it. The panel
## answers the same InputSource the player does, so no state is written here —
## the equip happens inside the panel's own handler.
func _equip_via_inventory(hud: CanvasLayer, row_part: String) -> bool:
	await _tap(&"inventory")
	await _wait(0.3)
	if not bool(hud.call("is_inventory_open")):
		await _tap(&"inventory")
		await _wait(0.3)
	var rows: PackedStringArray = hud.call("inventory_row_texts")
	var index := -1
	for i in range(rows.size()):
		if rows[i].contains(row_part):
			index = i
			break
	if index < 0:
		await _tap(&"inventory")
		await _wait(0.2)
		return false
	# The panel keeps the cursor where the last session left it — opening is
	# not resetting — so the walk to the row starts from the row the panel
	# itself reports as selected, in the right direction, not blindly down
	# from an imagined zero.
	var sel := int(hud.call("inventory_selection"))
	var steps := index - sel
	for i in range(absi(steps)):
		await _tap(&"move_down" if steps > 0 else &"move_up")
	await _wait(0.15)
	await _tap(&"interact")
	await _wait(0.3)
	await _tap(&"inventory")
	await _wait(0.3)
	return true


func _connect_combat_sensors() -> void:
	if _m_sensors_connected:
		return
	EventBus.damage_dealt.connect(_on_m_damage)
	EventBus.enemy_died.connect(_on_m_enemy_died)
	EventBus.status_applied.connect(_on_m_status)
	_m_sensors_connected = true


func _disconnect_combat_sensors() -> void:
	if not _m_sensors_connected:
		return
	EventBus.damage_dealt.disconnect(_on_m_damage)
	EventBus.enemy_died.disconnect(_on_m_enemy_died)
	EventBus.status_applied.disconnect(_on_m_status)
	_m_sensors_connected = false


func _on_m_damage(payload: Dictionary) -> void:
	if not bool(payload.get("applied", false)):
		return
	# The trap's own victim is the player, who is not in the "enemy" group, so
	# the trap tally is taken off the attacker id before the enemy-target pass.
	if _m_trap_id != -1 and int(payload.get("attacker_id", 0)) == _m_trap_id:
		_m_trap_damage += int(payload.get("final_damage", 0))
	var node: Node = instance_from_id(int(payload.get("target_id", 0))) as Node
	if node != null and is_instance_valid(node) and node.is_in_group("player"):
		var attacker: Node = instance_from_id(int(payload.get("attacker_id", 0))) as Node
		if attacker != null and is_instance_valid(attacker) and attacker.is_in_group("enemy"):
			var atype := String(attacker.get("enemy_type"))
			_m_taken_by_type[atype] = int(_m_taken_by_type.get(atype, 0)) \
				+ int(payload.get("final_damage", 0))
	if node == null or not is_instance_valid(node) or not node.is_in_group("enemy"):
		return
	var enemy_type := String(node.get("enemy_type"))
	_m_dmg_by_type[enemy_type] = int(_m_dmg_by_type.get(enemy_type, 0)) \
		+ int(payload.get("final_damage", 0))


func _on_m_enemy_died(_enemy_id: StringName, enemy_type: StringName, _world_position: Vector2) -> void:
	var key := String(enemy_type)
	_m_kills_by_type[key] = int(_m_kills_by_type.get(key, 0)) + 1


func _on_m_status(_status_name: String, _duration: float) -> void:
	_m_status_hits += 1


func _nearest_enemy() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("enemy"):
		var e := n as Node2D
		if e == null or not is_instance_valid(e):
			continue
		var d := me.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Quest-aware target picker, used only by the quest scenario. It locks onto the
## enemy type the objective actually counts, so the bot never wastes the run on
## an enemy whose death does not advance the quest (e.g. the ranged cultist).
## Aliveness is judged only from public facts: the node is still valid, still in
## the "enemy" group, and not in the public DEAD state (a dying enemy lingers in
## the group for a beat before queue_free, and the bot must not attack a corpse).
## It never reads hp or any private field. `exclude` (instance_id -> frame) lets
## the caller skip wolves it has just given up on; it defaults to empty so the
## plain single-argument call still means "nearest matching live enemy".
func _nearest_quest_enemy(quest_id: String, exclude: Dictionary = {}) -> Node2D:
	var objective: Dictionary = QuestManager.get_quest(quest_id).get("objective", {})
	if String(objective.get("type", "")) != "kill":
		return null
	var want_type := StringName(String(objective.get("target", "")))
	if want_type == &"":
		return null
	var best: Node2D = null
	var best_dist := INF
	var me := _player_pos()
	for n in get_tree().get_nodes_in_group("enemy"):
		var e := n as Node2D
		if e == null or not is_instance_valid(e):
			continue
		if not e.is_in_group("enemy"):
			continue
		if e.get("enemy_type") != want_type:
			continue
		if e.get("state") == Enemy.State.DEAD:
			continue
		if exclude.has(e.get_instance_id()):
			continue
		var d := me.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## Drop abandoned entries whose enemy is gone or whose abandonment has aged out,
## so a wolf can be retried once the bot has had time to reposition.
func _prune_abandoned(abandoned: Dictionary) -> void:
	if abandoned.is_empty():
		return
	var now := Engine.get_physics_frames()
	for id: int in abandoned.keys():
		var node := instance_from_id(id)
		if not is_instance_valid(node) or now - int(abandoned[id]) > 900:
			abandoned.erase(id)


func _move_step(target: Vector2) -> void:
	var delta := target - _player_pos()
	bot_input.set_aim(target)
	if delta.length() < 0.5:
		bot_input.release_all()
		await get_tree().physics_frame
		return
	var dir := delta.normalized()

	# Crude but honest obstacle handling: when the straight line is blocked,
	# slide along the obstacle for a few frames instead of pressing into it.
	if _avoid_frames > 0:
		_avoid_frames -= 1
		dir = (dir * 0.35 + _avoid_dir * 0.65).normalized()

	bot_input.hold(&"move_right", dir.x > 0.35)
	bot_input.hold(&"move_left", dir.x < -0.35)
	bot_input.hold(&"move_down", dir.y > 0.35)
	bot_input.hold(&"move_up", dir.y < -0.35)
	await get_tree().physics_frame


func _move_to(target: Vector2, arrive: float, timeout: float) -> bool:
	var frames := int(timeout * 60.0)
	var stuck_frames := 0
	var last_pos := _player_pos()
	var avoid_attempts := 0
	for i in range(frames):
		var pos := _player_pos()
		if pos.distance_to(target) <= arrive:
			bot_input.release_all()
			return true

		if pos.distance_to(last_pos) < 0.35:
			stuck_frames += 1
		else:
			stuck_frames = 0
			last_pos = pos

		if stuck_frames >= 12:
			# Pick a side and commit to it for a while, then retry the direct line.
			avoid_attempts += 1
			_avoid_sign = -_avoid_sign
			var to_target := (target - pos).normalized()
			_avoid_dir = Vector2(-to_target.y, to_target.x) * _avoid_sign
			_avoid_frames = 24
			stuck_frames = 0
			Telemetry.decision({
				"action": "avoid_obstacle",
				"attempt": avoid_attempts,
				"at": [pos.x, pos.y],
			})
			if avoid_attempts > 26:
				Telemetry.event(&"bot_stuck", {"at": [pos.x, pos.y], "target": [target.x, target.y]})
				bot_input.release_all()
				return false

		await _move_step(target)
	bot_input.release_all()
	return false


func _dismiss_dialogue() -> void:
	for i in range(4):
		if not GameState.ui_blocking:
			return
		await _tap(&"interact")
		await _wait(0.15)


## Opens Yorek's till through the real interact key, tolerating his first-meeting
## greeting. The very first interact runs `yorek_intro` instead of opening the
## shop, so when a conversation rather than a panel answers the press the bot
## advances it to its last node — which is what sets the `met_yorek` flag the
## greeting is gated on — and presses interact once more. Advancing (not Esc) is
## deliberate: Esc closes the greeting without setting the flag, so the next press
## would greet again forever and the till would never open. Bounded so a press
## that lands on the wrong villager can never leave the bot standing in a modal.
func _open_merchant_shop(hud: CanvasLayer) -> bool:
	for _attempt in range(3):
		await _tap(&"interact")
		await _wait(0.4)
		if bool(hud.call("is_shop_open")):
			return true
		if GameState.ui_blocking:
			await _dismiss_dialogue()
			await _wait(0.2)
	return bool(hud.call("is_shop_open"))


func _tap(action: StringName) -> void:
	bot_input.hold(action, true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	bot_input.hold(action, false)
	await get_tree().physics_frame
	Telemetry.decision({"action": String(action), "reason": "scenario_" + scenario})
	_wd_note_action(String(action))


func _wait(seconds: float) -> void:
	var frames := maxi(1, int(seconds * 60.0))
	for i in range(frames):
		await get_tree().physics_frame


## Spin until the world has stepped to `frame`, so a scenario begins on a fixed
## absolute simulation step. A no-op (returns immediately) if the world is already
## past it, which keeps the wait from ever pushing a run backwards.
func _park_to_frame(frame: int) -> void:
	while Engine.get_physics_frames() < frame:
		await get_tree().physics_frame


## Convert a nominal wall-clock duration in seconds to a count of physics frames at
## the project's fixed 60 Hz physics tick. Every scenario budget is expressed in
## seconds for readability (`SCENARIO_TIMEOUT`, `ARENA_TIMEOUT`, …) and turned into
## a frame count here, so a deadline is a number of simulation steps rather than a
## reading off the wall clock. A wall-clock deadline makes the number of actions a
## scenario lands a function of how loaded the machine was, so a recorded seed need
## not reproduce on a slower box; a frame budget makes the run a pure function of the
## seed while keeping the same nominal seconds at 60 Hz.
func _frames(seconds: float) -> int:
	return int(seconds * 60.0)


## The inverse of `_frames`, for reporting a frame-measured duration back in the
## milliseconds the watchdog's log fields and the arena's max_control_ms verdict
## have always carried. Quantised to the frame, so the reported number is a pure
## function of the seed and identical across two launches on the same seed.
func _ms_of_frames(frames: int) -> int:
	return int(frames * 1000.0 / 60.0)
