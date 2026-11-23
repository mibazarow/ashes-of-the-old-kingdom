# CRITIC-GODOT — ROUND 1 (architecture, API correctness, data structures, boundaries, extensibility)

| Field | Value |
| --- | --- |
| Role | CRITIC-GODOT (spec §22.1) — technical auditor: Godot architecture, GDScript, system boundaries, data structures, extensibility |
| Build / commit | `19eb835` (2026-11-23 07:22 +0300) |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` (`/opt/homebrew/bin/godot`) |
| Date | 2026-11-23 |
| Independence | I built none of this. Every finding is backed by a command I ran or a file I read on this commit. I did not trust `PROCESS.md`/`README.md`. |
| Scope note | Design findings (content, balance, story, the ending seam) belong to CRITIC-DESIGN and are NOT repeated here. This round is engineering only. |

**Verdict: APPROVE WITH CONDITIONS — Score 7.5/10.** No P0, no P1 in this round's scope. The
architecture is sound for a slice of this size; the conditions are P2/P3 maintainability items.

---

## 1. Findings

| ID | Sev | Finding | Evidence (file:line / command) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| G1-R1 | P2 | Data layer is 100% JSON with **no unified schema validator**. Each of 9 files is parsed by its own DB module; a misspelled field key (e.g. `damge`) is silently absorbed by the defensive getters' defaults rather than failing loudly. | `find data -type f` → 9 `.json`, 0 `.tres`. `item_db.gd:35-48` parses, `:89-91` `rarity()` falls back to `"common"` for any unknown value, `:134-140` `combo_window()` falls back on any non-positive. Only `progression.json` and the `quests.json` chain are schema-tested (`test_core.gd:468,580,1099`). | Expected: a data typo is caught at load/test time. Actual: a typo reads as a default and ships. | Add one static data-validation test that walks every DB and asserts each record's required keys and value ranges, so the JSON contract is pinned the way the save schema is. | OPEN |
| G2-R1 | P2 | `GameState` autoload is a **god object**: 1144 lines, 75 functions, 108 state fields spanning HP/mana, attributes, XP/progression, gold, items, equipment, quick-slots, skills, zones, flags and the ending. | `wc -l scripts/core/game_state.gd` → 1144; `grep -c '^[[:space:]]*func '` → 75; `grep -c '^[[:space:]]*var '` → 108. | Expected: cohesive single-responsibility state modules. Actual: one autoload owns every mutable domain. | Defensible for unified `to_dict`/`from_dict` save (it has both, `:949,:979`, plus `_sanitize_progression`), but extract inventory/equipment and progression behind sub-objects the autoload delegates to, to keep it from growing. | OPEN (accepted tradeoff) |
| G3-R1 | P3 | Directory boundary smell: `scripts/npc/` (base `Npc`, `ScheduleComponent`) vs `scripts/npcs/` (concrete `Merchant`/`Smith`/`Villager`/`Pilgrim`). Two near-identical names hold base vs derived. | `ls scripts/npc` → `npc.gd, schedule_component.gd`; `ls scripts/npcs` → `merchant/smith/villager/pilgrim.gd`. | Expected: one clear location or a name that signals base-vs-concrete. Actual: `npc` vs `npcs` is a navigation trap. | Merge into `scripts/npc/` with `base/` and `roles/`, or rename `npcs`→`npc_roles`. | OPEN |
| G4-R1 | P3 | No central data registry: each DB (`ItemDB`, `SkillDB`, `QuestManager`, `CraftManager`, `ShopManager`, `DialogueDB`, `GameState`, `ZoneManager`, `DayClock`) independently opens and parses its own `res://data/*.json`. | `grep -rn 'res://data/' scripts/` → 10 separate `const PATH` loaders. | Expected: one loader that owns parse+validate+cache. Actual: nine parallel loaders. | A shared `_load_validated(path)` helper would centralise the error handling the per-DB `_ensure_loaded` currently duplicates. | OPEN |
| G5-R1 | P3 | Debug bot and the full test suite ship inside the release `.pck`. | `export_presets.cfg:8,46` `export_filter="all_resources"`, `exclude_filter=""`; no `.gdignore` under `scripts/debug_bot` or `tests`. | Expected: release excludes dev-only code. Actual: `bot.gd` (4354 lines) + `test_core.gd` (13966) are packaged. | Add an export exclude for `scripts/debug_bot/`, `tests/`, `tools/`. (Bot is flag-gated so inert, but it is dead weight and surface.) | OPEN |

