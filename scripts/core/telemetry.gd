extends Node
## Writes structured diagnostic logs under user://debug_runs/<run_id>/.
##
## Godot exits with code 0 even after runtime errors, so engine-level errors are
## captured here through a custom Logger and mirrored into errors.log.

const SCHEMA_VERSION := 1

var run_id: String = ""
var run_dir: String = ""
var build_id: String = "dev"

var _events: FileAccess
var _combat: FileAccess
var _errors: FileAccess
var _decisions: FileAccess
var _started_ms: int = 0
var _logger: Logger


func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	run_id = _make_run_id()
	run_dir = "user://debug_runs/%s" % run_id
	DirAccess.make_dir_recursive_absolute(run_dir)
	_events = _open("events.jsonl")
	_combat = _open("combat.jsonl")
	_errors = _open("errors.log")
	_decisions = _open("decisions.jsonl")
	_install_engine_logger()
	write_run_meta()
	event("run_start", {"run_id": run_id, "engine": Engine.get_version_info().get("string", "")})


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
