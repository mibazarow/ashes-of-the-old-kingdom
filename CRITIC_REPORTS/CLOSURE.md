# CLOSURE — independent re-verification of the three critic reports

Role: independent closure verifier (spec §22.6). I did not write any of the code under
audit and I did not take any claim in `PROCESS.md`, `README.md` or the critics' own
reports on trust. Every verdict below is backed by a command I ran on this commit.

| Field | Value |
| --- | --- |
| HEAD re-verified | `043fda8` — «Отчёты трёх критиков: дизайн, инженерия, игрок — три раунда каждый», 2026-11-23 16:16:55 +0300 |
| Audited bases | DESIGN `1f7cca0` · GODOT `19eb835` · PLAYER `979db16` |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` (`/opt/homebrew/bin/godot`) |
| Platform | macOS (arm64) |
| Date | 2026-11-23 |
| Scope | every finding the three summaries list as `open` at P0/P1 |
| Working tree | unmodified by me; this file is the only file I wrote |

## 0. Headline

**The release-blocking P0 is closed. 15 of 27 P1s are closed, 5 are partial, 7 remain
open. The build is still not releasable under §22.4**, and the reason is narrow: one
player-facing readability P1 (enemies camouflage into their own zone floor) is not fixed
and is not actually covered by the green test suite, and the release artifact is still
three days stale.

### Gate (my own runs, not the project's)

| Check | Command | Result |
| --- | --- | --- |
| Unit/integration suite | `godot --headless --path . --script res://tests/test_core.gd` | `checks: 3391  failures: 0`, exit 0 |
| Clean run | `godot --headless --path . --quit-after 120 2>&1 \| grep -cE 'ERROR\|SCRIPT ERROR'` | `0`, exit 0 |
| Bot scenarios | `godot --headless --path . -- --bot=BOT-0NN` for NN=001..013 | **13/13 PASS**, all rc=0 |

The critic's own numbers have moved: DESIGN audited 2919 checks, GODOT 3197 — the suite
is now 3391 and still green, so the growth is real coverage, not a stale count.

### Counts

| Severity | Closed | Partial | Open | Total |
| --- | --- | --- | --- | --- |
| P0 | 1 | 0 | 0 | 1 |
| P1 | 15 | 5 | 7 | 27 |
| **Total** | **16** | **5** | **7** | **28** |

---

## 1. CRITIC-DESIGN

