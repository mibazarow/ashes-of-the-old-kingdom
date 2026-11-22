extends Node
## Writes structured diagnostic logs under user://debug_runs/<run_id>/.
##
## Godot exits with code 0 even after runtime errors, so engine-level errors are
## captured here through a custom Logger and mirrored into errors.log.

const SCHEMA_VERSION := 1

## The seed a bot run gets when nobody asks for one. Fixed rather than derived: the
## whole reason a seed is recorded is that a PASS can be re-run and either fails
## again or does not, and a bot that picks a fresh seed every launch answers a
## question twice and settles it never.
const BOT_DEFAULT_SEED := 20261122

var run_id: String = ""
var run_dir: String = ""
var build_id: String = "dev"

## The seed the global RNG is running on, and how it was chosen. Recorded on every
## run, bot or not: a run whose seed was never written down cannot be re-created,
## which makes every claim about it unfalsifiable after the fact.
var seed_value: int = 0
var seed_source: String = "engine_default"

var _world_seed: int = -1
var _world_seed_resolved := false

var _events: FileAccess
var _combat: FileAccess
var _errors: FileAccess
var _decisions: FileAccess
var _started_ms: int = 0
var _logger: Logger


func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	_apply_seed_from_cmdline()
	run_id = _make_run_id()
	run_dir = "user://debug_runs/%s" % run_id
	DirAccess.make_dir_recursive_absolute(run_dir)
	_events = _open("events.jsonl")
	_combat = _open("combat.jsonl")
	_errors = _open("errors.log")
	_decisions = _open("decisions.jsonl")
	_install_engine_logger()
	write_run_meta()
	event("run_start", {
		"run_id": run_id,
		"engine": Engine.get_version_info().get("string", ""),
		"seed": seed_value,
		"seed_source": seed_source,
		"world_seed": world_seed(),
	})


## Chooses the seed for this process and puts it on the global RNG before anything
## can roll. Three sources, in this order of priority:
##
## * `--seed=N` on the command line — the operator names the run;
## * a bot run with no `--seed=` — the fixed bot seed, so two launches of the same
##   scenario are the same run and a PASS means something next week;
## * everything else — a seed drawn from the wall clock, so a human does not live
##   the same critical hits twice, while the number is still written down and the
##   session is still reproducible from the log.
##
## Godot seeds the global RNG itself, unpredictably, and offers no way to read that
## choice back. Taking the seed here is the only way the recorded number is the
## number that was actually in force.
func _apply_seed_from_cmdline() -> void:
	var requested := 0
	var has_requested := false
	var is_bot := false
	for argument: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if argument.begins_with("--seed="):
			requested = int(argument.trim_prefix("--seed="))
			has_requested = true
		elif argument.begins_with("--bot="):
			is_bot = true
	if has_requested:
		seed_value = requested
		seed_source = "cmdline"
	elif is_bot:
		seed_value = BOT_DEFAULT_SEED
		seed_source = "bot_default"
	else:
		seed_value = int(Time.get_unix_time_from_system() * 1000.0) % 2147483647
		seed_source = "generated"
	seed(seed_value)


## The seed the forest's procedural pass builds its trees and road from. Read off
## the zone script rather than copied into a constant here: a number written into
## two files is a number that drifts, and a recorded seed that is not the seed the
## world was generated from is worse than no seed at all, because it invites
## re-runs that cannot match. Zones authored entirely by hand have no procedural
## seed to report and read as 0.
func world_seed() -> int:
	if _world_seed_resolved:
		return _world_seed
	_world_seed_resolved = true
	_world_seed = 0
	var path := "res://scripts/world/forest.gd"
	if not ResourceLoader.exists(path):
		return _world_seed
	var script := load(path) as GDScript
	if script == null:
		return _world_seed
	_world_seed = int(script.get_script_constant_map().get("MAP_SEED", 0))
	return _world_seed


## Re-records the seed after the process learned a better one, so a run that was
## re-seeded late still reports the seed it actually finished on.
func set_run_seed(value: int, source: String) -> void:
	seed_value = value
	seed_source = source
	seed(value)
	write_run_meta()
	event("run_seed", {"seed": value, "source": source, "world_seed": world_seed()})


func _make_run_id() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true)
	# "2026-11-18 18:17:11" -> "20261118-181711"; spaces are not safe in paths.
	stamp = stamp.replace("-", "").replace(":", "").replace(" ", "-").replace("T", "-")
	return "%s-%03d" % [stamp, Time.get_ticks_msec() % 1000]


func _open(file_name: String) -> FileAccess:
	var f := FileAccess.open(run_dir.path_join(file_name), FileAccess.WRITE)
	if f == null:
		push_error("Telemetry: cannot open %s" % file_name)
	return f


func _install_engine_logger() -> void:
	if not OS.has_method("add_logger"):
		return
	_logger = _make_logger()
	if _logger != null:
		OS.add_logger(_logger)


func _make_logger() -> Logger:
	var logger := preload("res://scripts/core/telemetry_logger.gd").new()
	logger.sink = self
	return logger


func elapsed_ms() -> int:
	return Time.get_ticks_msec() - _started_ms


func _base(event_type: StringName) -> Dictionary:
	return {
		"ts": elapsed_ms(),
		"run_id": run_id,
		"build_id": build_id,
		"type": String(event_type),
	}


func event(event_type: StringName, data: Dictionary = {}) -> void:
	var payload := _base(event_type)
	for k in data:
		payload[String(k)] = data[k]
	_write(_events, payload)


func combat(data: Dictionary) -> void:
	var payload := _base(&"combat")
	for k in data:
		payload[String(k)] = data[k]
	_write(_combat, payload)
	_write(_events, payload)


func decision(data: Dictionary) -> void:
	var payload := _base(&"decision")
	for k in data:
		payload[String(k)] = data[k]
	_write(_decisions, payload)
	_write(_events, payload)


func error(line: String) -> void:
	if _errors == null:
		return
	_errors.store_line("[%d] %s" % [elapsed_ms(), line])
	_errors.flush()


func _write(f: FileAccess, payload: Dictionary) -> void:
	if f == null:
		return
	f.store_line(JSON.stringify(payload))
	f.flush()


func write_run_meta(extra: Dictionary = {}) -> void:
	var meta := {
		"schema": SCHEMA_VERSION,
		"run_id": run_id,
		"build_id": build_id,
		"engine": Engine.get_version_info(),
		"started_at": Time.get_datetime_string_from_system(true),
		"platform": OS.get_name(),
		"seed": seed_value,
		"seed_source": seed_source,
		"world_seed": world_seed(),
	}
	for k in extra:
		meta[String(k)] = extra[k]
	var f := FileAccess.open(run_dir.path_join("run_meta.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()


func write_summary(result: String, extra: Dictionary = {}) -> void:
	var lines := PackedStringArray()
	lines.append("RUN: %s" % run_id)
	lines.append("BUILD: %s" % build_id)
	lines.append("GODOT: %s" % Engine.get_version_info().get("string", ""))
	lines.append("SEED: %d (%s)" % [seed_value, seed_source])
	lines.append("WORLD_SEED: %d" % world_seed())
	lines.append("RESULT: %s" % result)
	lines.append("DURATION_MS: %d" % elapsed_ms())
	for k in extra:
		lines.append("%s: %s" % [String(k).to_upper(), str(extra[k])])
	var f := FileAccess.open(run_dir.path_join("summary.md"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("[telemetry] run=%s result=%s" % [run_id, result])


func _exit_tree() -> void:
	for f in [_events, _combat, _errors, _decisions]:
		if f != null:
			f.flush()
			f.close()
