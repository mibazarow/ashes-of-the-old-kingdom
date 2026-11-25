class_name Npc
extends Area2D
## Quest giver. Turns the quest in exactly once through QuestManager.

# --- NPC readability (mirrors the enemy silhouette pass in scripts/ai/enemy.gd) --
# Enemies got a per-zone silhouette outline and a zone-scaled body tint
# (CRITIC-P1-18); NPCs stayed unpainted and sank into the dark dungeon and
# fortress floors as brown blobs. `enemy.gd` is off-limits to this pass, so the
# shader below is a byte-for-byte copy of `Enemy.OUTLINE_SHADER_CODE` and the
# two must be kept in sync by hand. The vertex-stage `modulate_alpha` copy is
# load-bearing there and here for the same reason: this engine hands
# `fragment()` a `COLOR` already multiplied by the texture sample, so at a
# transparent ring texel `COLOR.a` is 0 and a ring alpha taken from the
# fragment's `COLOR` would draw no outline anywhere.
const NPC_OUTLINE_SHADER_CODE := "
shader_type canvas_item;
uniform vec4 outline_color : source_color = vec4(0.043, 0.051, 0.067, 1.0);
varying float modulate_alpha;
void vertex() {
	modulate_alpha = COLOR.a;
}
void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec4 tex = texture(TEXTURE, UV);
	float ring = texture(TEXTURE, UV + vec2(px.x, 0.0)).a;
	ring = max(ring, texture(TEXTURE, UV - vec2(px.x, 0.0)).a);
	ring = max(ring, texture(TEXTURE, UV + vec2(0.0, px.y)).a);
	ring = max(ring, texture(TEXTURE, UV - vec2(0.0, px.y)).a);
	if (tex.a < 0.5 && ring >= 0.5) {
		COLOR = vec4(outline_color.rgb, outline_color.a * modulate_alpha);
	} else {
		COLOR = tex * COLOR;
	}
}
"

## The two silhouette outline colours, mirroring `Enemy.OUTLINE_DARK` and
## `Enemy.OUTLINE_LIGHT`: dark on the light forest/ruins/village floors, light
## on the dark dungeon/fortress floors. The zone itself decides which one its
## NPCs wear, through the same `enemy_outline_color()` hook the enemies read.
const OUTLINE_DARK := Color(0.043, 0.051, 0.067)
const OUTLINE_LIGHT := Color(0.910, 0.933, 0.965)

## One cached ShaderMaterial per outline colour, shared by every NPC — the
## `Npc` subclasses and the code-built `Merchant`/`Smith` alike, which call
## through these statics instead of inheriting them. At most two shader
## programs for the whole cast, and a headless test that never draws an NPC
## pays nothing for either.
static var _outline_materials: Dictionary = {}


## The silhouette material for one outline colour, built on first use.
static func outline_material(outline_color: Color = OUTLINE_DARK) -> ShaderMaterial:
	var key := outline_color.to_html(false)
	var cached: ShaderMaterial = _outline_materials.get(key)
	if cached == null:
		var shader := Shader.new()
		shader.code = NPC_OUTLINE_SHADER_CODE
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("outline_color", outline_color)
		_outline_materials[key] = material
		cached = material
	return cached


## The nearest ancestor that chose this zone's readability colours — a ZoneBase
## answers both `enemy_outline_color` and `enemy_body_tint`. Null in a bare
## arena, where the dark-outline default and an unscaled body apply. The same
## contract `Enemy._readability_zone` resolves, so an NPC and an enemy standing
## on the same tile read the same pair of colours from the same zone.
static func readability_zone(node: Node) -> Node:
	var parent := node.get_parent()
	while parent != null:
		if parent.has_method("enemy_outline_color") and parent.has_method("enemy_body_tint"):
			return parent
		parent = parent.get_parent()
	return null


## The outline colour of the zone `node` stands in (dark default with no zone).
static func zone_outline_color(node: Node) -> Color:
	var zone := readability_zone(node)
	if zone == null:
		return OUTLINE_DARK
	return zone.call("enemy_outline_color") as Color


## The body brightness scalar of the zone `node` stands in. Identity with no
## zone: a bare NPC keeps the tint its character authored, because the NPC
## identity tints are already mid-bright (unlike the near-white enemy defaults
## the zone scalars were tuned around).
static func zone_body_scalar(node: Node) -> Color:
	var zone := readability_zone(node)
	if zone == null:
		return Color(1.0, 1.0, 1.0)
	return zone.call("enemy_body_tint") as Color


