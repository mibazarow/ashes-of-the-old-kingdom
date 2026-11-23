# CRITIC REPORT — ROUND 3 (pre-release audit)

| Field | Value |
| --- | --- |
| Round | 3 |
| Date | 2026-11-21 |
| Role | CRITIC-DESIGN (spec §22.1 / §22.4) |
| Scope | Pre-release gate per §22.4: all critical story paths, side quests, economy, bosses, death/load, three save slots, settings, UI, long-session stability, re-run of critical scenarios with the same seed, visual inspection of every zone |
| Build / commit | `1f7cca0` — **the same commit as rounds 1 and 2** |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Prior rounds | ROUND_1_DESIGN.md REJECT (1×P0, 5×P1) · ROUND_2_DESIGN.md REJECT (1×P0, 5×P1) |

## Verdict up front

**REJECT.** One open P0 and six open P1.

I want to be precise about what the score drop means. **Nothing regressed** — the build is
byte-identical to the one I audited twice already. The score falls because §22.4 asks harder
questions than §22.2 and §22.3 do, and this build cannot answer them: it cannot be finished, it
cannot be re-verified from a seed, it has never been soak-tested for longer than 75 seconds, and
the last two zones of the game have never been entered by any automated scenario at all.

---

## Evidence base (new commands run for this round)

```
$ godot --headless --path . --script res://tests/test_core.gd 2>&1 | tail -2
checks: 2919  failures: 0                     # re-run, still green

$ godot --headless --path . --script res://CRITIC_REPORTS/probe_curve.gd
CURVE[forest]   regulars=18 avg_hp=27.1 avg_dmg=7.6 avg_xp=14.3 avg_gold=6.9 | zone_xp=578 zone_gold=274 | kinds=11
CURVE[ruins]    regulars=11 avg_hp=33.5 avg_dmg=9.0 avg_xp=20.2 avg_gold=9.5 | zone_xp=482 zone_gold=224 | kinds=7
CURVE[dungeon]  regulars=10 avg_hp=25.8 avg_dmg=8.0 avg_xp=17.6 avg_gold=8.1 | zone_xp=496 zone_gold=231 | kinds=6
CURVE[fortress] regulars=10 avg_hp=32.3 avg_dmg=9.3 avg_xp=21.5 avg_gold=10.7 | zone_xp=815 zone_gold=407 | kinds=7

$ godot --headless --path . --script res://CRITIC_REPORTS/probe_reach.gd
REACH[forest]   grid=52x32 walkable=1230 reachable=1224 unreachable=6 sealed_by_solids=1 unpainted=0 start=(4, 9) samples=["26,1(open=0)", "50,1(open=1)", "50,2(open=2)", "50,3(open=1)", "12,30(open=1)", "13,30(open=1)"]
REACH[ruins]    grid=40x26 walkable=862  reachable=862  unreachable=0 unpainted=0
REACH[dungeon]  grid=44x28 walkable=591  reachable=591  unreachable=0 unpainted=0
REACH[fortress] grid=48x30 walkable=1080 reachable=1080 unreachable=0 unpainted=0

# §22.4 requires re-running the critical scenarios with the same seed. I tried. Two runs of
# the same scenario, same binary, same commit, nothing else on the machine:
$ godot --headless --path . -- --bot=BOT-008   # run 1
[bot] BOT-008 -> PASS (attacks=94; kills={ "ash_wolf": 3, "spider": 5, "tick": 3, "slime": 1 })
$ godot --headless --path . -- --bot=BOT-008   # run 2
[bot] BOT-008 -> PASS (attacks=85; kills={ "ash_wolf": 3, "tick": 3, "spider": 2, "slime": 1 })
$ diff /tmp/det_1.txt /tmp/det_2.txt
DIVERGED

$ python3 -c "…read assets/sprites/tiles.png…"
tiles.png 64 x 16  colortype 6 (RGBA8)
tile 0 grass RGBA(173,188,58,255)   tile 1 dirt  RGBA(255,173,93,255)
tile 2 stone RGBA(95,113,96,255)    tile 3 tree  RGBA(19,36,22,255)
# centre pixel == corner pixel on every tile: flat single-colour swatches, no texture

$ python3 -c "…quest xp sum…"
quest xp total 1030
```