| Finding ID | Original severity | Verdict | Evidence | Notes |
| --- | --- | --- | --- | --- |
| D1-R3 (D1-R1/D1-R2) — the game cannot be finished | P0 | **CLOSED** | `tests/test_core.gd:14027-14100` drives the throne the way a player does: `altar.interact(hero)` → `Input.parse_input_event` key events via `_tap_key()` (`test_core.gd:3142-3154`, real `InputEventKey` down/up, not a method call) → asserts `GameState.ending == "dawn"`, `is_victory_open()`, victory title contains «Новый рассвет». Locked fates are refused with their reason on screen and commit nothing. Suite green 3391/0. | `ending_altar.gd:101` `choose()` is now reached from `hud.gd:2936` `_confirm_ending_choice()` (driven by `_process_ending_choice_navigation()` at `hud.gd:2909`), i.e. from real input, not only from tests. **`CRITIC_REPORTS/probe_ending.gd` is now a stale instrument**: it reads `GameState.ending` immediately after `interact()`, which under the fixed two-step design only *opens* the panel, so it still prints `ending_after_interact=` (empty) and `has_choose_hook=false`. Do not re-run it as a gate — it produces a false negative. |
| D2-R3 — no bot or test ever enters the dungeon or the fortress | P1 | **CLOSED** | BOT-012: `entered_dungeon at=3612`, `pin[ruin_skeleton_archer] saw=10 exchanges=10`, `dmg=ruin_skeleton:62,ruin_skeleton_archer:39`, `goal_two_dungeon_kinds=ok`, `goal_back_in_forest=ok`, `terms=all_pass`. BOT-013: `entered_fortress at=4171`, `king_phase_2 at=6372`, `goal_king_engaged=ok`, `goal_phase2_seen=ok`, `terms=all_pass`. | Both new scenarios also traverse forest→ruins→dungeon in one run, so the door chain is simulated, not just asserted. |
| D3-R3 — difficulty curve inverts (27.1 → 33.5 → 25.8 → 32.3) | P1 | **CLOSED** | `probe_curve.gd`: avg_hp **27.8 → 35.7 → 38.5 → 39.9**; avg_dmg **7.7 → 9.5 → 9.6 → 9.9**; avg_xp **14.8 → 22.4 → 25.7 → 26.9** — all three monotonic across forest→ruins→dungeon→fortress. The specific out-statting claim is reversed: `plague_bearer.tscn` is now 84 HP / 14 dmg vs `root_beast.tscn` 60 HP / 12 dmg. | One residual non-monotonicity, not part of the original finding: avg_gold dips in the dungeon (6.9 → 9.5 → **8.2** → 11.1). Cosmetic; log it as P3. |
| D4-R3 — content density falls toward the finale (9+2 → 6+1 → 2+1 → 1+1 new kinds) | P1 | **OPEN** | `probe_census.gd` kinds per zone: forest 11, ruins 7, dungeon 6, fortress 10. Recomputing *first appearance* per zone: forest 11 new, ruins 6 new, dungeon 2 new (`plague_bearer`, `bone_crawler`), fortress **1 new** (`ash_knight`). The collapse 11 → 6 → 2 → 1 is unchanged from the audited 9 → 6 → 2 → 1. | Live instances did improve (20/12/13/17 vs 20/12/11/11), and the fortress roster is no longer thin — but 9 of its 10 kinds are repeats, and it still re-uses the forest's `ash_boar` (1 instance), the exact example in the finding. |
| D5-R3 — all three endings are unconditional | P1 | **CLOSED** | `ending_altar.gd:145-161` `_lock_reason()`: `memory` requires `pilgrim_truth_known`; `crown` requires that truth **and** `GameState.count_item("rusted_seal") > 0`. `rusted_seal` is now obtainable — `scenes/enemies/king_without_crown.tscn:25` drops it (the critic recorded it as unobtainable). Test asserts rows 2 and 3 read «закрыто» with the King dead but the truth unknown, and that confirming «memory» toasts «Нужно узнать правду о печати» and commits nothing. | The seal drops from the King, who guards the throne where the choice is made — reachable (kill King, loot, then interact), but a player who loots nothing cannot see the third ending. Acceptable gating; worth a hint. |
| D6-R3 — no seed recorded anywhere; BOT-008 diverges run-to-run | P1 | **CLOSED** | Seed provenance is recorded twice per run: `run_meta.json` (`"seed": 424242, "seed_source": "cmdline", "world_seed": 20261107`, engine hash `ed1daf0bf…`) and `replay/seed.txt` (`seed=424242 / seed_source=cmdline / world_seed=20261107`). Double-runs at an identical seed: **BOT-003 ×2 → summary lines byte-identical**; **BOT-008 ×2 → byte-identical**. | BOT-008 was the critic's divergence exhibit (`attacks=94; spider:5` vs `attacks=85; spider:2`). It is now reproducible. The critic's own divergence exhibit (BOT-003 `cultist_caster best` 33→34) is also gone. |
| D7-R3 — long-session stability unverified: 75 s soak, no watchdog, no cycle detector, no replay, no logs | P1 | **PARTIAL** | Soak raised: `bot.gd:25` `SOAK_SECONDS_DEFAULT := 600.0`; BOT-010 reports `window=600s`, `segments=358`, `travelled=33395px`, `deaths=9`, `goal_survived=ok`. Watchdog and cycle detector exist and fire in the open: `watchdog_stuck no_progress_ms=3000` and `watchdog_cycle no_progress_ms=5450` appear in BOT-007/008/010 logs. Full log surface verified on disk in `user://debug_runs/20261123-164717-194/`: `inputs.jsonl` (58 KB), `observations.jsonl` (18 KB), `performance.csv` (2.7 KB), `decisions.jsonl`, `combat.jsonl`, `events.jsonl`, `quest_economy.jsonl`, `errors.log`, `replay/`, `run_meta.json`, `summary.md`, `screenshots/`. | **The soak is 10 minutes against the required 30–60 minutes** (§22.4). The instrumentation gap is closed; the duration gap is not. This is the cheapest remaining P1: one constant plus a longer BOT-010 run. |
| D2-R1 / D3-R2 — four zones, not five; the village is a painted district | P1 | **OPEN** | `data/zones.json` still contains exactly `forest, ruins, dungeon, fortress`. No fifth zone was added between `1f7cca0` and HEAD. | Unchanged. Any fix here is content work, not a patch. |
| D3-R1 — the 12 quests are not a chain (`next: null`, `requires: null`) | P1 | **CLOSED** | `data/quests.json`: every quest has a non-null `next` except the terminal `q12_officers_seal`, and a non-empty `requires` except the entry `q01_ash_wolves`. Chain: q01→q02→q03→q09→q04→q05→q06→q07→q10→q08→q11→q12. | It is a single linear chain, not the branching set TZ implies, but the finding ("nothing unlocks anything") is resolved: each quest now unlocks exactly one successor. |
| D4-R1 — objective vocabulary is two verbs; TZ §13.3 requires six | P1 | **OPEN** | `objective.type` over all 12 quests: `kill` 8, `collect` 4. Two verbs, as audited (was kill 7 / collect 5). | Slightly worse in distribution, unchanged in kind. Still four objective types short of TZ §13.3. |
| D5-R1 — five of twelve quests handed out by a standing stone | P1 | **OPEN** | `ruins_tablet` is still the giver of q04, q05, q06, q07, q08 — 5 of 12, all with `where=«Скрижаль у врат»`. | Unchanged. The ruins still have no character owning its quests, which is the substance of the finding. |
| D6-R1 — content budget ≈ a quarter of the stated duration | P1 | **OPEN** | Hostile instances total **62** (20/12/13/17) against the audited 54 — a 15 % increase against a 4× shortfall. Zone count unchanged at 4. Boss count unchanged at 5. | No zone-scale content landed. The finding stands as written. |
| D2-R2 — four quests are the same forest clearing; `boar.tscn` drops `wolf_fang` | P1 | **CLOSED** | `scenes/enemies/boar.tscn`: `loot_item = "boar_tusk"`, `loot_chance = 0.4` — the boar no longer drops a wolf's fang, and `boar_tusk` is a real item (`data/items.json:206`). The forest/village quests now name four distinct places: «Эдрик, опушка», «Мила, деревня», «Серис, мельница», «Альвена, деревня». | Мила still hands out two quests (q02, q03). The finding's "same clearing" complaint is about location variety, which is fixed; giver variety is improved but not one-to-one. |
| D3-R2 — q10 offered at level 1 for a material two zones deep, ungated | P1 | **CLOSED** | `q10_armor_fit`: `min_level: 4` and `requires: ["q07_captain_guard"]` — the only quest in the table with a level gate, and it is the one the finding named. | Gated behind the ruins captain chain, which is where `bone_shard` actually drops. |
| D4-R2 — six of nine NPCs have no dialogue tree | P1 | **CLOSED** | `data/dialogue.json` now holds **18** trees. `*_intro` exists for all nine NPCs (edrik, mila, seris, alvena, yorek, bran, nela, oren), `*_after_hunt` for six of them, plus four pilgrim trees (`pilgrim_forest/ruins/dungeon/fortress`). The four trees the finding named as missing (`seris`, `alvena`, `nela`, `oren`) all exist. | `CRITIC_REPORTS/probe_npc.gd` cannot confirm this — it crashes on its own line 38 (`SCRIPT ERROR: Invalid call 'String' constructor`). My count is from the data file directly. |
| D5-R2 — exactly one choice node, and one option has no effect and is not labelled cosmetic (TZ §12.2) | P1 | **PARTIAL** | Choice nodes went **1 → 9**, across `edrik_intro, mila_intro, mila_after_hunt, seris_intro, alvena_intro, yorek_intro, bran_intro, nela_intro, oren_intro`. 11 no-effect options now carry `"cosmetic": true` in `data/dialogue.json`. **But `cosmetic` appears nowhere under `scripts/`** — `hud.gd:1826-1837` renders each option as `"> %d. %s"` from `text` only, ignoring every other key. | The data now knows which options are cosmetic; the player still does not. TZ §12.2 forbids precisely an unlabelled no-effect option, so the prohibition is still violated at the screen. The fix is a few lines in the option renderer. |
| D6-R2 — the pilgrim thread gates nothing, is untracked and unjournalled | P1 | **PARTIAL** | Gating half is fixed: `pilgrim_truth_known` (set at `data/dialogue.json:468`, in the fortress fragment) is read by `ending_altar.gd:159` and locks two of three endings; the four pilgrim trees set `pilgrim_met_forest/ruins/dungeon/fortress`, and tests assert the chain sets the flag and that it survives a save round-trip. **Journal half is not**: `hud.gd:1944-1965` `_refresh_journal()` iterates `QuestManager.quests` only — there is no pilgrim entry, and `grep pilgrim scripts/ui/hud.gd` returns nothing. | A player who meets three pilgrims gets no visible record that a thread exists, which is the "untracked" half of the finding. |

