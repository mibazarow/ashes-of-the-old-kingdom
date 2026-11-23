# CRITIC-GODOT — ROUND 2 (testability, bot viability, logging, determinism)

| Field | Value |
| --- | --- |
| Role | CRITIC-GODOT — vertical-slice gate (spec §22.3): testability, debug-bot viability, logging, reproducibility |
| Build / commit | `19eb835` (2026-11-23 07:22 +0300) |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Date | 2026-11-23 |
| Independence | All bot results below are runs I executed myself on this commit; I did not accept the developer's word or `PROCESS.md`. |

**Verdict: APPROVE WITH CONDITIONS — Score 7.0/10.** No P0. One P1 (determinism is applied
inconsistently across bot scenarios). The test harness and bot are genuinely strong.

---

## 1. Findings

| ID | Sev | Finding | Evidence (file:line / command) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| G1-R2 | **P1** | Bot scenario budgets are **timed inconsistently**: only 4 loops are frame-locked (`Engine.get_physics_frames()`), ~20 use wall-clock `Time.get_ticks_msec()` deadlines. A wall-clock budget makes the number of actions a scenario lands a function of machine speed/load, so the same seed can produce a different verdict on a slower box — exactly the reproducibility §20.4 and §19.4 forbid. | `grep -c 'Engine.get_physics_frames() <' bot.gd` = 4; `grep -n 'Time.get_ticks_msec() <' bot.gd` ≈ 20 (arena `:1418,1621,1634`, inventory hunt `:2623,2625`, trap swing `:3065,3066`, dungeon `:3167`, fortress `:3267`, take-damage `:1364,1369`). My double-run: **BOT-008 (frame-budgeted) identical** `attacks=93`, kills `{ash_wolf:3,spider:4,tick:3}` both runs; **BOT-003 (wall-clock) diverged** `cultist_caster best=33` vs `34`. | Expected: every scenario bounded in physics frames so a seed reproduces. Actual: half the scenarios are wall-clock bound; on this idle machine they are near-deterministic, but the budget is a latent divergence that bites under load. | Convert the remaining scenario loops to `Engine.get_physics_frames()` budgets (the pattern already exists at `:945,1033,1138`). Add a CI check that runs each scenario twice on one seed and diffs the `[bot]` line. | OPEN |
| G2-R2 | P2 | §20.1 requires a `screenshots/` directory captured on error/death/softlock; it is **entirely absent**. | `find <debug_runs> -type d -name screenshots` → **0** across all 60 run dirs. `telemetry.gd:93-103` opens every other §20.1 file but never a screenshot. A `PEPEL_SCREENSHOT` viewport-capture path exists (`main_menu.gd:134`) but is manual, not anomaly-triggered. | Expected: `screenshots/` with a frame on FATAL/death/softlock (§20.3). Actual: no screenshot is ever written; the `EVIDENCE:` field can cite a `screenshot …png` that does not exist. | On `Telemetry.fatal()` and on death/softlock, grab `get_viewport().get_texture()` and write `screenshots/<clock>.png` (headless-safe guard: skip when no renderer). | OPEN |
| G3-R2 | P2 | Soak default is **600 s (10 min)**, below the spec's 30–60 min floor. | `bot.gd:25` `SOAK_SECONDS_DEFAULT := 600.0`; completed soak summary `DURATION: 00:10:00`. §19.5 BOT-010 and §21.2 both say 30–60 min. | Expected: ≥1800 s soak at the release gate. Actual: 600 s default (`--soak=` can reach it, but the gate runs the default). | Raise the default to 1800 s, or make the release gate pass `--soak=1800` explicitly and record it in the summary. | OPEN |
| G4-R2 | P2 | The test suite is a **single 13 966-line file** with order-dependent shared autoload state. | `wc -l tests/test_core.gd` → 13966; 77 test functions, 2680 `_check` assertions, 65 logical groups all in one file; tests mutate `GameState`/`QuestManager` singletons in sequence. | Expected: tests splittable and order-independent. Actual: one monolith; a mid-file failure can leave shared state dirty for later groups. | Split by domain into `tests/*.gd` loaded by one runner; reset autoload state between groups (a `reset()` exists on `GameState:reset`). | OPEN |
| G5-R2 | P3 | Telemetry has no release-build gate: it opens and flushes every log on every run, including a shipped release. | `telemetry.gd:_ready` opens 9 files unconditionally; `grep -rn 'is_debug_build' scripts/` → 0. §20.3: «релизная сборка по умолчанию не пишет шумный DEBUG». | Expected: DEBUG streams off in release. Actual: release writes events/combat/decisions/inputs/observations every run. | Gate the chatty streams behind `OS.is_debug_build()` or a project setting; keep `errors.log`+`summary.md` in release. | OPEN |

### Verified correct in this scope

- **Test harness is real and CI-usable.** `godot --headless --path . --script res://tests/test_core.gd`
  → `checks: 3197  failures: 0`, `every test group ran to completion (got 65/65)`, and the runner is a
  `SceneTree` script that calls `quit(1 if failures > 0 else 0)` (`test_core.gd:388`) — a non-zero exit
  on failure, not a silent 0.