New read-only probes for this round, all under `CRITIC_REPORTS/`: `probe_curve.gd`,
`probe_reach.gd`. Round-1/2 probes (`probe_ending.gd`, `probe_path.gd`, `probe_census.gd`,
`probe_respawn.gd`) were re-run where their findings are carried below.

---

## Findings

| ID | Severity | Finding | Evidence (file:line or command output) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| D1-R3 | **P0** | **The game still cannot be finished.** Carried from D1-R1/D1-R2 and re-verified on this build. The throne toasts and does nothing; `EndingAltar.choose()` has no caller outside the test file. | `CRITIC_REPORTS/probe_ending.gd` → `PROBE prompt_after_king_dead=Выбрать судьбу`, `PROBE ending_after_interact=` (empty), `PROBE has_choose_hook=false`. `scripts/world/ending_altar.gd:59-69` — `interact()` has three branches, all `EventBus.toast.emit(...)`, none of them sets `GameState.ending`. `scripts/ui/hud.gd:2378-2380` — the code's own comment: *"nothing in the world does today"*. | Expected (§22.4: "Проверить все критические сюжетные пути"; TZ §1.3 P0 row "завершение сюжетной цепочки"): the final interact commits one of three fates and opens the victory screen. Actual: `GameState.ending == ""` forever; no victory screen, no credits, no completion state reachable by a human. | Ship a three-row altar choice surface (↑↓ + E, same input style as the defeat panel) calling `EndingAltar.choose()`, plus a bot scenario that finishes the game through the HUD and asserts a non-empty `GameState.ending`. | open |
| D2-R3 | **P1** | **No automated scenario ever enters the dungeon or the fortress.** The two final zones, two of the five bosses and the finale have zero simulation coverage, so §22.4's "check all critical story paths" is not merely failing — it is unmeasured. | `grep -rn "travel(\|zone_id" tests/` finds no bot scenario that travels to `dungeon` or `fortress`; the only fortress/dungeon mentions in `tests/test_core.gd` are dialogue-flag unit tests (e.g. line 12363, the fortress pilgrim fragment). BOT-003, the longest traversal bot, ends `zone=ruins`. My own probes had to force `manager.call("travel", "dungeon")` to get eyes into those zones at all. | Expected (§22.4: all critical story paths, bosses, death/load checked; §23 stage 5 gate: "Каждая зона имеет тестовый маршрут, точки входа/выхода"; stage 6: "Все боссы победимы; сценарии победы/поражения тестируются ботом"): a route per zone and a kill scenario per boss. Actual: 2 of 4 zones and 3 of 5 bosses are never fought by anything that runs. | Add BOT-012 (dungeon route + Bell Ringer kill) and BOT-013 (fortress route + King kill), each asserting zone entry, boss phase transitions, boss death, reward-once, and exit. Until they exist, no claim about the late game is verified by anyone. | open |
| D3-R3 | **P1** | **The difficulty curve runs backwards in the middle of the game.** Zone 3 has the weakest regular enemies in the entire build — weaker than zone 1. | `probe_curve.gd` above. Average regular (non-boss) HP by zone: **27.1 → 33.5 → 25.8 → 32.3**. Average damage: 7.6 → 9.0 → 8.0 → 9.3. Per-enemy detail: forest `lumberjack` 52 HP / 15 dmg and `root_beast` 60 HP / 12 dmg vs the dungeon's toughest regular `plague_bearer` 48 HP / 8 dmg. Total zone XP budget: 578 → 482 → 496 → 815 — the **first** zone pays more total XP than the second and third combined-per-zone average. | Expected (TZ §22.1 remit "прогрессия, сложность"; §11 enemy composition per zone; §5 zone table orders the zones as an escalating route): a monotone or at least non-decreasing threat curve. Actual: the player is asked to fight a 60 HP / 12 dmg root beast in the first zone and then, two zones later, a 48 HP / 8 dmg plague bearer. The middle of the game is the easy part, and the reward for reaching it is smaller than the reward for the tutorial clearing. | Re-tune the dungeon regulars above the forest's elite tier (≥65 HP / ≥13 dmg) or reorder the curve so the fortress is the only peak; add a test asserting `avg_hp(zone[n+1]) >= avg_hp(zone[n])` over the live census so the curve cannot silently invert again. | open |
| D4-R3 | **P1** | **The last zone introduces one new enemy.** Content density falls as the game progresses, in every dimension. | New enemy kinds per zone (first appearance): forest 9 regulars + 2 bosses; ruins 6 new (`skeleton`, `skeleton_archer`, `grave_hound`, `shieldbearer`, `royal_guard`, `cultist_caster`) + 1 boss; dungeon 2 new (`bone_crawler`, `plague_bearer`) + 1 boss; **fortress 1 new (`ash_knight`) + 1 boss**, and it re-uses the forest `boar.tscn` (`fortress.gd` spawn list includes `boar`). Live instance counts: 20 / 12 / 11 / 11. Live kind counts including bosses: 11 / 7 / 6 / 7. | Expected (TZ §5: each zone has "свой состав противников"; §1.1 "18+ типов противников" is a floor, not a target; §23 stage 5 gate "Каждая зона имеет … набор сцен"): the finale should be the densest zone in the game. Actual: the finale is a corridor of skeletons, archers, wisps and a boar, of which the player has already killed hundreds. | Give the fortress its own 3–4 hostile kinds (ash knight variants, crown cult officers, a siege enemy), remove the forest boar from it, and raise its instance count above the forest's. | open |
| D5-R3 | **P1** | **All three endings are unconditional; the "hidden" ending is not hidden and not earned.** | `scripts/world/ending_altar.gd:71-84` — `choose()` refuses only when `ending_id` is unknown, the King is alive, or an ending was already taken. There is no flag, quest, seal or count check of any kind. TZ §4.4 line 185: "«Пепельный венец» — **скрытая** концовка при выполнении цепочки хранителя и сборе редких печатей". The pilgrim chain sets `pilgrim_truth_known` (`data/dialogue.json`) and nothing reads it; `rusted_seal` (`data/items.json:179`) is never obtainable (D7-R1, still open). | Expected: `crown` requires the keeper chain plus the rare seals; the other two are reachable by default. Actual: a player who has spoken to nobody, collected nothing and skipped every side thread can pick the "secret" ending on their first visit to the throne. The one piece of writing in the game that pays off (the pilgrim) pays off nothing. | Gate `crown` on `pilgrim_truth_known` plus a seal count, keep `dawn`/`memory` unconditional, and add a test asserting `choose("crown") == false` with the flags absent and `true` with them set. | open |
| D6-R3 | **P1** | **The pre-release re-verification gate cannot be executed: nothing records a seed and the bots do not reproduce.** | §22.4: "минимум критические сценарии запустить повторно с одинаковым seed". TZ §20.4: "Сохранять seed, версию билда, настройки сложности, профиль бота, сценарий, состояние слота и последовательность поданного ввода." `grep -n "seed" scripts/debug_bot/bot.gd` → **one** hit, line 544 (`rng.seed = 4242`, soak only). `grep -rn "seed" scripts/core/telemetry.gd` → **zero** hits. Empirically, two runs of the same scenario on the same binary: BOT-008 `attacks=94; spider:5` vs `attacks=85; spider:2`. | Expected: a critical scenario re-runs identically from a recorded seed, or its random outcomes are logged so a divergence can be explained. Actual: no seed is stored anywhere, no run id ties a log to a seed, and combat scenarios diverge run-to-run. Any "fixed and re-verified" claim made after this round is unfalsifiable. | Record `seed`, build version and profile in every telemetry run header; seed the bot RNG per scenario from that value; make BOT-008/010/011 byte-identical across two consecutive runs and assert it in CI. | open |
| D7-R3 | **P1** | **Long-session stability is unverified: the soak is 75 seconds against a required 30–60 minutes, and there is no watchdog, no replay and no input/observation/performance log.** | §22.4 input list requires "логи soak test"; §23 stage 7 gate: "30–60 минут soak test". `PROCESS.md:380` states it honestly: "остаются soak 30–60 мин (сейчас 75 с), watchdog, детектор циклов, реплей и логи `inputs`/`observations`/`performance`". `PROCESS.md:567` still lists "Детектор циклов и watchdog" unchecked. `PROCESS.md:424` admits "реплея нет". I found no watchdog implementation in `scripts/` either. | Expected: an hour-long session with a stuck-run detector, cycle detector and replayable input log, on which a release decision can rest. Actual: the longest evidence of stability in this project is 75 seconds of a bot that heals itself. Memory growth, leak behaviour, day-cycle drift, NPC schedule accumulation and save-file growth over an hour are all unknown. | Run BOT-010 at 30 min and 60 min with `--seed`, publish the JSONL plus a monitor table (node count, memory, fps) at 5-minute intervals; implement the watchdog and cycle detector before claiming stage 7. | open |
| D8-R3 | **P2** | **The four zones are not visually distinguishable by their tiles: one shared four-colour atlas paints the whole game.** | `scripts/world/zone_base.gd:13` `const ATLAS := "res://assets/sprites/tiles.png"`; `zone_base.gd:85-131` builds one 4-tile atlas (grass/dirt/stone/tree) and `grep -rn "_build_tileset_and_layer" scripts/world/` shows **no zone overrides it**. The atlas is flat swatches: grass RGBA(173,188,58), dirt (255,173,93), stone (95,113,96), tree (19,36,22) — centre pixel equals corner pixel on all four. `dungeon.gd:278-307` paints its floor with `,` (dirt) and `.` (grass) only, so the undercroft floor is the same yellow-green grass tile as the forest clearing. There is no zone-wide grade: `grep -rn "CanvasModulate\|ambient\|fog" scripts/world/` → zero hits; the only `modulate` uses are per-NPC sprite tints (`dungeon.gd:496`, `fortress.gd:453`, `ruins.gd:439`). Screenshots: `/tmp/cd_world.png`, `/tmp/cd_ruins.png`, `/tmp/cd_dungeon.png`, `/tmp/cd_fortress.png`. | Expected (TZ §5 line 191: "У каждой зоны есть **узнаваемая цветовая схема**"; §1.2 "Цельная подача"): four readable zone identities. Actual: the dungeon reads as a bright grass field with grey walls; the fortress as a slightly browner grass field. A player who teleports between zones cannot tell them apart from the floor alone. | Give each zone its own atlas or at minimum a per-zone `CanvasModulate` grade plus a distinct floor tile set; the dungeon needs a stone/flagstone floor, not grass. Note: this overlaps CRITIC-PLAYER's remit (visual integrity) — I raise it as design because it destroys zone identity and the exploration motivation that depends on it, and I expect their report to reach the same place from the art side. | open |
| D9-R3 | **P2** | **The content budget reaches level 12 of a level-20 cap; the remaining eight levels can only be bought with farming, which the TZ forbids.** | Live totals from `probe_curve.gd`: enemy XP 578+482+496+815 = **2371**; quest XP from `data/quests.json` = **1030**; one full clear = **3401 XP**. `data/progression.json`: `max_level: 20`, `xp_curve` reaching 9600. 3401 XP lands between `xp_curve[11]`=3300 and `xp_curve[12]`=3840 → **level 12**. Gold: enemies 1136 + quests 1195 = 2331 for the whole game. Enemies respawn in full on re-entry (`probe_respawn.gd`: `alive_before=20 after_kill=0 after_reentry=20 respawned=true`), so the only way to reach the advertised cap is to kill the same 54 creatures repeatedly. | Expected (TZ §1.1 line 60: "Не растягивать прохождение искусственным гриндом"; §8 progression to a reachable cap): the level cap is either reachable from authored content or the cap matches the content. Actual: a 20-level cap with 12 levels of authored XP, and a respawn system positioned as the gap-filler. | Either set `max_level` to what a full clear delivers (12–13) or author the XP that justifies 20; do not let respawned farming be the answer — it is the one thing the TZ names as forbidden. | open |
| D10-R3 | **P2** | **Settings ship two of the five required sections.** | TZ §16.1 line 666: "Настройки **управления, громкости, масштабирования, окна, визуальной интенсивности и доступности**". `grep -n "func _build\|section" scripts/ui/settings_panel.gd` yields controls and audio only; there is no resolution/scale control, no window-mode toggle, no brightness or visual-intensity option, and no accessibility section. TZ §16.3 line 561 additionally requires "предоставить опции снижения визуальной интенсивности". `PROCESS.md:72` does state honestly "доступности нет". | Expected: five settings sections. Actual: two. A player on a 1080p laptop cannot scale the 480×270 viewport, and a photosensitive player has no way to reduce flash intensity. | Add display (scale, window mode), visual-intensity (flash/screen-shake sliders) and accessibility (damage-number toggle, telegraph-contrast option) sections; persist them separately from progress as §16.1 requires. | open |
| D11-R3 | **P3** | **Six walkable tiles in the forest are unreachable, one of them sealed on all four sides.** | `probe_reach.gd` → `REACH[forest] walkable=1230 reachable=1224 unreachable=6 sealed_by_solids=1 samples=["26,1(open=0)", "50,1(open=1)", "50,2(open=2)", "50,3(open=1)", "12,30(open=1)", "13,30(open=1)"]`. Ruins, dungeon and fortress are clean (`unreachable=0`). | Expected (§22.4 visual inspection: "нет незакрытых пустот в тайлмапе"): every painted floor tile is either reachable or visibly walled off. Actual: tile (26,1) is a floor tile with solid tiles on all four sides — a visible one-tile hole the player can never enter; (50,1)–(50,3) and (12,30)–(13,30) are small pockets cut off by the border/tree cluster. | Erase or wall those six cells in `_generate_map()` for the forest, and keep `probe_reach.gd` as a regression check asserting `unreachable == 0` for every zone. | open |
| D12-R3 | **P3** | **There is no reason to play a second time, and no NG+.** | Full respawn with no cleared-state persistence (D7-R2, still open) plus `grep -rn "ng+\|new_game_plus\|ng_plus" scripts/ data/` → zero hits, plus no readable lore objects at all (D10-R1, still open: `grep -rn "записка\|note\|lore\|journal_entry" scripts/ data/` → zero implementations). The three endings differ only by a string in `GameState.ending` and a victory-panel title (`hud.gd:403-436`); no epilogue text, no world state diff, no stat carry. | Expected (TZ §4.4: three endings with distinct consequences; §1.2 "Причина и следствие"): a reason to return. Actual: endings are cosmetic labels over the same save, and the world forgets everything on re-entry. | Write a short epilogue per ending that reads the flags the player actually set, and either persist cleared areas or add NG+ flag carry. Documented acceptance of this as P3 is acceptable for release; it is not acceptable as a silent omission. | open |

