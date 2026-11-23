extends Node
## Display/accessibility settings (spec §24 «настройки интенсивности», §23 stage 8).
##
## One small store for the three screen preferences the settings panel exposes:
## hit-flash intensity, UI font scale and a colour-blind mode. It owns exactly
## one file, `user://settings/accessibility.json`, written atomically with the
## same tmp+verify+rename discipline as `audio_manager.gd`, and it is deliberately
## a *separate* file from `audio.json`: the audio autoload owns its file and its
## `save_settings()` writes only the volume block, so folding screen settings in
## there would either make the audio layer carry keys it knows nothing about or
## force a second writer onto the same file. A separate file keeps each store's
## writer single and each round trip independent.
##
## Like the audio autoload, this node is resolved at runtime by name through the
## scene root wherever it is read (player, enemy, HUD, settings panel), so no
## gameplay script names `Accessibility` in its compile graph and every reader
## still loads under `godot --script`. A reader that finds no autoload falls back
## to the shipped default, so removing this autoload changes nothing but the
## defaults — the same contract the audio layer gives the game.

const SETTINGS_PATH := "user://settings/accessibility.json"
const SETTINGS_VERSION := 1

## Hit-flash intensity, percent. 100 is the shipped flash; 0 removes it entirely
## (a hit still registers, it just does not tint the sprite). Clamped 0..100.
const FLASH_MIN := 0
const FLASH_MAX := 100
const FLASH_DEFAULT := 100
## UI font scale, percent of the base 8 px theme font. Clamped 100..150 so the
## HUD can never be scaled past what the 480x270 viewport holds.
const FONT_MIN := 100
const FONT_MAX := 150
const FONT_DEFAULT := 100

## Emitted after any value changes, so the HUD can re-apply the font scale and
## the settings panel can repaint without polling.
signal changed

var flash_intensity: int = FLASH_DEFAULT
var font_scale: int = FONT_DEFAULT
var colorblind_mode: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()


# --- normalised reads for consumers ------------------------------------------

## Hit-flash strength as 0..1, the unit the player and enemy multiply their flash
## tint by. 0 means "no flash", 1 means "the shipped flash".
func flash_intensity_normalized() -> float:
	return clampi(flash_intensity, FLASH_MIN, FLASH_MAX) / 100.0


## Font scale as a multiplier (1.0 .. 1.5) applied to the base theme font size.
func font_scale_factor() -> float:
	return clampi(font_scale, FONT_MIN, FONT_MAX) / 100.0


func colorblind_enabled() -> bool:
	return colorblind_mode


# --- setters (clamped, emit `changed`) ---------------------------------------

func set_flash_intensity(value: int) -> void:
	var next := clampi(value, FLASH_MIN, FLASH_MAX)
	if next == flash_intensity:
		return
	flash_intensity = next
	changed.emit()


func set_font_scale(value: int) -> void:
	var next := clampi(value, FONT_MIN, FONT_MAX)
	if next == font_scale:
		return
	font_scale = next
	changed.emit()


func set_colorblind_mode(enabled: bool) -> void:
	if enabled == colorblind_mode:
		return
	colorblind_mode = enabled
	changed.emit()


## Restores all three shipped defaults. The settings panel's `R` key routes here
## for the selected row only via the individual setters; this is the whole-reset.
func set_defaults() -> void:
	flash_intensity = FLASH_DEFAULT
	font_scale = FONT_DEFAULT
	colorblind_mode = false
	changed.emit()


## The shipped defaults, for a caller that has to show or restore them rather
## than apply them — the settings panel is the only one.
func settings_defaults() -> Dictionary:
	return {
		"flash_intensity": FLASH_DEFAULT,
		"font_scale": FONT_DEFAULT,
		"colorblind_mode": false,
	}


# --- persistence --------------------------------------------------------------

## Atomic write: tmp file, flush, re-read and re-parse to verify, then rename
## over the target. A half-written or unparseable file never replaces a good one.
func save_settings() -> Dictionary:
	var payload := {
		"version": SETTINGS_VERSION,
		"flash_intensity": flash_intensity,
		"font_scale": font_scale,
		"colorblind_mode": colorblind_mode,
	}
	DirAccess.make_dir_recursive_absolute(SETTINGS_PATH.get_base_dir())
	var text := JSON.stringify(payload, "\t")
	var tmp := SETTINGS_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		var msg := "cannot_open_tmp: %s" % error_string(FileAccess.get_open_error())
		_warn(msg)
		return {"ok": false, "error": msg}
	file.store_string(text)
	file.flush()
	file.close()

	var verify := FileAccess.get_file_as_string(tmp)
	if verify.length() != text.length() or _parse_json(verify) == null:
		DirAccess.remove_absolute(tmp)
		_warn("verification failed for %s" % SETTINGS_PATH)
		return {"ok": false, "error": "verification_failed"}

	var err := DirAccess.rename_absolute(tmp, SETTINGS_PATH)
	if err != OK:
		_warn("rename failed (%s)" % error_string(err))
		return {"ok": false, "error": "rename_failed:%s" % error_string(err)}
	return {"ok": true, "error": ""}


## Apply the stored values. A missing file is a fresh install and keeps the
## shipped defaults; a corrupt or half-written file lands on the same defaults
## with one diagnostic line, never on a partial state.
func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed: Variant = _parse_json(FileAccess.get_file_as_string(SETTINGS_PATH))
	if not parsed is Dictionary:
		_warn("%s is not a JSON object, keeping defaults" % SETTINGS_PATH)
		return
	var data := parsed as Dictionary
	if data.get("flash_intensity", null) is float or data.get("flash_intensity", null) is int:
		flash_intensity = clampi(int(data["flash_intensity"]), FLASH_MIN, FLASH_MAX)
	if data.get("font_scale", null) is float or data.get("font_scale", null) is int:
		font_scale = clampi(int(data["font_scale"]), FONT_MIN, FONT_MAX)
	if data.get("colorblind_mode", null) is bool:
		colorblind_mode = bool(data["colorblind_mode"])


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


## Single-line diagnostic, mirroring `audio_manager.gd`: a corrupt settings file
## is expected and recoverable, so it must not spray a backtrace into the log.
func _warn(message: String) -> void:
	print("[accessibility] %s" % message)