## 2. CRITIC-GODOT

| Finding ID | Original severity | Verdict | Evidence | Notes |
| --- | --- | --- | --- | --- |
| G1-R3 — the release artifact is stale | P1 | **OPEN** | `build/macos/Pepl-macos-arm64.zip` mtime **Nov 20 17:06**; HEAD `043fda8` dated **Nov 23 16:16** — 3 days and every determinism, dungeon-bot, dialogue and readability commit newer than the binary. No export process is running (`ps` shows only my test runs), so this is not a rebuild in flight. | `docs/BUILD_MACOS.md:22` still cites `checks: 1832` against the 3391 I measured. Shipping this zip ships none of the work the green suite certifies. |
| G2-R2 / G2-R3 — reproducibility applied inconsistently (4 frame-locked vs ~20 wall-clock budgets) | P1 | **CLOSED** | `bot.gd` grep: **72** `Engine.get_physics_frames()` call sites, **26** physics-frame deadline comparisons, and **0** wall-clock deadlines. The single remaining `Time.get_ticks_msec()` is `bot.gd:716` `_start_ms`, used only to report elapsed time in the summary — it gates nothing. Behavioural proof: BOT-003 and BOT-008 each run twice at `--seed=424242` produced **byte-identical** result lines. | The critic's two exhibits were a divergence in BOT-003 and consistency in BOT-008; both now reproduce. Frame-locking is applied uniformly. |

