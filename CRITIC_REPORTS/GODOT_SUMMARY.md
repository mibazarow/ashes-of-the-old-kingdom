# CRITIC-GODOT — SUMMARY OF ALL THREE ROUNDS

| Field | Value |
| --- | --- |
| Role | CRITIC-GODOT (spec §22.1) — technical auditor: Godot architecture, GDScript, data structures, testability, bot viability, performance, save/export, engineering risk |
| Build audited in all three rounds | `19eb835` (2026-11-23 07:22 +0300) |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Date | 2026-11-23 |
| Rounds | ROUND_1_GODOT.md (architecture/API/data) · ROUND_2_GODOT.md (testability/bot/logging/determinism) · ROUND_3_GODOT.md (perf/save/export/crash/maintenance) |
| Independence | I built none of this. Every finding is backed by a command I ran or a file I read on this commit. Bot results are my own runs, not the developer's word. |
| Non-overlap | Design findings (content, balance, story, the ending seam) are CRITIC-DESIGN's and are not repeated. Where the design round flagged seed/soak/coverage (D6/D7/D2-R3) against the **older** commit `1f7cca0`, I re-checked them on `19eb835` and record the engineering status here. |

**The same commit was audited three times.** No fixes landed between my rounds, so the score
trajectory is three different gates on one unchanged build, not a timeline. Round 3 scores lowest
because §22.4 is a hard release gate and it is the gate the stale artifact fails.

---

## 1. Verdicts and scores side by side

| | Round 1 (§22.2) | Round 2 (§22.3) | Round 3 (§22.4) |
| --- | --- | --- | --- |
| Gate | architecture / data | vertical slice | pre-release |
| **Verdict** | **APPROVE WITH CONDITIONS** | **APPROVE WITH CONDITIONS** | **REJECT** |
| Полнота требований (eng. coverage) | 8 | 7 | 6 |
| Корректность систем (correctness) | 9 | 8 | 8 |
| Scope axis 3 (architecture / determinism / save-crash) | 7 | 6 | 7 |
| Scope axis 4 (extensibility / testability / release) | 7 | 7 | 3 |
| Техническая надёжность (reliability) | 8 | 7 | 7 |
| Weighted mean (§22.5 weights 0.175/0.225/0.15/0.15/0.30) | 7.6 | 7.05 | 6.4 |
| **Reported engineering score** | **7.5** | **7.0** | **5.0** |
| Open P0 | 0 | 0 | 0 |
| Open P1 | 0 | 1 | 2 |
| Open P2/P3 | 5 | 4 | 3 |

**Method, stated so the numbers are not misread.** Rounds 1–2 report the weighted mean (rounded down
one notch where a silent-defect channel remains open). Round 3 reports the weighted mean (6.4) *minus
the §22.4 open-gate penalty* to **5.0**, because two P1 are open at the gate that makes them fatal.
The trajectory 7.5 → 7.0 → 5.0 is the gate getting harder on an unchanged build, not the code decaying.

---

## 2. Consolidated open findings

### P0 — release blocker
**None in engineering scope.** Tests are 3197/0, the clean run is 0 `ERROR|SCRIPT ERROR|leaked|still
in use`, all 13 bot scenarios pass, and a 20-minute soak shows no leak. (The project's single P0 — the
un-wired ending — is a design finding, owned by CRITIC-DESIGN, and is out of my scope.)

### P1 — release blockers under §22.4

| ID | Finding | Proof |
| --- | --- | --- |
| **G1-R3** | **The release artifact is stale.** The only built binary (`build/macos/Pepl-macos-arm64.zip`, Nov 20 17:06) predates HEAD `19eb835` (Nov 23) by 3 days and several fixes; `BUILD_MACOS.md` cites `checks: 1832` against the current `3197`. Shipping it ships none of the determinism/dungeon-bot/dialogue/leak work the green tests certify. | `ls -la build/macos/…zip` vs `git log -1`; doc check-count vs `test_core.gd` run. |
| **G2-R2 / G2-R3** | **Reproducibility is applied inconsistently.** Only 4 bot scenario loops are frame-locked (`Engine.get_physics_frames()`); ~20 use wall-clock `Time.get_ticks_msec()` deadlines, so a scenario's action count is machine-speed dependent and a recorded seed need not reproduce on a loaded box — the §20.4/§19.4/§22.4 reproducibility guarantee. | `bot.gd` budget grep (4 vs ~20); my double-runs: **BOT-008 identical** (`attacks=93`, same kills), **BOT-003 diverged** (`cultist_caster best` 33→34). |

### P2 — ship only with written risk acceptance