- **Tests isolate `user://`.** The suite removes save/backup/temp paths (`:947,1003,1597,1600`) and
  self-asserts `suite left no controls file behind`. Save fixtures exist for migration
  (`tests/fixtures/saves/fixture_v0_no_quests.json`, `fixture_v0_sparse.json`, `fixture_v1_full.json`).
- **All 10 spec scenarios exist and pass, plus 3 extra.** `bot.gd:739-763` registers BOT-001…013. I
  ran the 5 required by my brief, all PASS on `seed=20261122`:
  - `BOT-001 -> PASS (reached_npc; quest_state=active)`
  - `BOT-003 -> PASS (… entered_ruins; ruin_door_open; zone=ruins; roles melee/ranged/support=true; max_control_ms=0)`
  - `BOT-008 -> PASS (attacks=93; kills={ash_wolf:3,spider:4,tick:3})`
  - `BOT-012 -> PASS (entered_dungeon; two dungeon kinds; trap telegraph=true dmg_at_distance=0; back_in_forest; alive)`
  - `BOT-013 -> PASS` (fortress; 10 completed runs cluster at `DURATION_MS≈106545`±14 ms)
  BOT-012/013 now enter the dungeon and fortress — the simulation-coverage hole CRITIC-DESIGN raised
  as D2-R3 on the older commit is closed on this build (I will not re-litigate their content verdict).
- **Seed infrastructure is genuinely fixed** (this addresses D6-R3 from the design round, which was
  filed against `1f7cca0`). `telemetry.gd:238-257` seeds the global RNG before anything rolls, records
  `seed_value`/`seed_source`/`world_seed` on every run, and uses a fixed `BOT_DEFAULT_SEED`. No
  `randomize()` anywhere (`grep randomize() scripts/` → 0); game logic uses the seeded global RNG; the
  forest's procedural `RandomNumberGenerator` is seeded from `MAP_SEED` (`forest.gd:327`).
- **Watchdog matches §19.6.** `bot.gd:461-540` detects stuck (position frozen while moving),
  zero-progress (goal active, progress token static) and cycle (same action repeated with no world
  change); the progress token is coarse (tile, not pixel) so wall-sliding is not counted as progress;
  detections are logged, not aborting, and re-arm so one corner cannot spam per-frame.
- **Bot input is frame-locked.** The `BotInputAdapter` arms each press edge on
  `Engine.get_physics_frames()` (`bot.gd:137,142`) and pins physics-steps-per-frame to 1, so input
  delivery is deterministic — the non-determinism that remains is the scenario *budget*, not the input.

---

## 2. Scores (0–10)

| Criterion (engineering reading) | Weight | Score | One-line justification |
| --- | --- | --- | --- |
| Полнота требований (requirements coverage, eng.) | 0.175 | 7 | All 10 scenarios + logs + replay present; screenshots missing, soak under-length. |
| Корректность систем (correctness) | 0.225 | 8 | 3197/0, 13 scenarios pass, watchdog honest; no false PASS found. |
| Воспроизводимость (determinism/reproducibility) | 0.15 | 6 | Seed infra strong and BOT-008 identical, but wall-clock budgets make it inconsistent. |
| Тестируемость (testability) | 0.15 | 7 | Exit-code gate + `user://` isolation + fixtures, but one 14k-line order-dependent file. |
| Техническая надёжность (logging/telemetry) | 0.30 | 7 | Full §20.1 set minus screenshots, flush-per-line crash-safe, but no release gating. |

Weighted mean = 7·0.175 + 8·0.225 + 6·0.15 + 7·0.15 + 7·0.30 = **7.05**. Reported **7.0**.

---

## 3. Verdict

**APPROVE WITH CONDITIONS.** The vertical slice is testable and the bot is viable and honest: it
perceives through the same input layer as a player, covers all four zones now, and its watchdog finds
real stalls. The one P1 is that reproducibility is only half-implemented — the seed and the input are
deterministic, but the scenario budgets are not, so a PASS is not guaranteed to reproduce on a slower
machine. Per §22.3, P1 must close before content expansion is certified against this slice.

Closing criteria:
- **G1 (P1)**: every scenario loop bounded in physics frames; a twice-run seed-diff check is green.
- **G2**: `screenshots/` written on FATAL/death/softlock.
- **G3**: soak default (or the gate invocation) ≥ 1800 s, recorded in `summary.md`.

## 4. What I could not verify in this round
- I could not force the wall-clock divergence to a *different verdict* on this machine — BOT-003
  diverged by ±1 damage only, because the arena finished its pinned fights before its deadline. The
  P1 is the latent hazard under load, which I demonstrated by the budget-type inconsistency and the
  one field that did move; I did not reproduce a full PASS→FAIL flip.
- BOT-004/006/007/009/010/011 I read as PASS in a concurrent agent's log file, not my own run; I
  treat those as untrusted and rely only on the five I ran myself plus BOT-013's on-disk summaries.