## 3. CRITIC-PLAYER

All pixel numbers below are measured from frames I re-rendered myself at HEAD
(`PEPEL_SCREENSHOT` + `PEPEL_SCREENSHOT_UI`, 14 frames at 480×270), not from the critic's
screenshots. Contrast is WCAG relative-luminance ratio.

| Finding ID | Original severity | Verdict | Evidence | Notes |
| --- | --- | --- | --- | --- |
| CRITIC-P1-01 — zones share one floor colour | P1 | **PARTIAL** | The shared colour the finding named, `RGB(173,188,58)`, is now **0.00 %** of the sample in all four zones, and no RGB value is shared above 20 % across zones. Dominant floor per zone: forest `RGB(175,190,60)` 4.30 %, ruins `RGB(135,126,112)` 5.15 %, dungeon `RGB(52,61,89)` **30.55 %**, fortress `RGB(120,100,73)` 6.10 %. Pairwise mean-floor contrast: all six pairs ≥1.5:1 (min 1.57 forest↔ruins, 1.61 ruins↔fortress). | Two of the acceptance clauses still fail: the dungeon's single dominant value is **30.55 %** against a 20 % bar, and the ruins↔fortress **dominant-pixel** contrast is **1.41:1** against the 1.5:1 bar. The zones are now distinguishable in aggregate; the two warm zones still touch at their most common colour. |
| CRITIC-P1-02 — HUD text sits on the world with no plate | P1 | **CLOSED** | `hud.gd:24` `PLATE_COLOR := Color(0.04, 0.05, 0.07, 0.86)`; compositing it over measured grass reproduces the rendered plate exactly at `RGB(33,38,24)`. Text on that plate: core **15.26–16.87:1**, perceived **9.53–10.13:1** on all four zones; the controls band **12.13–12.95:1**. | Was 1.19/1.05/1.73/2.96:1 against raw floors. Every HUD string now clears 4.5:1 by a wide margin on every zone. |
| CRITIC-P1-03 — XP bar too thin, HP/MP/XP uncaptioned | P1 | **CLOSED** | `_xp_bar` is built at the full `BAR_H := 7.0` (`hud.gd:6`) with a `_make_bar_label("XP")` caption; `hp_caption_text()` renders `"HP %d/%d"` and the XP row renders `"XP %d/%d"`. | Both clauses of the acceptance test met. |
| CRITIC-P1-04 — HUD font is antialiased SystemFont | P1 | **PARTIAL** | `hud.gd:959-969` `_make_theme()` sets `font.antialiasing = TextServer.FONT_ANTIALIASING_NONE` and `subpixel_positioning = SUBPIXEL_POSITIONING_DISABLED`. Confirmed empirically: every bright text pixel in the sample is exactly `RGB(243,243,230)` — **1 distinct bright colour over 88 px**, i.e. no grey AA fringe remains. | The acceptance test was «no `SystemFont` default assignment; identical glyph metrics on two platforms». It is still a `SystemFont`, so glyph metrics remain platform-dependent, and the repo contains no `.ttf`/`.otf`/`.fnt` at all. Crispness is fixed; portability is not. |
| CRITIC-P1-09 — attack telegraph invisible on the floor | P1 | **CLOSED** (computed) | `enemy.gd:85-86` `TELEGRAPH_ALPHA_START 0.70` → `TELEGRAPH_ALPHA_PEAK 0.95`, fill `RGB(0,230,255)`, plus a 1 px opaque outline sibling `RGB(5,8,13)`. Fill at the **first** warning frame vs floor: forest 1.17, ruins 1.95, dungeon 4.27, fortress 2.52. At peak: 1.31 / 2.50 / 6.54 / 3.50. Outline vs floor: forest 9.79, ruins 5.01, dungeon 1.87, fortress 3.55. The shape therefore clears **≥3:1 on all four floors through at least one channel** (light floors by outline, the dark dungeon floor by fill). | Caveat, stated plainly: this is a computed blend of the shipped constants over measured floor pixels, because no probe freezes a warning frame — the same method limitation the original report had. Behavioural corroboration exists (BOT-007/012 report `telegraph_seen=true`, `telegraph=true`), but a pixel-exact first-frame capture would be stronger. |
| CRITIC-P1-10 — spike trap indistinguishable from floor | P1 | **CLOSED** (computed) | `scripts/world/spike_trap.gd` rewritten with `IDLE_FILL (0.10,0.55,0.65)` α0.50, `WARNING_FILL (0.0,0.90,1.0)` α0.60→0.95, `ACTIVE_FILL (1.0,0.35,0.95)` α0.95 and an `OUTLINE_COLOR (0.02,0.03,0.05)` child with `show_behind_parent`. Warning at first frame vs floor: 1.12 / 1.75 / 3.54 / 2.20; at peak 1.31 / 2.50 / 6.54 / 3.50; outline 9.79 / 5.01 / 1.87 / 3.55 — ≥3:1 on every floor via at least one channel. Behavioural: BOT-012 `trap telegraph=true dmg_at_distance=0 crossed=true dmg_crossing=0`, i.e. the trap warns and punishes only on crossing. | Same computed-blend caveat as P1-09. The cool hue is now clearly outside every floor family, which was the design ask. |
| CRITIC-P1-11 — no accessibility surface | P1 | **CLOSED** | `settings_panel.gd:46` `SECTION_COUNT := 3` with a third «Экран» section (`COLOR_SECTION_*` at :33-34) exposing `"flash_intensity": "Яркость вспышек"` and `"font_scale": "Размер шрифта"` (:54-55), plus a colour-blind row rendered as «Дальтонизм — выкл». Confirmed in the rendered settings frame. | §24's «настройки интенсивности» and §23 stage 8's accessibility deliverable are both now present on screen, not only in code. |
| CRITIC-P1-12 — settings footer below 4.5:1 | P1 | **CLOSED** | The three footer bands (y224-229, y237-240, y248-253) measure **11.91:1** against the panel body `RGB(17,20,21)`; the worst single line anywhere in the settings panel is **8.15:1**. | Was 3.84 / 3.79 / 2.92:1. No string in the panel is below 4.5:1. |
| CRITIC-P1-18 — enemies camouflage into their own zone floor | P1 | **OPEN** | Segmented every enemy sprite in my four zone renders and measured each sprite pixel against its own local floor. **0 of 23 sprites reach the ≥90 % @ ≥3:1 bar.** Mean fraction of sprite pixels at ≥3:1: forest **48.4 %** (8 sprites), ruins **41.5 %** (7), dungeon **8.0 %** (2), fortress **22.3 %** (6). Worst case, dungeon sprite at x193 y97: **0.0 %** of its pixels reach 3:1 — its best colour is `RGB(150,107,82)` at **2.31:1**, its outline `RGB(12,16,17)` at **1.78:1**, and 44 of its own outline pixels sit at 1.78:1. | **Root cause, isolated.** The fix added one shared near-black silhouette — `enemy.gd:126` `outline_color = vec4(0.043, 0.051, 0.067)`. That colour is 10.25:1 and 12.05:1 against the light forest floors, but only **1.96:1** against the dungeon floor `RGB(52,61,89)` and **1.36:1** against the dungeon's dark tile `RGB(32,36,49)`; against the fortress dark tile `RGB(46,39,30)` it is 1.42:1. A dark outline cannot separate a sprite from a dark floor. `READABLE_TINTS` (`enemy.gd:94-118`) is keyed per **enemy type**, not per **zone**, so the same tint lands on a light grass floor and a dark dungeon floor. |
| CRITIC-P1-18 — why the green suite does not cover it | P1 | (same finding) | The guard test `tests/test_core.gd:11786-11829` checks only (a) that a `ShaderMaterial` exists on the sprite, (b) that `sprite_tint` equals the `READABLE_TINTS` entry, and (c) `if _hue_separation_deg(tint, floor_c) < 45.0 and _wcag_contrast(tint, floor_c) < 3.0` — a **hue-OR-contrast escape hatch**, evaluated against the **atlas** colours, never the outline and never a rendered pixel. | The atlas colours are not what renders: `_atlas_floor_colors` reads forest's top colour as `RGB(141,151,127)` (L=0.293) while the shipped frame shows grass at `RGB(175,190,60)` (L=0.463). So the test validates tints against colours the player never sees, and passes. **`checks: 3391 failures: 0` is not evidence for this acceptance test.** The code comment at `enemy.gd:88-96` («the roster test re-derives the floors from the zone atlases themselves», line 91) is true of the atlas and misleading about the screen. |