## The outline pass: the zone's silhouette ring on the sprite. NB: this engine
## build exposes CanvasItem's local material as `material`, not 4.x
## `material_override` — the same note as in `Enemy._ready`.
static func apply_npc_outline(node: Node, sprite: Sprite2D) -> void:
	if sprite == null or not is_instance_valid(sprite):
		return
	sprite.material = outline_material(zone_outline_color(node))


## The headman's identity tint: a warm earth brown on the shared NPC sprite.
## The base `Npc` IS Edrik's class the same way it already carries his default
## `display_name` and `quest_id` (`edrik.tscn` overrides neither with a tint),
## and every subclass authors its own `modulate` in its `_ready` after
## `super()`, so this lands on the headman (and a bare `Npc`) only.
const IDENTITY_TINT := Color(0.72, 0.46, 0.24)

## The floor the body pass never lets a zone push a figure below, on the HSV
## value axis. The owner's frame review found the whole village cast rendering
## as six near-identical dark blobs: the village inherited the enemy scalar
## 0.5, and a per-channel `modulate *= 0.5` on mid-bright pastel identities
## lands at WCAG luminance ~0.15 — a dark lump no hue survives reading in.
## 0.45 keeps every figure a clearly lit person on any floor while staying
## below the light floors' own luminance, so the dark silhouette ring keeps
## its contrast the zone chose for it.
const NPC_BODY_MIN_VALUE := 0.45

## The body pass: move the VALUE (brightness) axis of whatever tint the
## character authored in `_ready` (or the zone script painted over it right
## after `add_child`) by the zone scalar's luminance, and never touch the hue
## or saturation — the character's identity. The old per-channel multiply was
## tuned around the enemies' near-white hues (`Enemy.readable_body_tint`,
## untouched here); on the NPCs' coloured tints it only crushed them toward
## black. Value scaling keeps the six villagers six different people: Mila's
## herb green and Seris's mill blue stay green and blue at the village scalar,
## not two darker copies of the same brown blob. Dark-zone scalars (> 1) still
## brighten — Nela's undercroft grey rides to v 1.0 and renders as a light
## readable figure — clamping at 1.0 exactly where the display clamps
## `tex * modulate`. The floor stops the crush from the other side: the ruins
## scalar 0.32 used to drive the pilgrim's cloak to v 0.27; it now lands on
## the floor.
static func scale_npc_tint(tint: Color, scalar: Color) -> Color:
	# NB: this engine build exposes the HSV axes as `Color.h/s/v` properties
	# and `Color.from_hsv` (the same pair `Enemy.readable_body_tint` uses);
	# the stock 4.x `to_hsv()` does not exist here.
	var value := clampf(tint.v * scalar.get_luminance(), NPC_BODY_MIN_VALUE, 1.0)
	return Color.from_hsv(tint.h, tint.s, value, tint.a)


static func scale_npc_body(node: Node, sprite: Sprite2D) -> void:
	if sprite == null or not is_instance_valid(sprite):
		return
	var scalar := zone_body_scalar(node)
	if scalar == Color(1.0, 1.0, 1.0):
		return
	sprite.modulate = scale_npc_tint(sprite.modulate, scalar)

## The quest this instance hands out. Per-instance (set on `edrik.tscn`, and on
## any code-built villager) rather than a hardcoded constant, so a second quest
## giver can exist without subclassing the dialogue path. Edrik's scene sets
## `q01_ash_wolves`; the default keeps a bare `Npc` working as the hunt giver.
@export var quest_id: String = "q01_ash_wolves"

@export var display_name: String = "Эдрик"
## Slug that names this character's dialogues in data/dialogue.json: the runner id
## is `"<speaker_id>_<context>"` (spec §12.2). It is a stable ASCII key, kept
## separate from the Cyrillic `display_name` so renaming the label never orphans
## the conversation data.
@export var speaker_id: String = "edrik"
@export var sprite_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D

var _bubble: Label

## One-shot body scaling (see `_process`). The zone scripts paint their own
## identity tint right after `add_child` — after `_ready` has run — so the
## zone scalar cannot be applied inside `_ready` without being overwritten.
## A freed NPC never processes again, so a world freed mid-frame (travel uses
## `free()`, and the screenshot probe travels inside `_ready`) leaves nothing
## pending behind it.
var _npc_body_scaled := false