---

## Corrections to my own earlier reports

§22.6 says a critic must not be allowed to leave a wrong finding standing. One of mine was wrong.

- **Round 1, "What I could NOT verify":** I wrote *"Save-file durability across a version bump —
  no schema migration exists to test."* That is **false**. `scripts/save/save_manager.gd:154-162`
  implements `_migrate()` with a real v0→v1 step (adds the missing `quests` block) and refuses a
  newer-than-known schema with `newer_schema_%d`; `SCHEMA_VERSION := 1` at line 7. I have now also
  read the slot tests: `tests/test_core.gd:874-925` covers a corrupt slot, backup behaviour,
  residue cleanup and slot-3 isolation. **Withdrawn, and the save layer is better than I said.**

## What passes the round-3 gate (checked, not assumed)

- **Tilemap integrity.** `unpainted=0` in all four zones — every grid cell is painted. Three of
  four zones have zero unreachable floor tiles. This is the §22.4 "пустоты в тайлмапе" check and it
  passes apart from D11-R3.
- **Three save slots are genuinely independent.** `SLOT_COUNT := 3` (`save_manager.gd:8`), atomic
  `tmp → verify → bak → json` write order (`save_manager.gd:43-73`), corrupt-slot and isolation
  tests at `tests/test_core.gd:874-925`, and a real migration path. I probed none of this on trust.
