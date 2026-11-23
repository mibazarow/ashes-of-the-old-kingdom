# CRITIC-DESIGN — SUMMARY OF ALL THREE ROUNDS

| Field | Value |
| --- | --- |
| Role | CRITIC-DESIGN (spec §22.1) — game design: loop, pacing, progression, economy, quests, difficulty, enemy and boss variety |
| Build audited in all three rounds | `1f7cca0` |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Date | 2026-11-21 |
| Rounds | ROUND_1_DESIGN.md (§22.2 pre-production) · ROUND_2_DESIGN.md (§22.3 vertical slice) · ROUND_3_DESIGN.md (§22.4 pre-release) |
| Independence | I built none of this. Every finding below is backed by a command I ran or a file I read on this commit. Nothing is taken from `PROCESS.md` or `README.md` on trust. |

**The same commit was audited three times.** No fixes landed between rounds, so the rounds are not
a timeline of progress — they are three different gates applied to one unchanged build. Round 3
scores lowest because §22.4 asks the hardest questions, not because the code got worse.

---

## 1. Verdicts and scores side by side

| | Round 1 (§22.2) | Round 2 (§22.3) | Round 3 (§22.4) |
| --- | --- | --- | --- |
| Gate | before mass content | vertical slice | pre-release |
| **Verdict** | **REJECT** | **REJECT** | **REJECT** |
| Полнота требований | 4 | 4 | 3 |
| Корректность систем | 6 | 7 | 6 |
| Игровое качество | 5 | 4 | 4 |
| UX и читаемость | 6 | 6 | 5 |
| Техническая надёжность | 8 | 8 | 6 |
| Weighted mean (§22.5 mid weights) | 5.8 | 5.8 | 4.8 |
| **Reported design score** | **5.0** | **4.8** | **3.6** |
| Open P0 | 1 | 1 | 1 |
| Open P1 | 5 | 5 | 6 |
| Open P2/P3 | 5 | 4 | 5 |

**Method note, stated so the numbers are not misread.** Rounds 1 and 2 reported holistic scores
(5.0, 4.8) whose strict weighted means were both 5.8; round 3 reports both (4.8 weighted, 3.6 after
the gate penalty for one open P0 and six open P1). The trajectory 5.0 → 4.8 → 3.6 is directional,
not an arithmetic measurement of code change. From round 3 the formula is fixed: weighted mean under
§22.5 mid-range weights 0.175 / 0.225 / 0.225 / 0.20 / 0.175, minus the open-gate penalty.

Where a criterion moved, the reason is in the round file. Корректность rose to 7 in round 2 (I had
probed more systems and none broke) and fell to 6 in round 3 only because the ending seam is still
open at the gate that makes it fatal. Надёжность fell 8 → 6 in round 3 with no code change: rounds
1–2 did not ask for a seed, a soak or a replay, and §22.4 does.

---

## 2. Consolidated open findings

### P0 — release blocker, open in all three rounds

| ID (R1 / R2 / R3) | Finding | Proof |
| --- | --- | --- |
| D1-R1 / D1-R2 / **D1-R3** | **The game cannot be finished.** The throne toasts and commits nothing; `EndingAltar.choose()` has no caller outside `tests/test_core.gd`. | `probe_ending.gd`: `prompt_after_king_dead=Выбрать судьбу`, `ending_after_interact=` (empty), `has_choose_hook=false`. `ending_altar.gd:59-69` (three toast branches, no state write). `hud.gd:2378-2380` — the code's own comment: *"nothing in the world does today"*. `tests/test_core.gd:12041-12064` calls `choose()` directly, which is why 2919 checks stay green. |

This is the only P0 and it has survived three rounds. It is also the cheapest finding in the report:
one three-row choice surface wired to a function that already works.

### P1 — release blockers under §22.4