func _ready() -> void:
	add_to_group("interactable")
	if sprite_texture != null:
		sprite.texture = sprite_texture
	# The headman's identity tint (see `IDENTITY_TINT`). Guarded like the
	# subclass tints: a bare `Npc` built without the world's sprite has none.
	# Subclasses overwrite this in their own `_ready` after `super()`, and a
	# spawning zone may still paint its figure tint after `add_child` — both
	# win over the default exactly as they won over the old white.
	if sprite != null and is_instance_valid(sprite):
		sprite.modulate = IDENTITY_TINT
	# Readability pass (mirrors `Enemy._ready`): the zone's silhouette ring goes
	# on immediately; the zone-scaled body tint lands on the first processed
	# frame, after any tint the spawning zone script paints in this same frame.
	apply_npc_outline(self, sprite)
	_bubble = Label.new()
	_bubble.text = "!"
	_bubble.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_bubble.add_theme_font_size_override("font_size", 8)
	_bubble.position = Vector2(-2, -24)
	add_child(_bubble)
	EventBus.quest_progress.connect(_on_quest_progress)
	EventBus.quest_completed.connect(_on_quest_completed)
	_refresh_bubble()


## Runs exactly once, on the first processed frame, then switches itself off:
## the body pass has to land after the spawner's post-`add_child` tint, and no
## later code in the project writes an NPC sprite's modulate again (the day
## schedule moves positions, never colours). `Villager` and `Pilgrim` inherit
## this pass; they only author their identity tint in `_ready`.
func _process(_delta: float) -> void:
	if _npc_body_scaled:
		return
	_npc_body_scaled = true
	set_process(false)
	scale_npc_body(self, sprite)


func prompt_text() -> String:
	return "Говорить — %s" % display_name


func interact(_player: Node) -> void:
	# Data-driven conversation first (spec §12.2). The context picks the dialogue:
	# the after-hunt line once the hunt is over, the intro otherwise. The runner is
	# built with the live state injected rather than reading the autoloads inside,
	# so the same object the test constructs is the one the game uses.
	var state: String = QuestManager.state_of(quest_id)
	var context := "intro"
	if state == QuestManager.STATE_READY or state == QuestManager.STATE_DONE:
		context = "after_hunt"
	var runner := DialogueRunner.new(GameState, QuestManager)
	if runner.start("%s_%s" % [speaker_id, context]):
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("open_dialogue_runner"):
			hud.open_dialogue_runner(runner)
			return

	# Fallback: the runner refused (unknown dialogue, an unmet condition, or no HUD
	# to show it). The quest turn-in lives here on purpose — edrik_after_hunt is
	# gated on `quest_done`, so while the quest is only `ready` the runner refuses
	# and this path turns it in. This is the path the quest bot relies on.
	var quest: Dictionary = QuestManager.get_quest(quest_id)
	var lines: Array = []

	if state == QuestManager.STATE_AVAILABLE:
		lines.append({"speaker": display_name, "text": String(quest.get("start_line", "..."))})
		EventBus.dialogue_requested.emit(lines)
		QuestManager.start(quest_id)
		return
	if state == QuestManager.STATE_ACTIVE:
		var cur: int = QuestManager.progress_of(quest_id)
		var total: int = QuestManager.target_count(quest_id)
		var title := String(quest.get("title", "Задание"))
		lines.append({
			"speaker": display_name,
			"text": "%s: %d из %d. Ещё не готово." % [title, cur, total],
		})
		EventBus.dialogue_requested.emit(lines)
		return
	if state == QuestManager.STATE_READY:
		lines.append({"speaker": display_name, "text": String(quest.get("turn_in_line", "..."))})
		EventBus.dialogue_requested.emit(lines)
		QuestManager.turn_in(quest_id)
		return

	lines.append({"speaker": display_name, "text": "Деревня дышит ровнее. Спасибо."})
	EventBus.dialogue_requested.emit(lines)


func _refresh_bubble() -> void:
	var state: String = QuestManager.state_of(quest_id)
	match state:
		QuestManager.STATE_AVAILABLE:
			_bubble.text = "!"
			_bubble.visible = true
		QuestManager.STATE_READY:
			_bubble.text = "?"
			_bubble.visible = true
		_:
			_bubble.visible = false


func _on_quest_progress(_id: StringName, _c: int, _t: int) -> void:
	_refresh_bubble()


func _on_quest_completed(_id: StringName) -> void:
	_refresh_bubble()