- **Death and load work.** BOT-011 `hp=100->92` (damage lands), BOT-009 `saved; gold=7 hp=100`
  (round-trip), defeat panel exists and is reachable.
- **The economy ledger is honest.** BOT-005 `ledger fangs/chest/buy/sell/equip=true; price=25/12`,
  BOT-006 `paid_again=false`. No dupe path found in this round either.
- **Quest and combat systems remain correct.** 2919 checks / 0 failures, 65 groups, 11 bots PASS,
  re-run for the third time on this round with identical results.
- **The ruins door puzzle is still not bypassable** (round 1 result, geometry unchanged).

---

## Scores

| Criterion | Score | One-line justification |
| --- | --- | --- |
| Полнота требований | **3/10** | At the pre-release bar the gaps are now decisive: no reachable ending, 2 of 4 zones never simulated, 5 of 6 required objective types missing, 4 of 5 zones, 2 of 5 settings sections, hidden ending ungated. |
| Корректность систем | **6/10** | Everything I exercised is correct — saves, migration, slot isolation, ledger, statuses, telegraphs, puzzle gating — and the one broken seam is the highest-priority system in the TZ, still broken after three rounds. |
| Игровое качество | **4/10** | The curve inverts at zone 3 (D3-R3), the finale introduces one new enemy (D4-R3), the reward for finishing the game is a label (D12-R3), and the strongest content is front-loaded into the tutorial zone. |
| UX и читаемость | **5/10** | HUD, journal, map and panels are readable and every screen is reachable, but the four zones are not distinguishable from their tiles (D8-R3) and the throne still prompts the player with an action it cannot perform. |
| Техническая надёжность | **6/10** | Down from 8 in rounds 1–2 not because the code got worse but because §22.4 asks the reliability questions: no recorded seed, bots diverge run-to-run (D6-R3), 75 s soak against 30–60 min, no watchdog, no replay (D7-R3). |