---

## 4. P0/P1 still open — explicit statement

Per §22.6 I state this without hedging.

**P0: none open.** The single release-blocking P0 (D1-R3, the game could not be finished)
is closed and is now pinned by a test that drives real key events rather than calling
`choose()` directly.

**P1: 7 open, 5 partial.** Not releasable under §22.4.

Open:

1. **CRITIC-P1-18** — enemies camouflage into their own zone floor. The most serious
   remaining item: it is player-facing, it is worst exactly where the game is darkest
   (dungeon: 0 % of sprite pixels at 3:1), and the suite gives false comfort about it.
2. **G1-R3** — the release artifact is three days stale; shipping it ships none of the
   audited fixes.
3. **D4-R3** — new hostile kinds per zone still collapse 11 → 6 → 2 → 1 toward the finale.
4. **D2-R1** — four zones, not the five the plan counts as closed.
5. **D4-R1** — objective vocabulary is still two verbs against TZ §13.3's six.
6. **D5-R1** — a standing stone still hands out 5 of 12 quests, replacing the ruins
   character TZ §12 designed.
7. **D6-R1** — content budget remains roughly a quarter of the stated 5–8 hour target
   (62 hostile instances against 54 at audit).

Partial: **D7-R3** (soak 10 min against 30–60 min required — instrumentation itself is now
complete), **D5-R2** (cosmetic options are flagged in data and unlabelled on screen),
**D6-R2** (pilgrim thread gates two endings but is still absent from the journal),
**CRITIC-P1-01** (dungeon dominant value 30.55 % against a 20 % bar; ruins↔fortress
dominant-pixel 1.41:1 against 1.5:1), **CRITIC-P1-04** (antialiasing off, but still a
platform-dependent `SystemFont` and no font asset in the repo).

