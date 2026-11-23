# CRITIC-GODOT — ROUND 3 (pre-release engineering: performance, save safety, export, crash resilience, maintenance risk)

| Field | Value |
| --- | --- |
| Role | CRITIC-GODOT — pre-release gate (spec §22.4): performance, save safety, export, crash resilience, maintenance risk |
| Build / commit | `19eb835` (2026-11-23 07:22 +0300) |
| Shipped artifact | `build/macos/Pepl-macos-arm64.zip` dated **2026-11-20 17:06** — 3 days / many commits behind HEAD |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Date | 2026-11-23 |

**Verdict: REJECT — Score 5.0/10.** No P0. Two P1 open at the release gate. The running code is
reliable and leak-free, but the thing that would actually ship is a stale, unsigned binary that does
not contain the fixes the green tests describe. §22.4 forbids release with any open P1.

---

## 1. Findings

| ID | Sev | Finding | Evidence (file:line / command) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| G1-R3 | **P1** | The **release artifact is stale**: the only built binary predates the determinism, dungeon/fortress-bot, NPC-dialogue and audio-leak fixes that the current tests certify. Shipping it ships none of that work. | `ls -la build/macos/…zip` → `Nov 20 17:06`; `git log -1` → `19eb835 … 2026-11-23 07:22`. `docs/BUILD_MACOS.md` cites `checks: 1832` while the suite is now `3197`. | Expected (§21.2/§23 stage 9): a clean build **of current code** at the release gate. Actual: a 3-day-old binary whose test count is 1365 checks behind. | Re-export from `19eb835` and re-run the §21.2 checklist against the rebuilt artifact before any release. | OPEN |
| G2-R3 | **P1** | Reproducibility is not release-safe (carried from R2 G1): wall-clock scenario budgets mean a release-gate "re-run with the same seed" (§22.4) is not guaranteed to reproduce on a different/loaded machine. | `bot.gd` — 4 frame-budget loops vs ~20 `Time.get_ticks_msec()` deadlines; my BOT-003 double-run moved `cultist_caster best` 33→34. | Expected: identical verdict from the recorded seed on any box. Actual: verdict stable only while the machine is fast enough to finish each scenario before its wall-clock deadline. | Same fix as R2 G1: bound every scenario in physics frames; add a twice-run seed-diff gate. | OPEN |
| G3-R3 | P2 | `SaveManager.load_game` returns `empty_slot` for a **missing** primary file and never consults the `.bak`, while `slot_zone` does fall back to backup — inconsistent recovery. A crash in the window between `rename(final→bak)` and `rename(tmp→final)` leaves a good `.bak` and `.tmp` on disk but the slot reads as empty. | `save_manager.gd:80-81` (`if not file_exists(path): return empty_slot`) vs `:134-143` `slot_zone` calls `_try_backup` on missing. The suite even notes the gap: `test_core.gd:885` "an absent primary reports empty_slot". | Expected: a missing primary with a valid backup recovers (or at least matches `slot_zone`). Actual: the save is present on disk but reported empty. | In `load_game`, when the primary is missing, try `_try_backup` (and optionally promote `.tmp`) before returning `empty_slot`; add a test for missing-primary-with-backup. | OPEN |
| G4-R3 | P2 | Telemetry flushes **every event line synchronously** to disk. §19.7 requires heavy recording be buffered and not cost the FPS budget. | `telemetry.gd:464-465` `f.store_line(...); f.flush()` on every `event/combat/decision/input/observation`. | Expected: buffered writes flushed on interval/anomaly/exit. Actual: one `flush()` per event; a combat-heavy soak writes thousands of forced flushes. | Buffer per stream, flush on the 1 s perf tick, on anomaly, and in `_exit_tree` (which already closes all). | OPEN |
| G5-R3 | P3 | macOS build is unsigned/un-notarised: preset sets `codesign=1` but `identity`/`apple_team_id` are empty and `notarization=0`; the doc says the binary is re-signed ad-hoc. | `export_presets.cfg:74-92`; `docs/BUILD_MACOS.md` "переподписан ad-hoc". | Expected: a distribution-ready signed+notarised build, or a documented Gatekeeper caveat. Actual: ad-hoc only — other Macs show "cannot be opened". | Either notarise, or record the Gatekeeper right-click-open step as a known limitation in the release notes. | OPEN (documented) |

### Verified correct in this scope

- **No leak over a long run.** A 20-minute run's `performance.csv` (1205 rows): `orphan_nodes` stays
  1–5 (max 5), `object_count` flat at ~2338 from t=200 s to t=1200 s, steady `fps=145.00` headless.
  `awk` over the file: `orphan_max=5 object_max=2573`. The completed soak `BOT-010` reports
  `ERRORS: 0 FATAL: 0` and `RESULT: PASS`. The audio-leak fix the commit claims holds up in the data.