**Weighted mean under §22.5 mid-range weights (0.175 / 0.225 / 0.225 / 0.20 / 0.175): 4.8/10.**
**Reported design score after the gate penalty for 1 open P0 and 6 open P1: 3.6/10.**
Method note: rounds 1 and 2 reported holistic scores (5.0, 4.8) whose weighted means were both
5.8; the trajectory 5.0 → 4.8 → 3.6 is directional, and the drop reflects a stricter gate on an
unchanged build, not a regression. I state this so the numbers are not read as a measurement of
code change.

---

## Closing criteria for this round (each has a checkable criterion)

1. **D1-R3** — a bot scenario travels forest→ruins→dungeon→fortress, kills the King, presses E at
   the throne through the HUD, and asserts `GameState.ending != ""`. Output pasted into
   `PROCESS.md`. *Criterion: the scenario exists, runs green, and no test calls `choose()` directly
   to make it pass.*
2. **D2-R3** — BOT-012 and BOT-013 exist and pass, covering dungeon and fortress routes plus Bell
   Ringer, Captain, and King kills with phase transitions asserted. *Criterion: `grep travel` in
   `tests/` shows both zones entered by a scenario, not by a unit fixture.*
3. **D3-R3** — a test asserts non-decreasing average regular HP across the four zones from the live
   census. *Criterion: the test exists and passes without special-casing.*