Cheapest path to a releasable build, in order: rebuild the artifact and correct
`BUILD_MACOS.md`'s check count (G1-R3); raise `SOAK_SECONDS_DEFAULT` to 1800 and re-run
BOT-010 (D7-R3); label cosmetic options in `hud.gd:1835` from the `cosmetic` key that
already exists (D5-R2); make the enemy silhouette zone-aware — a light outline on dark
floors — and extend the roster test to measure the outline and rendered pixels without the
hue escape hatch (P1-18).

---

## 5. Stale instruments — do not use these as gates

Both are the critic's own round-1 probes, and both now mislead:

- **`CRITIC_REPORTS/probe_ending.gd`** still prints `ending_after_interact=` (empty) and
  `has_choose_hook=false` on a build where the ending is reachable, because it reads
  `GameState.ending` right after `interact()`, which now only opens the choice panel. It
  reports a false P0.
- **`CRITIC_REPORTS/probe_npc.gd`** crashes before reporting:
  `SCRIPT ERROR: Invalid call 'String' constructor: q01_ash_wolves` at line 38. It cannot
  confirm or deny NPC coverage; my NPC count came from `data/dialogue.json` directly.

`probe_curve.gd`, `probe_census.gd`, `probe_replay.gd`, `probe_reach.gd`, `probe_path.gd`
and `probe_respawn.gd` run clean.

