extends Logger
## Bridges engine errors into Telemetry.errors.log.
##
## Registered through OS.add_logger() by Telemetry._ready(). If the engine
## version lacks the Logger API the call is skipped there and this file is unused.

var sink: Node = null


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array[ScriptBacktrace]
) -> void:
	if sink == null:
		return
	sink.error(
		"ENGINE_ERROR type=%d code=%s at %s:%d (%s) %s"
		% [error_type, code, file, line, function, rationale]
	)


func _log_message(message: String, error: bool) -> void:
	if sink == null or not error:
		return
	sink.error("ENGINE_MESSAGE %s" % message)