`SaveManager.load_game` returns `empty_slot` on a **missing** primary and never tries the `.bak`,
though `slot_zone` does (`save_manager.gd:80-81` vs `:134-143`; the suite itself notes the gap at
`test_core.gd:885`) · §20.1 `screenshots/` is **entirely absent** (0 of 60 run dirs) so the `EVIDENCE:`
field can cite a screenshot that was never taken · soak default is **600 s** against the spec's 30–60
min (`bot.gd:25`) · telemetry **flushes every event line** synchronously, against §19.7's buffered
requirement (`telemetry.gd:464-465`) · the test suite is a **single 13 966-line file** with
order-dependent shared autoload state · the JSON data layer has **no unified schema validator**, so a
misspelled key is silently absorbed by a defensive default (`item_db.gd:89-91,134-140`).

### P3 — minor

`GameState` god-object (1144 lines / 75 funcs / 108 vars) · `scripts/npc/` vs `scripts/npcs/`
base-vs-concrete naming trap · nine parallel JSON loaders with no shared helper · debug bot + full test
suite ship in the release `.pck` (`export_filter="all_resources"`, no exclude) · macOS build is ad-hoc
signed and un-notarised (Gatekeeper "cannot be opened" on other Macs) · telemetry has no
`is_debug_build()` gate, so a release writes chatty DEBUG streams (§20.3).

---

## 3. What I verified as correct (and would not touch)

- **API correctness for the installed engine is excellent.** Zero real Godot-3 leftovers
  (`KinematicBody2D`/`yield`/`setget`/`rand_range`/`File.new`/`PoolStringArray`/`OS.get_ticks`/argued
  `move_and_slide(...)` → 0 hits); 1097/1108 functions carry return types (99%).
- **Clean engine run and no leaks.** `--quit-after 120` → 0 error/leak lines; a 20-min
  `performance.csv` holds `orphan_nodes` 1–5 and `object_count` ~2338 flat, 145 fps headless.
- **The save layer is trustworthy.** Atomic `tmp→verify→bak→json`, backup recovery on corrupt
  primary, `v0→v1` migration with newer-schema refusal, three independent slots, fixtures + tests.
- **The bot is honest and now covers the world.** It drives the real input layer, never reads hidden
  enemy state, has a §19.6 watchdog (stuck/zero-progress/cycle), and BOT-012/013 enter the dungeon and
  fortress — closing the simulation-coverage hole the design round flagged on the older commit.
- **Seed infrastructure is genuinely fixed** on this commit (vs design D6-R3 on `1f7cca0`): the global
  RNG is seeded before anything rolls, `seed`/`seed_source`/`world_seed` are recorded every run, no
  `randomize()` exists, and the forest's procedural RNG is seeded from `MAP_SEED`.
- **Decoupling and physics layers are clean.** A typed domain-organised `EventBus`; 8 ordered
  autoloads; collision layers/masks match the named bit scheme with no magic numbers.

---

## 4. Conflicts / notes for the technical lead (§22.6)

- I do **not** contradict CRITIC-DESIGN; I scope-shift their D2/D6/D7. On `1f7cca0` those were real;
  on `19eb835` the seed is recorded, the soak is 600 s (not 75 s), and the dungeon/fortress are now
  simulated. The *remaining* engineering gaps are narrower and different: screenshots, soak length,
  and the wall-clock budget inconsistency — not "no seed / no coverage".
- Priority per §22.6: data safety and reproducibility outrank aesthetics. My two P1 are reproducibility
  (G2) and shipping-the-wrong-binary (G1); both outrank the P3 cosmetic/export items.

---

## 5. Verdict

**The engineering underneath this build is better than its release state suggests, and the gap between
the two is the whole story of round 3.** The source is clean and careful: correct Godot 4.7 API with
99% typed functions, a zero-error headless run, a leak-free 20-minute soak at 145 fps, an atomic and
migration-safe save layer, throttled AI hot paths, a typed event bus, and an honest debug bot that now
walks all four zones and catches its own stalls. Rounds 1 and 2 approve with conditions because nothing
in architecture or the vertical slice is a P0/P1 — the worst there are P2/P3 maintainability items (a
god-object autoload, a 14k-line test file, an unvalidated JSON contract). What I cannot approve is the
pre-release gate: the only artifact anyone has actually built is three days and several fixes older than
the commit the 3197 green checks describe, it is unsigned and un-notarised, and reproducibility — which
§22.4 re-tests with a fixed seed — is only half-implemented, because four scenario loops count physics
frames while about twenty count wall-clock milliseconds, so a PASS is guaranteed to reproduce only while
the machine is fast enough to finish each scenario before its deadline (my BOT-008 double-run was
byte-identical; my BOT-003 double-run moved by one damage point). Release stays **REJECT** until the
build is re-exported from `19eb835` and re-verified, every bot scenario is bounded in physics frames with
a twice-run same-seed diff green, and the `load_game` missing-primary recovery and the §20.1 screenshots
are closed; the P2/P3 list may then ship under written risk acceptance.