| ID | Finding | First raised |
| --- | --- | --- |
| **D2-R3** | No bot or test ever enters the dungeon or the fortress. 2 of 4 zones and 3 of 5 bosses have zero simulation coverage; "all critical story paths checked" is unmeasured, not passing. | round 3 |
| **D3-R3** | Difficulty curve inverts: average regular HP by zone is 27.1 → 33.5 → **25.8** → 32.3. Zone 3 has the weakest regulars in the game, below zone 1. Forest's `root_beast` (60 HP/12 dmg) out-stats the dungeon's best regular `plague_bearer` (48 HP/8 dmg). | round 3 |
| **D4-R3** | Content density falls toward the finale. New hostile kinds per zone: 9+2 → 6+1 → 2+1 → **1+1**; the fortress re-uses the forest boar. Live instances 20 / 12 / 11 / 11. | round 3 |
| **D5-R3** | All three endings are unconditional. `choose()` checks only "known id + King dead + not yet taken", so the "hidden" `crown` ending (TZ §4.4: requires the keeper chain and rare seals) is selectable by a player who did nothing. `pilgrim_truth_known` is set and never read; `rusted_seal` is unobtainable. | round 3 |
| **D6-R3** | The pre-release re-verification gate is unexecutable: no seed is recorded anywhere (`grep seed` → one hit, soak only; telemetry records none), and BOT-008 diverges run-to-run (`attacks=94; spider:5` vs `attacks=85; spider:2`). Every future "fixed and re-checked" claim is unfalsifiable. | round 3 |
| **D7-R3** | Long-session stability unverified: soak is 75 s against the required 30–60 min, no watchdog, no cycle detector, no replay, no `inputs`/`observations`/`performance` logs. `PROCESS.md:380` and `:567` state this honestly. | round 3 |
| D2-R1 / D3-R2 | Four zones, not five — the village is a district painted inside the forest map, while `PROCESS.md:72` counts the gate as closed. | round 1 |
| D3-R1 | The 12 quests are not a chain: every entry has `next: null` and `requires: null`. Nothing unlocks anything. `PROCESS.md:93` marks "12–16 связанных заданий" `[x]`. | round 1 |
| D4-R1 | Objective vocabulary is two verbs: `kill` (7 quests) and `collect` (5). TZ §13.3 requires six types. | round 1 |
| D5-R1 | Five of twelve quests are handed out by a standing stone (`ruins_tablet` gives q04–q08), replacing the character TZ §12 designed to own the ruins. | round 1 |
| D6-R1 | Content budget is roughly a quarter of the stated duration: 5,376 tiles, 54 hostile instances, a 45–90 minute first clear against a 5–8 hour target. | round 1 |
| D2-R2 | Four of twelve quests are the same forest clearing, and `boar.tscn` drops `wolf_fang` — a boar dropping a wolf's fang. | round 2 |
| D3-R2 | q10 is offered at level 1 in the village for a material that only drops two zones deep, ungated and unhinted. | round 2 |
| D4-R2 | Six of nine NPCs have no dialogue tree at all (`seris`, `alvena`, `nela`, `oren` have no `*_intro` key; Yorek and Bran only open panels). | round 2 |
| D5-R2 | The game has exactly one choice node, and one of its two options has no effect and is not labelled cosmetic (TZ §12.2 forbids exactly that). | round 2 |
| D6-R2 | The pilgrim thread — the best writing in the project — gates nothing: untracked, unjournalled, and the ending it should unlock is unconditional. | round 2 |

### P2 / P3 — open, may ship only with written risk acceptance (§22.4)

`rusted_seal` unobtainable and Act I's protective amulet absent (D7-R1, D8-R1) · TZ §12 NPC roles
renamed without their motivations (D9-R1) · no readable lore objects anywhere (D10-R1) · fifth boss
has no unique mechanic (D11-R1) · zones forget violence — full respawn on re-entry (D7-R2) · the
rarest item farmable off a respawned boss at 100 % drop rate (D8-R2) · crafting economy is one
material deep and `bone_shard` is consumed by nothing (D9-R2) · Mila's written dialogue never
offers her quests (D10-R2) · four zones share one flat four-colour tile atlas, so the dungeon floor
is the same RGB(173,188,58) grass as the forest (D8-R3) · level cap 20 against 3,401 XP of authored
content, reachable only by the farming the TZ forbids (D9-R3) · settings ship 2 of 5 required
sections — no display, visual-intensity or accessibility (D10-R3) · six unreachable forest tiles
(D11-R3) · no reason to replay, no NG+, endings differ only by a title string (D12-R3).