## 6. Reproducing my measurements

```bash
# gate
godot --headless --path . --script res://tests/test_core.gd          # checks: 3391 failures: 0
godot --headless --path . --quit-after 120 2>&1 | grep -cE 'ERROR|SCRIPT ERROR'   # 0
for n in 001 002 003 004 005 006 007 008 009 010 011 012 013; do
  godot --headless --path . -- --bot=BOT-$n; done                    # 13/13 PASS

# reproducibility (the G2-R3 exhibit)
godot --headless --path . -- --bot=BOT-008 --seed=424242   # run twice: byte-identical result line
godot --headless --path . -- --bot=BOT-003 --seed=424242   # run twice: byte-identical result line
cat ~/Library/Application\ Support/Godot/app_userdata/Пепел\ старого\ королевства/debug_runs/<run_id>/replay/seed.txt

# design
godot --headless --path . --script res://CRITIC_REPORTS/probe_curve.gd
godot --headless --path . --script res://CRITIC_REPORTS/probe_census.gd

# player pixels: re-render, then measure sprite/floor and text/plate contrast per frame
PEPEL_SCREENSHOT=/tmp/cl/cp_world.png PEPEL_SCREENSHOT_UI=world \
  godot --headless --path . --quit-after 120
```

My throwaway measurement scripts live in `/tmp` (`cl_render.sh`, `cl_bots.sh`,
`cl_sprites.py`, `cl_panels.py`, `pngtool.py`, `repro.sh`) and are deliberately not added
to the repository. The working tree is otherwise exactly `043fda8` as I found it.
