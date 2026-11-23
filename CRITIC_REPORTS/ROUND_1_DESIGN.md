# CRITIC REPORT — ROUND 1 (design / scope audit)

| Field | Value |
| --- | --- |
| Round | 1 |
| Date | 2026-11-21 |
| Role | CRITIC-DESIGN (independent game-design critic, spec §22.1 / §22.2) |
| Scope | Scale realism, story coherence, game loops, enemy/NPC/quest composition, content-budget realism vs TZ §1, §4, §5, §10–14 |
| Build / commit | `1f7cca0` ("Документация по факту: 2919 проверок, 11 ботов, 5 зон, CHANGELOG") |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Critic independence | I did not build any part of this project. All findings below come from commands I ran myself and files I read myself. No finding is taken from `PROCESS.md` / `README.md` on trust. |

## Verdict up front

**REJECT.** One open P0 (the game cannot be finished by a human player) and five open P1s.
Spec §22.2 forbids moving to mass content production with open P0/P1 on the core loop or data;
spec §22.4 forbids release with any open P0/P1. Both gates are currently crossed.

---

## Evidence base (commands I actually ran)

```
$ godot --headless --path . --script res://tests/test_core.gd 2>&1 | tail -3
  PASS  every test group ran to completion (got 65/65)
checks: 2919  failures: 0

$ for b in BOT-001 … BOT-011; do godot --headless --path . -- --bot=$b 2>&1 | tail -1; done
BOT-001 PASS (reached_npc; quest_state=active)
BOT-002 PASS (quest_taken; progress=3/3; state=done; gold=18->78)
BOT-003 PASS (… zone=ruins …)
BOT-004 PASS (casts=4/4; exact_costs=4/4; cooldown_blocks=4; statuses=3)
BOT-005 PASS (ledger fangs/chest/buy/sell/equip=true; price=25/12)
BOT-006 PASS (reward=gold+60 xp+50 potions+2; paid_again=false)
BOT-007 PASS (telegraph_seen=true; trap_damage_at_distance=0)
BOT-008 PASS (kills={ash_wolf:4, spider:4, tick:3, slime:1, lumberjack:1, ash_boar:1})
BOT-009 PASS (saved; gold=7 hp=100)
BOT-010 PASS (segments=46; travelled=4164px; attacks=117)
BOT-011 PASS (hp=100->92)

$ python3 -c "…content inventory…"
items 13 | quests 12 | skills 8 | zones 4 | dialogues 7 | recipes 4

$ ls scenes/enemies/*.tscn | wc -l
23
```

Green tests and green bots are real and I credit them. They are also **not evidence that the
game is playable**, and the first finding is the proof.

---

## Findings