---

## 3. What I verified as correct (and would not touch)

Recorded so the report is not read as a blanket negative. All of this was probed, not assumed.

- **Save layer is genuinely strong.** `SLOT_COUNT := 3`, atomic `tmp → verify → bak → json` write
  order, real `v0 → v1` schema migration with refusal of newer schemas (`save_manager.gd:154-162`),
  corrupt-slot, backup, residue and slot-isolation tests (`tests/test_core.gd:874-925`).
- **Tilemap integrity.** `unpainted=0` in all four zones; zero unreachable tiles in ruins, dungeon
  and fortress (`probe_reach.gd`).
- **The ruins door puzzle is not bypassable.** I tried to break it in round 1 and failed; the
  `DungeonGate` is behind the only gap in the inner wall and the key is on the near side.
- **Combat systems are real and honest.** Dash i-frames (`player.gd:395-399`), six statuses, genuine
  elemental combos, telegraph-before-damage proven independently (BOT-007), zero player lockout
  (BOT-003 `max_control_ms=0`).
- **The economy and quest ledgers do not dupe.** BOT-005 full ledger, BOT-006 `paid_again=false`.
- **Test and bot discipline.** 2919 checks / 0 failures across 65 groups, 11 bots PASS — green on
  three separate re-runs by me, on three rounds, first try each time.
- **`PROCESS.md` is honest about its own gaps** in almost every place I checked it
  (`:380` soak/watchdog/replay, `:424` "реплея нет", `:72` "доступности нет", `:51` export
  templates). Two entries are not honest and are listed as findings: `:72`/`:93` claim gates that
  the data contradicts.

## 4. My own error, corrected

Round 1 stated "no schema migration exists to test". That was **wrong** — `_migrate()` exists and is
tested. Withdrawn in ROUND_3_DESIGN.md §"Corrections to my own earlier reports". Recorded here
because §22.6 does not let a critic leave a false finding standing.

---

## 5. Verdict

**REJECT, three for three.** The engineering underneath this project is better than average for a
slice its size: the systems that exist are tested hard, the save layer is trustworthy, the combat
verbs are real, and the one spatial puzzle in the game is properly gated. I would not change any of
that. What fails is the game and its evidence chain, and the failure is concentrated, not diffuse.
A player cannot finish the game — the throne prints a toast line and the function that would commit
an ending is called only from a test file, which is precisely why 2,919 green checks and 11 green
bots have been read as proof of a finished finale for three rounds. Nobody has ever simulated the
dungeon or the fortress, so the last third of the world is unmeasured rather than weak. The
difficulty curve runs backwards in the middle (zone 3 has the weakest regulars in the build, below
zone 1), the final zone introduces exactly one new enemy while re-using a forest boar, and the
"hidden" ending requires nothing, which quietly deflates the pilgrim thread — the only content in
this project that says something — into four untracked monologues. Nothing records a seed and the
bots diverge run-to-run, so no future "fixed" claim can be checked; and the longest run anyone has
evidence for is 75 seconds against a required half-hour. Twelve of the fourteen P1s are content and
authoring problems, not architecture, and the single P0 is one UI surface wired to a function that
already works. Fix the ending seam, then write the two late-zone bots **before** tuning anything
else, because the curve and density findings above are claims about zones no scenario has entered —
I would rather be wrong about them for the right reason than right about them from a spreadsheet.
Release stays blocked under §22.4 until the P0 and all P1s are closed and independently re-verified.
