extends Node
## Process-wide hit-stop: a single, caller-independent slow-motion clock.
##
## The old Player._hit_stop awaited a SceneTree timer on the player node, so a
## player freed mid-stop (death + respawn, scene change, quit to menu) left
## Engine.time_scale stuck at 0.12 for the rest of the process, and overlapping
## swings in one melee fan each reset the scale at their own time. This autoload
## owns the clock instead: it is never freed mid-stop, it merges overlapping
## requests to the longest remaining duration, and it always restores
## Engine.time_scale = 1.0 — including when the autoload itself is torn down.

const SCALE := 0.12

var _left := 0.0
var _active := false


func _ready() -> void:
	# Keep ticking through a paused tree so a stop can never hang on a pause that
	# happens to land while the scale is reduced.
	process_mode = PROCESS_MODE_ALWAYS


## Request a hit-stop of `duration` real seconds. Overlapping requests do not
## stack or race: the active window is extended to the longest remaining
## duration, so a second, longer hit keeps the scale down until it is spent.
func request(duration: float) -> void:
	if duration <= 0.0:
		return
	_left = maxf(_left, duration)
	if not _active:
		_active = true
		Engine.time_scale = SCALE


## Restore full speed immediately. Used on death, respawn, scene change and quit
## so a stop can never carry into the death screen or a menu.
func cancel() -> void:
	_restore()


# Real-duration accounting: the delta Godot hands _process is already multiplied
# by Engine.time_scale, so subtracting it directly would make a 0.12 stop last
# ~8x longer in wall-clock terms. Dividing the scaled delta back by the current
# scale recovers real seconds, so a requested 0.045 s stop lasts 0.045 s of real
# time regardless of the scale value. The maxf guard keeps the divisor off zero.
func _process(delta: float) -> void:
	if not _active:
		return
	var real_delta := delta / maxf(Engine.time_scale, 0.0001)
	_left -= real_delta
	if _left <= 0.0:
		_restore()


func _restore() -> void:
	_left = 0.0
	_active = false
	Engine.time_scale = 1.0


# Tearing the autoload down (process exit, tree shutdown) must never leave the
# scale broken for whatever reads it next.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		if _active:
			_restore()