- **Hot paths are throttled, not per-frame.** Enemy AI caches the player ref and only re-looks-up when
  invalid (`enemy.gd:543-547`); the pack-bonus group scan and the cultist aura heal are gated behind
  `PACK_REFRESH_INTERVAL`/`AURA_INTERVAL` ("a few times a second, not 60", `enemy.gd:674-735`); there
  is a bounded death pool (`DEATH_POOL_MAX := 3`). The `get_nodes_in_group("enemy")` in
  `combinations.gd:141` is event-driven (on a shock hit), not in `_process`.
- **Save layer is strong.** Atomic `tmp → flush → read-back verify (length + JSON) → rename to .bak →
  rename tmp to final` (`save_manager.gd:43-70`); backup recovery on a *corrupt* primary; `v0→v1`
  migration and **refusal of newer schemas** (`:154-163`), tested (`test_core.gd:1067-1077`). Three
  independent slots.
- **Crash resilience of logs is good.** Every stream flushes on write and `_exit_tree` flushes+closes
  all nine handles (`telemetry.gd:558-563`); a custom `OS.add_logger` mirrors engine stderr into
  `errors.log` with severity parsed off the line (`:420-433`), so a run that dies still leaves its
  errors on disk.
- **Export templates are present and the macOS recipe is honest.** `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`
  exists; `BUILD_MACOS.md` correctly explains the universal→`lipo -thin arm64`→ad-hoc path and the
  `import_etc2_astc=true` requirement. The doc is accurate about *how*; it is only stale about *when*.

---

## 2. Scores (0–10)

| Criterion (engineering reading) | Weight | Score | One-line justification |
| --- | --- | --- | --- |
| Полнота требований (requirements coverage, eng.) | 0.175 | 6 | §21.2 release checklist not satisfiable: stale artifact, screenshots absent, soak short. |
| Корректность систем (correctness) | 0.225 | 8 | Tests 3197/0, bots pass, no leaks; the running code is correct. |
| Надёжность сохранений и краш-устойчивость (save/crash) | 0.15 | 7 | Atomic+migration strong; `empty_slot`-on-missing gap and unbuffered flushes. |
| Сборка и релиз (export/release readiness) | 0.15 | 3 | Stale binary, unsigned/un-notarised, ships dev code, doc 1365 checks behind. |
| Техническая надёжность (perf + maintenance) | 0.30 | 7 | No leak, 145 fps, throttled hot paths; maintenance risk from god-object + 14k test file. |

Weighted mean = 6·0.175 + 8·0.225 + 7·0.15 + 3·0.15 + 7·0.30 = **6.4**. The §22.4 gate is a hard
release gate and two P1 are open, so the reported score is penalised to **5.0** and the verdict is
REJECT — the penalty reflects that the *artifact*, not the source, is what fails this gate.

---

## 3. Verdict

**REJECT (release blocked).** This is not a verdict on the code, which is reliable: leak-free over 20
minutes, atomic and migration-safe saves, crash-safe logs, throttled hot paths, 3197 green checks. It
is a verdict on release readiness. The only built binary is three days and several fixes older than the
commit the green tests describe, it is unsigned and un-notarised, and reproducibility — the thing §22.4
explicitly re-tests with a fixed seed — is only half-implemented. Releasing now would ship a build that
does not contain the work the reports cite as proof.

Closing criteria (all must be green before release):
- **G1 (P1)**: re-export from `19eb835`; re-run §21.2 against the rebuilt artifact; refresh
  `BUILD_MACOS.md` to the current check count.
- **G2 (P1)**: every bot scenario bounded in physics frames; a twice-run same-seed diff is identical.
- **G3**: `load_game` recovers a missing primary from `.bak`; add the missing-primary-with-backup test.
- **G4**: telemetry writes buffered, flushed on tick/anomaly/exit.
- **G5**: notarise, or record the Gatekeeper limitation in the release notes.

## 4. What I could not verify in this round
- I did not run the 30–60 min soak myself (the default is 10 min); my leak conclusion is from a
  20-minute `performance.csv` already on disk plus the 10-min soak summary, not a fresh half-hour run.
- I did not export a fresh build (exporting is a mutating action outside my read-only brief), so the
  staleness finding is from artifact timestamp + doc check-count, not from a rebuild-and-compare.
- I did not launch the `.app` on a second Mac, so the Gatekeeper consequence of ad-hoc signing is
  reasoned from the preset/doc, not observed.
- One 20-min BOT-013 run on disk has no `summary.md` (last decision event at 97 s, perf to 1200 s);
  I could not tell whether that was a developer kill or a scenario deadlock, so I did not raise it as a
  finding — but it is consistent with the watchdog never aborting a hung scenario, worth a look.