4. **D4-R3** — the fortress introduces ≥3 new hostile kinds and contains no forest-only enemy.
   *Criterion: `probe_census.gd` output shows fortress kinds ≥ 4 new.*
5. **D5-R3** — `choose("crown")` returns false without `pilgrim_truth_known` + seals, true with
   them; `rusted_seal` is obtainable in normal play. *Criterion: both assertions in the suite.*
6. **D6-R3** — every telemetry run records seed + build version + profile, and two consecutive
   BOT-008 runs are byte-identical. *Criterion: CI asserts the diff is empty.*
7. **D7-R3** — a 30-minute and a 60-minute soak log with monitor tables are committed, and the
   watchdog plus cycle detector exist. *Criterion: `PROCESS.md:567` item checked with a log path.*
8. **D8-R3 / D9-R3 / D10-R3 / D11-R3 / D12-R3** — P2/P3 items may ship only with a written,
   owner-signed risk acceptance in `PROCESS.md`, per §22.4 ("P2/P3 допустимы только при
   документированном принятии риска").

---

## What I could NOT verify

- **Whether the game is fun.** Still no human playtest, three rounds in. I can prove the quests
  repeat and the curve inverts from data; I cannot prove a player cares, and I cannot prove the
  combat is enjoyable either. Every statement above about "quality" is a statement about structure.
- **Long-session behaviour.** No soak exists beyond 75 s. Memory, leaks, day-cycle drift and save
  growth over an hour are unknown, not good.
- **The shipping build.** Export templates `4.7.2.stable` are absent (`PROCESS.md:51`); I did not
  download them. Nothing about a Windows/macOS build — size, boot time, missing-resource behaviour
  on export — is verified.
- **Audio.** I never listened to this game. Telegraph sound, zone music, mix and bus layout
  (TZ §16.4) are unverified by ear.
- **Readability above the base 480×270 viewport.** All my screenshots (`/tmp/cd_*.png`) are at the
  base resolution, and there is no scale setting to test with (D10-R3).
- **Whether the late game is beatable at all by a human.** No bot reaches the King (D2-R3) and I did
  not hand-play to the fortress, so "the final boss is winnable" is an untested claim in both
  directions.
- **Balance of the three endings as narrative payoffs**, since none of them is reachable (D1-R3)
  and their text differs only by a title string.

## Conflicts with other critics

None recorded. `CRITIC_REPORTS/` contains only my own files. Per §22.6, if another critic marks the
ending, the late zones, or soak coverage as complete, that is a contradiction to escalate with the
probe outputs above — and note that a green `tests/test_core.gd` is not a counter-argument, because
the suite calls `EndingAltar.choose()` directly at `tests/test_core.gd:12041-12064` and never
travels to the fortress.

## Release blockers

D1-R3 (P0). Then D2-R3, D3-R3, D4-R3, D5-R3, D6-R3, D7-R3 (P1). §22.4: "Релиз запрещён при любом
открытом P0 или P1."

## Final recommendation

**REJECT.** The machinery is trustworthy — I tried to break the saves, the slots, the migration and
the ruins door this round and could not. What fails is the game and its evidence chain. A player
cannot finish it. Nobody has ever simulated the last two zones. The middle of the difficulty curve
is easier than the first zone. The final zone contains one new enemy. The secret ending is not
secret. Nothing records a seed, so no future "fixed" claim can be checked. And the longest run
anyone has evidence for is 75 seconds.

Close D1-R3 first — it is one UI surface and it unblocks the honest measurement of everything else.
Then build the two late-zone bots before tuning anything, because D3-R3 and D4-R3 are currently
findings about zones that no scenario has ever entered, and I would rather be wrong about them for
the right reason than right about them by reading a spreadsheet.
