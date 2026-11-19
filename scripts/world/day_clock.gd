class_name DayClock
extends Node
## In-game day cycle for the villager schedules (spec §12.1).
##
## Lives as a node created by `Forest`, NOT an autoload: the clock is part of the
## world slice, so a test gets it by instantiating the world scene, and adding it
## to `project.godot` would touch a file the task keeps off-limits unless needed.
## It joins the `day_clock` group so the HUD and the schedule components can find
## it through a group scan rather than a hardcoded node path.
##
## Time is a fraction of a day (0..1). It only advances while the game is neither
## blocked by a modal UI (`GameState.ui_blocking`) nor paused: a paused or menu
## screen must not age the villagers. The default `PROCESS_MODE_INHERIT` already
## stops `_process` while the tree is paused; the `ui_blocking` gate is the extra
## half of that rule.

signal phase_changed(phase: String)

const SCHEDULES_PATH := "res://data/schedules.json"

## Full real-time length of one in-game day, in seconds. Overridden from the data.
var day_length_seconds: float = 240.0

## Current time as a fraction of the day, 0..1 (never reaches 1.0).
var time_fraction: float = 0.0

var _phases: Array = []
var _phase: String = ""
var _data: Dictionary = {}
var _loaded: bool = false


func _ready() -> void:
	add_to_group("day_clock")
	_load()
	# Seed the current phase without emitting: listeners (schedule components)
	# read `phase()` in their own _ready and snap to the matching spot, so the
	# first assignment must not trigger a walk.
	_refresh_phase(true)


func _process(delta: float) -> void:
	if GameState.ui_blocking:
		return
	time_fraction += delta / maxf(0.001, day_length_seconds)
	if time_fraction >= 1.0:
		time_fraction -= floorf(time_fraction)
	_refresh_phase(false)


## The phase whose `start` is the last one at or below `time_fraction`. Before the
## first phase loads this returns the empty string rather than guessing.
func phase() -> String:
	return _phase


## Sets the time directly, for tests and save restore. Values at or past 1.0 wrap
## back into [0,1) (so 1.0 lands on 0.0, the start of a new day); negatives wrap
## forward the same way. A phase change is announced like any other.
func set_time_fraction(value: float) -> void:
	var wrapped := fmod(value, 1.0)
	if wrapped < 0.0:
		wrapped += 1.0
	time_fraction = wrapped
	_refresh_phase(false)


## The raw parsed schedule data (phases, per-NPC spots, day length), so the
## schedule components and a data-vs-world test read one shared source.
func schedules() -> Dictionary:
	if not _loaded:
		_load()
	return _data


func _load() -> void:
	_loaded = true
	if not FileAccess.file_exists(SCHEDULES_PATH):
		push_error("DayClock: cannot find %s" % SCHEDULES_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCHEDULES_PATH))
	if not (parsed is Dictionary):
		push_error("DayClock: cannot parse %s" % SCHEDULES_PATH)
		return
	_data = parsed as Dictionary
	var length: Variant = _data.get("day_length_seconds", day_length_seconds)
	if (length is int or length is float) and float(length) > 0.0:
		day_length_seconds = float(length)
	var phases: Variant = _data.get("phases", [])
	if phases is Array:
		_phases = phases as Array
	_phases.sort_custom(_compare_phase_starts)


func _compare_phase_starts(a: Variant, b: Variant) -> bool:
	return _phase_start(a) < _phase_start(b)


func _phase_start(entry: Variant) -> float:
	if not (entry is Dictionary):
		return 0.0
	var raw: Variant = (entry as Dictionary).get("start", 0.0)
	return float(raw) if (raw is int or raw is float) else 0.0


## Resolves the phase id for the current fraction and emits `phase_changed` when
## it differs from the last one. `silent` assigns without emitting (first seed).
func _refresh_phase(silent: bool) -> void:
	if _phases.is_empty():
		return
	var resolved := _phase_for(time_fraction)
	if resolved == _phase:
		return
	_phase = resolved
	if not silent:
		phase_changed.emit(_phase)


func _phase_for(fraction: float) -> String:
	var result := ""
	for entry: Variant in _phases:
		if not (entry is Dictionary):
			continue
		var block: Dictionary = entry as Dictionary
		if _phase_start(block) <= fraction:
			result = String(block.get("id", ""))
		else:
			break
	if result == "" and not _phases.is_empty():
		var first: Variant = _phases[0]
		if first is Dictionary:
			result = String((first as Dictionary).get("id", ""))
	return result