| ID | Severity | Finding | Evidence (file:line or command output) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| D1-R1 | **P0** | **The game has no reachable ending.** A player who kills the King and walks to the throne cannot choose a fate. `EndingAltar.choose()` is the only function that commits an ending, and nothing in `scripts/` calls it — only `tests/test_core.gd` does. | My probe `CRITIC_REPORTS/probe_ending.gd`: `PROBE prompt_after_king_dead=Выбрать судьбу` / `PROBE ending_after_interact=` (empty) / `PROBE hud_nodes_matching_ending_ui=["@Label@35(Label)=Трон ждёт: рассвет, память или венец"]` / `PROBE has_choose_hook=false`. `scripts/world/ending_altar.gd:63-70` — `interact()` only emits toasts. `scripts/ui/hud.gd:2378-2380` — the code's own comment: *"the final boss that has not been built yet is what will call it; nothing in the world does today"*. Callers of `choose()`: `tests/test_core.gd:12041-12064` only. | Expected (TZ §1.3 P0 row: "завершение сюжетной цепочки"): pressing E at the throne presents three fates and commits one. Actual: pressing E prints one toast line and `GameState.ending` stays `""` forever. The 2919 checks pass because the tests call the seam directly and bypass the missing UI. | Add a player-facing choice surface at the altar (three rows, ↑↓ + E, same keyboard style as the defeat panel) that calls `EndingAltar.choose()`. Add a bot scenario that reaches the fortress, kills the King, presses E through the HUD, and asserts `GameState.ending != ""`. | open |
| D2-R1 | **P1** | **Four zones, not five.** The TZ's zone 1 "Последняя деревня" is a district painted inside the forest map, not a zone. | `data/zones.json` → `zones` has exactly `forest`, `ruins`, `dungeon`, `fortress`. My census probe: all six village NPCs (`Edrik`, `Mila`, `Seris`, `Bran`, `Yorek`, `Alvena`) are spawned by `scripts/world/forest.gd:393-463` inside the forest zone. | Expected (TZ §1.1 "Целевой состав: 5 основных областей"; §5 table lists the village as zone 1 with its own square, well, forge, herb yard, palisade, abandoned house): 5 zones. Actual: 4. `PROCESS.md:78` states this honestly ("4 сцены зон … + область деревни"), but `PROCESS.md:72` then claims "гейт 5 закрыт", and the README/matrix counts the item as done. | Either promote the village to its own zone (own tilemap, own palette, own save point, own TZ §5 sub-areas) or record the deviation as `[-]` in the TZ matrix with the owner's sign-off, not `[x]`. | open |
| D3-R1 | **P1** | **The 12 quests are not a chain — they are 12 disconnected errands.** Not one quest declares a successor or a prerequisite. | `data/quests.json`: for all 12 entries `next` is `null`/absent and `requires` is `null`. Givers: `npc_edrik`×1, `npc_mila`×2, `ruins_tablet`×5, `npc_seris`×1, `npc_alvena`×1, `npc_nela`×1, `npc_oren`×1. | Expected (TZ §13.1 "Базовая сюжетная цепочка" Q01→Q14, each quest's *Результат* unlocking the next; §1.1 "12–16 **связанных** заданий"): taking Q07 opens the ruins, Q08 yields the royal key, etc. Actual: any quest can be taken in any order at any level; nothing unlocks anything. `PROCESS.md:93` marks "12–16 связанных заданий" as `[x]`. | Add `requires` to the data and enforce it in `QuestManager.start()`; gate zone access on quest state rather than only on geometry; make the tablet's q06→q07→q08 sequence explicit in data. | open |
| D4-R1 | **P1** | **Quest objective vocabulary is two verbs deep: `kill` (7 quests) and `collect` (5 quests).** | `data/quests.json` objective types: q01 kill, q02 collect, q03 kill, q04 kill, q05 collect, q06 kill, q07 kill, q08 kill, q09 collect, q10 collect, q11 kill, q12 collect. No `interact_flag`, `reach_area`, `talk_to_npc`, `boss_defeated`, `item_delivered` anywhere. | Expected (TZ §13.3: "Условия целей хранятся данными: kill_count, collect_count, interact_flag, reach_area, talk_to_npc, boss_defeated, item_delivered"): six objective kinds. Actual: two. Every quest resolves to "go to a tile, hit N things, walk back". | Implement the remaining four objective types in `QuestManager` and re-author at least 4 of the 12 quests onto them (a reach_area + interact_flag puzzle quest, a talk_to_npc interrogation, an item_delivered, a boss_defeated that is not q07/q08). | open |
| D5-R1 | **P1** | **Five of twelve quests are handed out by a standing stone.** The ruins' entire quest identity is a rock. | `data/quests.json` giver field: `ruins_tablet` gives q04, q05, q06, q07, q08 — including the two named bosses of the middle act. `scripts/world/quest_stone.gd:3` — *"A quest giver that is not a person: a standing stone with a task carved into it."* | Expected (TZ §12 opening line: "NPC должны ощущаться жителями одного поселения, **а не терминалами выдачи квестов**"; §12 lists Серис as "хранитель руин … Открытие руин, расшифровка табличек"): the ruins' keeper is a person with a voice and a motive. Actual: the character who was designed to own the ruins was replaced by furniture. | Replace `ruins_tablet` with the Seris character (or a new ruin-keeper) and give them the TZ §12 personality plus at least one branching conversation; keep the tablet as lore flavour only. | open |
| D6-R1 | **P1** | **Content budget is roughly a quarter of the stated duration.** The whole world is ~5,400 tiles and 54 enemy instances. | Map constants: `forest.gd:35` 52×32=1664, `ruins.gd:32` 40×26=1040, `dungeon.gd:40` 44×28=1232, `fortress.gd:48` 48×30=1440 → **5376 tiles**. My census probe (live node counts): forest 20 enemies, ruins 12, dungeon 11, fortress 11 → **54 hostiles**, 18 unique kinds. Content inventory: 13 items, 4 recipes, 7 dialogue trees, 8 skills. BOT-010's 75 s soak covered 4164 px of a ~86,000 px total path budget. | Expected (TZ §1.1: "Продолжительность целевого первого релиза: ориентир 5–8 часов"): 5–8 h. Actual: a first clear of all four zones, all 12 quests and all 5 bosses is realistically **45–90 minutes**. The budget does not hold together against the TZ's own duration target. | Pick one: (a) restate the duration target to 1–2 h in the TZ matrix and stop claiming 5–8 h, or (b) roughly triple hostile count and add the missing zone before claiming the target. Do not paper the gap with respawn grinding — TZ §1.1 explicitly forbids "растягивать прохождение искусственным грindом". | open |
| D7-R1 | **P2** | **The premise item of the story is unobtainable.** The hero is supposed to arrive carrying a fragment of the royal seal; `rusted_seal` exists in data and is never granted by anything. | `grep -rn "rusted_seal" scripts/ data/ tests/` → hits only `data/items.json:179` (definition) and `tests/test_core.gd:4759/4913/5473` (tests that add it by hand). No script, no chest table, no quest reward, no dialogue effect ever gives it. | Expected (TZ §4.1: "Герой прибывает в деревню с обломком королевской печати и не знает, почему она реагирует на пепел"; §4.3 Act I culmination: "Обломок печати реагирует на руины"): the seal fragment is in the opening inventory and reacts at the ruins. Actual: the item is dead data; the player never holds it and nothing reacts. | Grant `rusted_seal` at new-game, add the Act I culmination as a flag-driven reaction at the ruins gate, and surface it in the journal. | open |
| D8-R1 | **P2** | **Act I of the four-act structure does not exist as content.** No amulet, no amulet restoration, no "village is threatened" arc. | `grep -rn "оберег\|amulet\|talism" scripts/ data/` → the only hit is `data/items.json:155` `echo_amulet` (a bell-flavour equipment drop, unrelated). No quest, flag, or object implements the protective amulet. | Expected (TZ §4.3 Act I: "Игрок знакомится с деревней, помогает пережить угрозу леса, **восстанавливает защитный оберег**"): a measurable Act I objective with a culmination. Actual: Act I is three wolf-errands with no stakes stated anywhere in dialogue. | Add the amulet as an Act I objective with a visible state change in the village when restored (TZ §5: "позже меняются вид поселения и услуги"). | open |
| D9-R1 | **P2** | **NPC identities were renamed but their TZ roles were dropped.** Names survive from TZ §12; the personal lines do not. | TZ §12 defines Серис as "хранитель руин … говорит загадками", Орен as "охотник … обучение уклонению, охота на элитного зверя", the herbwife as "Лиора". The build has `forest.gd:458` `"Мельник Серис"` (a miller, q09 about a millrace) and `fortress.gd:444` `oren` (a fortress officer, q12 about a seal), and the herbwife is `Мила`. | Expected: each TZ §12 NPC keeps their motivation and personal line. Actual: two characters keep a TZ name and get an unrelated job; the herbwife is renamed. The result reads as coincidence, not authorship. | Either restore the TZ roles or rename the characters and write a short deviation note in the TZ matrix, so the divergence is a decision rather than drift. | open |
| D10-R1 | **P3** | **No lore objects anywhere.** Exploration rewards are chests and materials only. | `grep -rn "записка\|note\|lore\|journal_entry" scripts/ data/` → zero readable-object implementations. `PROCESS.md:72` does not claim them either. | Expected (TZ §5.1: "минимум 3 исследовательские находки разного масштаба: ресурс, сундук, **записка/lore**, секретный проход или особая встреча" per zone; §4.2: "Истина раскрывается через предметы, **записи**, архитектуру"): contradictory accounts delivered as readable artefacts. Actual: none. | Add one `ReadableNote` interactable per zone with 2–3 contradicting versions of the catastrophe (TZ §4.2), surfaced in the journal. | open |
| D11-R1 | **P3** | **The fifth boss has no unique mechanic.** `forest_warden` is a generic 2-phase boss. | `scenes/enemies/forest_warden.tscn:5` uses `res://scripts/ai/boss.gd` (the generic base) with `kind = 0`; the four specialised scripts are `boss_root_mother.gd`, `boss_captain.gd`, `boss_bell_ringer.gd`, `boss_king.gd`. My census confirms it does spawn (`forest.gd:536`). | Expected (TZ §11.1: "У каждой опасной атаки: визуальный телеграф…"; §11 gives every named boss a unique mechanic): a signature mechanic per boss. Actual: the warden is a stat-scaled generic. It is extra content beyond the TZ's 3+1, so this is a bonus item, not a shortfall — but a boss with no identity is not worth an arena. | Give the warden one mechanic (roots, pack call, or terrain change) or demote it to an elite enemy so the boss count matches the TZ's 3+1. | open |

---

## What is genuinely good (kept short, as instructed)

- **The pilgrim thread is real writing.** Four flag-gated monologues across four zones
  (`pilgrim_forest/ruins/dungeon/fortress`) that escalate from "Пепел помнит" to
  "Корона — не власть. Корона — выбор. Наденешь — останешься держать." It is the only content
  in the project that sounds like a theme rather than a task list. It is, however, mechanically
  inert — see D4-R2 in round 2.
- **All ten TZ §16.1 screens exist** as real implementations (`main_menu`, `hud`, inventory,
  `skills_panel`, journal, `map_panel`, dialogue runner, `shop_panel`/`craft_panel`,
  `settings_panel`, defeat + victory panels). I checked the files, not the README.
- **The ruins puzzle is honestly gated.** I tried to break it and could not: the `DungeonGate`
  sits at tile (37,22), behind the inner wall whose only gap is column 14 rows 9–13 where the
  `RuinDoor` slab stands (`ruins.gd:96-100`), and the key is deliberately on the near side
  (`ruins.gd:118-121`). My probe confirmed `door_open_after_interact_no_key=false`. This is
  correct design and I am recording it as correct.
- **Test and bot discipline is real.** 2919 checks, 65 groups, 11 scenarios, all green on my
  machine, first try, three separate runs of the suite and the bots.

---

## Scores

| Criterion | Score | One-line justification |
| --- | --- | --- |
| Полнота требований | **4/10** | 4 of 5 zones, 0 of 12 quests connected, 2 of 6 required objective types, Act I absent, premise item unobtainable — but all 10 UI screens and the 18-enemy/5-boss counts are genuinely met. |
| Корректность систем | **6/10** | Every system I could exercise behaves correctly (2919/0, 11 bots PASS, door puzzle unbreakable), yet the ending system has no player seam at all, which is a correctness hole in the highest-priority system in the TZ. |
| Игровое качество | **5/10** | The loop is legible and the ruins puzzle is a real spatial beat, but with two quest verbs, no choices with consequence, and no unlock chain there are no meaningful decisions to make. |
| UX и читаемость | **6/10** | HUD is readable and every screen is reachable; zone identity is weak (see D6-R3) and the throne actively misleads the player with a prompt it cannot satisfy. |
| Техническая надёжность | **8/10** | Clean headless run, deterministic bots, save round-trip verified by BOT-009; loses points for no soak beyond 75 s, no watchdog, no replay (`PROCESS.md:424` admits "реплея нет"). |

**Weighted design score (spec §22.5, design criteria): 5.0/10.**

---

## Closing criteria for this round

Release and mass-content expansion stay blocked until all of the following are demonstrably true:

1. **D1-R1 closed:** a bot scenario walks forest→ruins→dungeon→fortress, kills the King, presses
   E at the throne through the HUD, and asserts `GameState.ending != ""` for at least one of
   `dawn`/`memory`/`crown`. Output pasted into `PROCESS.md`.
2. **D3-R1 closed:** `data/quests.json` carries `requires`/`next` for at least the 6 main-path
   quests, and a test asserts that a gated quest cannot be started out of order.
3. **D4-R1 closed:** `QuestManager` supports ≥4 objective types and ≥4 of the 12 quests use a
   non-kill/non-collect objective.
4. **D5-R1 closed:** no quest is given by a non-person, or the deviation is signed off by the
   owner and marked `[-]` rather than `[x]`.
5. **D2-R1 / D6-R1 closed by decision, not by silence:** the owner picks "5 zones + 5–8 h" or
   "4 zones + 1–2 h", and the TZ matrix, README and `PROCESS.md` all say the same thing.

---

## What I could NOT verify

- **No human has played this game.** Difficulty feel, pacing, whether combat is fun, and whether
  the telegraphs read as fair are all unverified. Bots measure geometry and state, not experience.
- **Windows build.** `PROCESS.md:51` records that export templates `4.7.2.stable` are absent; I
  did not download them, so nothing about the shipping build is verified.
- **Audio.** I ran headless and non-headless but never listened; TZ §16.4 bus layout, mix, and
  zone music transitions are unverified by ear.
- **Long-session stability.** BOT-010 is 75 s. Nothing here is evidence about a 2-hour session.
- **Frame pacing on real hardware** at non-480×270 resolutions.
- **Save-file durability across a version bump** — no schema migration exists to test.

## Conflicts with other critics

None recorded yet: `CRITIC_REPORTS/` was empty when I started (`PROCESS.md:696` confirms
"`CRITIC_REPORTS/` нет"). If CRITIC-GODOT or CRITIC-PLAYER marks the ending as working, that is
a contradiction to escalate per §22.6, and my runtime probe output above is the evidence.

## Release blockers

D1-R1 (P0). Then D2-R1, D3-R1, D4-R1, D5-R1, D6-R1 (P1).

## Final recommendation

**REJECT.** The engineering underneath is better than average — the systems that exist are
tested hard and the ruins puzzle is properly gated. But the project currently documents a
three-ending finale that a player cannot reach, and it does so while 2919 green checks and 11
green bots assert the opposite. That is the exact failure mode TZ §24 was written to prevent.
Fix the ending seam, connect the quest chain, decide the real scope, and re-submit for round 2.
