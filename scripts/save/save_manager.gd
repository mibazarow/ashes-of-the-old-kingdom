extends Node
## Save/load with three slots, atomic writes and schema migration.
##
## Write order: slot_N.tmp -> read back and validate -> slot_N.bak -> slot_N.json.
## A crash mid-write therefore leaves the previous good slot untouched.

const SCHEMA_VERSION := 1
const SLOT_COUNT := 3
const SAVE_DIR := "user://saves"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [SAVE_DIR, slot]


func slot_backup_path(slot: int) -> String:
	return "%s/slot_%d.bak" % [SAVE_DIR, slot]


func slot_temp_path(slot: int) -> String:
	return "%s/slot_%d.tmp" % [SAVE_DIR, slot]


func save_game(slot: int) -> Dictionary:
	if slot < 1 or slot > SLOT_COUNT:
		return {"ok": false, "error": "bad_slot"}

	var payload := {
		"schema_version": SCHEMA_VERSION,
		"saved_at": Time.get_datetime_string_from_system(true),
		"play_time_ms": GameState.play_time_ms,
		"zone": "forest",
		"player_position": _player_position(),
		"game_state": GameState.to_dict(),
		"quests": QuestManager.to_dict(),
	}
	var text := JSON.stringify(payload, "\t")

	var tmp := slot_temp_path(slot)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		var msg := "cannot_open_tmp: %s" % error_string(FileAccess.get_open_error())
		Telemetry.error("SaveManager: " + msg)
		return {"ok": false, "error": msg}
	f.store_string(text)
	f.flush()
	f.close()

	# Verify what actually landed on disk before replacing the good slot.
	var verify := FileAccess.get_file_as_string(tmp)
	if verify.length() != text.length() or JSON.parse_string(verify) == null:
		DirAccess.remove_absolute(tmp)
		Telemetry.error("SaveManager: verification failed for slot %d" % slot)
		return {"ok": false, "error": "verification_failed"}

	var final_path := slot_path(slot)
	var bak_path := slot_backup_path(slot)
	if FileAccess.file_exists(final_path):
		if FileAccess.file_exists(bak_path):
			DirAccess.remove_absolute(bak_path)
		DirAccess.rename_absolute(final_path, bak_path)

	var err := DirAccess.rename_absolute(tmp, final_path)
	if err != OK:
		Telemetry.error("SaveManager: rename failed (%s)" % error_string(err))
		return {"ok": false, "error": "rename_failed:%s" % error_string(err)}

	Telemetry.event(&"save_written", {"slot": slot, "bytes": text.length()})
	return {"ok": true, "slot": slot, "bytes": text.length()}


func load_game(slot: int) -> Dictionary:
	if slot < 1 or slot > SLOT_COUNT:
		return {"ok": false, "error": "bad_slot"}
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "empty_slot"}

	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = _parse_json(text)
	if not parsed is Dictionary:
		Telemetry.error("SaveManager: corrupt slot %d, trying backup" % slot)
		var recovered := _try_backup(slot)
		if recovered.is_empty():
			return {"ok": false, "error": "corrupt_and_no_backup"}
		parsed = recovered

	var data: Dictionary = parsed
	var migrated := _migrate(data)
	if not bool(migrated.get("ok", false)):
		return {"ok": false, "error": String(migrated.get("error", "migration_failed"))}

	var payload: Dictionary = migrated["data"]
	GameState.from_dict(payload.get("game_state", {}))
	QuestManager.from_dict(payload.get("quests", {}))
	Telemetry.event(&"save_loaded", {"slot": slot, "schema": int(payload.get("schema_version", 0))})

	# Tell the player where the save left them. This is the player's own saved
	# position, not a shortcut into world state.
	var pos_raw: Array = payload.get("player_position", [])
	if pos_raw.size() == 2:
		EventBus.save_loaded.emit(Vector2(float(pos_raw[0]), float(pos_raw[1])))

	return {
		"ok": true,
		"slot": slot,
		"player_position": payload.get("player_position", []),
		"saved_at": payload.get("saved_at", ""),
	}


func _try_backup(slot: int) -> Dictionary:
	var bak := slot_backup_path(slot)
	if not FileAccess.file_exists(bak):
		return {}
	var parsed: Variant = _parse_json(FileAccess.get_file_as_string(bak))
	return parsed if parsed is Dictionary else {}


func _migrate(data: Dictionary) -> Dictionary:
	var version := int(data.get("schema_version", 0))
	if version > SCHEMA_VERSION:
		return {"ok": false, "error": "newer_schema_%d" % version}
	# v0 -> v1: pre-versioned saves had no quest block.
	if version < 1:
		if not data.has("quests"):
			data["quests"] = {}
		data["schema_version"] = 1
	return {"ok": true, "data": data}


func slot_info(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {"slot": slot, "exists": false}
	var parsed: Variant = _parse_json(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {"slot": slot, "exists": true, "corrupt": true}
	var gs: Dictionary = parsed.get("game_state", {})
	return {
		"slot": slot,
		"exists": true,
		"corrupt": false,
		"saved_at": parsed.get("saved_at", ""),
		"level": int(gs.get("level", 1)),
		"play_time_ms": int(parsed.get("play_time_ms", 0)),
	}


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _player_position() -> Array:
	var tree := get_tree()
	if tree == null:
		return []
	var players := tree.get_nodes_in_group("player")
	if players.is_empty():
		return []
	var p: Node2D = players[0]
	return [p.global_position.x, p.global_position.y]