### Verified correct in this scope (recorded so the report is not read as blanket-negative)

- **API correctness is excellent.** Zero real Godot-3 leftovers: `grep -rnE 'KinematicBody2D|yield\(|setget |[^_]export\(|rand_range|[^a-z_]instance\(|File\.new|PoolStringArray|OS\.get_ticks|move_and_slide\([^)]' scripts/` → **0**. The 20 hits from the loose scan are all correct 4.x idioms (`@onready var`, zero-arg `move_and_slide()`).
- **Static typing discipline is high.** 1097 of 1108 function signatures carry a return type (99%); the 11 "untyped" are multi-line signatures whose `->` is on a continuation line.
- **Clean engine run.** `godot --headless --path . --quit-after 120` → `grep -cE 'ERROR|SCRIPT ERROR|leaked|still in use'` = **0**. No leaks, no invalid references, no `still in use` at shutdown.
- **Physics layers are coherent and match the named scheme.** `project.godot:155-161` names world/player/enemy/player_attack/enemy_attack/interactable/pickup = bits 1/2/4/8/16/32/64; every `.tscn` I sampled uses the matching integer (chest layer 32 mask 0, projectile layer 16 mask 3, spell_projectile layer 8 mask 5, pickup layer 64 mask 2). No magic-number collisions.
- **Decoupling is real.** `event_bus.gd` is a typed, domain-organised signal bus (player/enemy/status/quest/inventory/UI/sfx); systems communicate through it rather than holding cross-references. Autoloads are 8, ordered with `Telemetry` first so engine errors are captured before anything can throw.
- **No circular-dependency smell surfaced** in the autoload/DB layer; `Combinations` documents its one-way dependency on `StatusComponent` explicitly (`combinations.gd:13`).

---

## 2. Scores (0–10)

| Criterion (engineering reading) | Weight | Score | One-line justification |
| --- | --- | --- | --- |
| Полнота требований (requirements coverage, eng.) | 0.175 | 8 | §19 bot + §20 logs + §21 QA all have real implementations; gaps are §20.1 screenshots (raised in R2). |
| Корректность систем (correctness) | 0.225 | 9 | 0 Godot-3 leftovers, 0 runtime errors, coherent collision layers, 99% typed. |
| Архитектура и границы (architecture/boundaries) | 0.15 | 7 | EventBus + clean autoloads, but GameState god-object and `npc`/`npcs` split. |
| Структуры данных и расширяемость (data/extensibility) | 0.15 | 7 | Consistent JSON + defensive facades, but no schema validator and nine parallel loaders. |
| Техническая надёжность (technical reliability) | 0.30 | 8 | Clean headless run, no leaks, no invalid refs; extensibility is the soft edge. |

Weighted mean = 8·0.175 + 9·0.225 + 7·0.15 + 7·0.15 + 8·0.30 = **7.6**. Reported **7.5** (rounded
down for the unvalidated data contract, which is the one place a silent defect can still enter).

---

## 3. Verdict

**APPROVE WITH CONDITIONS.** The architecture passes the §22.2 gate: correct API for the installed
engine, no monolith that blocks work, no circular coupling, clean data path to testability. Nothing
here is a P0/P1, so per §22.2 mass development is not blocked by engineering.

Closing criteria for the conditions (all P2/P3, may ship with written risk acceptance):
- **G1**: a data-validation test that fails on a missing/misspelled required key in any `data/*.json`.
- **G2**: GameState delegates inventory/equipment/progression to sub-objects (or a written note that
  the god-object is accepted for save-cohesion reasons).
- **G3/G4/G5**: directory rename, shared loader helper, export exclude for dev code.

## 4. What I could not verify in this round
- Whether any two autoloads hold a hard reference to each other at runtime (I read the bus and the DB
  facades, not every `get_node()` call site); I found no evidence of a cycle but did not exhaustively
  trace all cross-autoload lookups.
- Scene-level coupling inside the 2727-line `hud.gd` (deferred to R3 maintenance review).
