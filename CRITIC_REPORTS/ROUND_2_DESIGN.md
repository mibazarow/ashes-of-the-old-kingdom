# CRITIC REPORT — ROUND 2 (vertical-slice audit)

| Field | Value |
| --- | --- |
| Round | 2 |
| Date | 2026-11-21 |
| Role | CRITIC-DESIGN (spec §22.1 / §22.3) |
| Scope | The core loop as a vertical slice: movement, combat, quest, loot, save. Is it fun and readable? Are the 12 quests meaningful or filler? Does the pilgrim story thread land? |
| Build / commit | `1f7cca0` |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| Prior round | ROUND_1_DESIGN.md — REJECT, 1×P0 + 5×P1 open. Nothing has been fixed since; round 1 findings are re-verified, not assumed. |

## Verdict up front

**REJECT.** The slice's individual mechanics are competent and honestly tested. The slice's
*meaning layer* is not: four of the twelve quests are the same fight with different counters,
six of nine NPCs cannot hold a conversation, the one branching dialogue in the game has one
effectless option, and the loop's terminal step — get the reward, go further — is unreachable.

---

## Evidence base

Everything below was produced by me on commit `1f7cca0`. The suite and bots were re-run for this
round and are still green (`checks: 2919 failures: 0`, BOT-001…011 all `PASS`). New probes written
and run for this round, all read-only, all under `CRITIC_REPORTS/`:

`probe_ending.gd`, `probe_path.gd`, `probe_census.gd`, `probe_npc.gd`, `probe_respawn.gd`.

---

## Findings

| ID | Severity | Finding | Evidence (file:line or command output) | Expected vs actual | Recommendation | Status |
| --- | --- | --- | --- | --- | --- | --- |
| D1-R2 | **P0** | **The loop has no last step.** "Вернуться к NPC → получить награду → отправиться дальше" (TZ §6) terminates in a throne that cannot be used. Carried from D1-R1 and re-verified this round. | `CRITIC_REPORTS/probe_ending.gd` → `PROBE prompt_after_king_dead=Выбрать судьбу`, `PROBE ending_after_interact=` (empty), `PROBE has_choose_hook=false`. `ending_altar.gd:63-70`; `hud.gd:2378-2380` admits "nothing in the world does today". | Expected: the final interact commits an ending and shows the victory screen. Actual: a toast line, `GameState.ending == ""`, no victory screen, no credits, no way to finish. | Ship the altar choice row (three rows, ↑↓ + E, matching the defeat-panel input style) wired to `EndingAltar.choose()`; cover it with a bot scenario that asserts a non-empty `GameState.ending`. | open |
| D2-R2 | **P1** | **Four of the twelve quests are the same twenty tiles of forest.** q01, q02, q03, q09 all resolve to killing wolves and boars in the spawn clearing, and the drops cross-feed so the counters advance together. | `data/quests.json`: q01 `kill ash_wolf ×3` (Edrik), q02 `collect wolf_fang ×4` (Mila), q03 `kill ash_boar ×2` (Mila), q09 `collect wolf_fang ×3` (Seris). Drop tables: `scenes/enemies/wolf.tscn` `loot_item="wolf_fang" loot_chance=0.75`; `scenes/enemies/boar.tscn` `loot_item="wolf_fang" loot_chance=0.4` — **a boar drops a wolf's fang**. My census: forest holds 5 ash_wolf + 2 ash_boar, all within the one zone the player starts in. | Expected (TZ §13.1: each quest has a distinct task and a distinct *Результат*; §1.2 "Исследование с наградой"): four different activities. Actual: one activity, four counters, and a loot table that contradicts the fiction. | Give the boar a boar drop (tusk/hide) and route q03's reward through it; move q09 to a different resource (herbs, grist) so the miller's errand is not a second wolf count. | open |
| D3-R2 | **P1** | **q10 is offered at level 1 in the village and cannot be completed at level 1.** Its target drops only in zones 2 and 3, with no gate and no hint. | `data/quests.json` q10 `collect bone_shard ×2`, giver `npc_alvena`, who spawns in the forest village (`forest.gd:463`). `bone_shard` drop sources (`grep -rn "bone_shard" scripts/ data/`): `skeleton.tscn` (`ruin_skeleton`, ruins) 0.5 and `bone_crawler.tscn` (dungeon) 0.45. Nothing gates the offer: `Villager.interact` starts the first `STATE_AVAILABLE` quest unconditionally (`scripts/npcs/villager.gd:47-53`). | Expected (TZ §13.3 "Недоступен → доступен → активен": a quest becomes available when it can be done; §6 loop: "получить поручение → **подготовиться** → исследовать **область**"): the village does not hand out ruins-and-dungeon errands to a level-1 character. Actual: Alvena offers it on frame one; a player who accepts has no way to know the material is two zones deep. | Gate q10 on `ruins_unlocked` (or on q04 done) via the `requires` field from D3-R1, and have the journal state where the material comes from. | open |
| D4-R2 | **P1** | **Six of nine NPCs have no conversation at all.** They are pure quest terminals, which is the one thing TZ §12 forbids in as many words. | `data/dialogue.json` contains exactly 7 trees: `edrik_intro`, `edrik_after_hunt`, `mila_intro`, `pilgrim_{forest,ruins,dungeon,fortress}`. `Villager.interact` looks up `"<speaker_id>_intro"` (`villager.gd:34`); the speaker ids in the build are `seris` (`forest.gd:458`), `alvena` (`forest.gd:463`), `nela` (`dungeon.gd:487`), `oren` (`fortress.gd:444`) — **none of those keys exists**, so all four fall through to the single-line `EventBus.dialogue_requested` fallback (`villager.gd:55-77`). `Yorek` (`Merchant`) and `Bran` (`Smith`) open shop/craft panels and never speak. | Expected (TZ §12: "NPC должны ощущаться жителями одного поселения, а не терминалами выдачи квестов. Каждый важный персонаж имеет мотивацию, собственный голос, визуальную деталь, расписание, личную линию и изменение реплик после ключевых событий"): 8–10 characters. Actual: Edrik (2 trees), Mila (1 tree), Pilgrim (4 trees) have writing; Seris, Alvena, Nela, Oren, Yorek, Bran have one toast line each. | Add `<speaker>_intro` + `<speaker>_after` trees for Seris, Alvena, Nela and Oren at minimum, each with a stated motive and one line that changes after a world event. | open |
| D5-R2 | **P1** | **The game contains exactly one player choice, and half of it does nothing.** | My parse of `data/dialogue.json`: `dialogues total 7 with any choice 1`. The only node with options is `edrik_intro:n2` — "Я сделаю это." (sets `accepted_wolf_hunt`, starts q01) and "Дай мне награду вперёд." (→ n4, a scolding line, `next: "n2"`, i.e. loop back with no flag, no cost, no state change). | Expected (TZ §12.2: "Ключевые разговоры имеют 2–3 варианта выбора, последствия которых описаны явными флагами. **Варианты без реального эффекта помечать как косметические**"): consequential options, cosmetic ones labelled. Actual: one branch, one dead option, nothing labelled. | Either give the greedy option a real effect (a small gold advance against a later reputation line) or delete it; then add 2–3 option nodes to the Act I and Act IV conversations that set flags the endings actually read. | open |
| D6-R2 | **P1** | **The pilgrim thread lands as writing and misses as a story system.** It is the best text in the project and it changes nothing the player can see or act on. | `scripts/npcs/pilgrim.gd:9` — *"He is deliberately NOT a quest giver."* The four trees set only `pilgrim_met_*` flags plus `pilgrim_truth_known` (`data/dialogue.json`). No quest references any of them; the journal has no lore section to record them; `EndingAltar.choose()` accepts `crown` with no requirement at all (`ending_altar.gd:71-84`), so the "truth" the pilgrim gives is never spent. | Expected (TZ §13.1 Q11: "**Паломник** — Собрать четыре фрагмента сведений о ритуале → Дополнительный диалог с финальным боссом"; §4.4: "«Пепельный венец» — **скрытая** концовка при выполнении цепочки хранителя и сборе редких печатей"): a tracked four-fragment line that unlocks extra boss dialogue and gates the hidden ending. Actual: four untracked monologues that gate nothing. | Make the four fragments a tracked quest with a journal entry per fragment; require `pilgrim_truth_known` for the `crown` ending; add the extra pre-fight boss line the TZ asks for. | open |
| D7-R2 | **P2** | **Clearing a zone is undone by walking out and back.** Enemies respawn in full on re-entry, so the world has no memory of violence. | `CRITIC_REPORTS/probe_respawn.gd` → `PROBE_RESPAWN forest alive_before=20 after_kill=0 after_reentry=20 respawned=true`. Mechanism: `ZoneManager` rebuilds `World` from the zone script on every `travel()`, and every hostile is spawned in the zone build pass; only chests, doors and the key carry flags. | Expected (TZ §1.2 "Причина и следствие … Состояния NPC и мира переживают сохранение/загрузку"; §12.1 "состояние меняется после сюжетного события"): cleared areas stay cleared, or at least the ones the story says you cleared. Actual: the forest is as dangerous after the Root Mother dies as it was before you arrived. | Persist per-spawner `cleared` state in `GameState` keyed by stable spawner id, and let the village/road reflect it (fewer patrols after Act I). | open |
| D8-R2 | **P2** | **The rarest item in the game is farmable from a respawned boss at 100 % drop rate.** | `scenes/enemies/root_mother.tscn:25-26` `loot_item = "swift_ring"`, `loot_chance = 1.0`. `swift_ring` is the most expensive equipment in `data/items.json` (price 120). Bosses respawn with the zone (D7-R2). `grep -n "set_flag\|_on_death\|reward" scripts/ai/boss.gd scripts/ai/boss_root_mother.gd` → no one-time reward guard exists. | Expected (TZ §11.1: "После победы награда, сюжетный флаг и открытие прохода выдаются **ровно один раз**"): a boss drops its unique reward once. Actual: kill Root Mother, leave to the forest exit, come back, kill her again — another `swift_ring`, forever. | Gate boss loot on a `boss_<type>_rewarded` flag set in the boss death path, and stop respawning story bosses. | open |
| D9-R2 | **P2** | **The crafting economy is one material deep.** Every recipe in the game eats wolf fangs. | `data/recipes.json`: `potion_health` needs `wolf_fang ×2`; `potion_mana` needs `wolf_fang ×1`; `temper_sword` needs `wolf_fang ×3`; `reinforce_armor` needs `wolf_fang ×2`. `bone_shard` is consumed by nothing — it exists only as q10's target (`grep -rn "bone_shard" data/` → quests + items only). | Expected (TZ §14.4: crafting from gathered plants and resources; §5: forest gives "Рецепты, материалы"): a material web where different zones feed different stations. Actual: one drop from one wolf is the entire crafting economy, and the second material is dead weight. | Introduce 2–3 zone-specific materials (herbs from the forest, bone dust from the dungeon, forge scrap from the fortress) and re-cost the recipes across them. | open |
| D10-R2 | **P3** | **The one written herbwife conversation is decorative.** Mila's dialogue never starts either of her quests. | `data/dialogue.json` `mila_intro` is 2 nodes, no effects, no quest action; its last line is "Вернёшься — поговорим." q02/q03 are started only by the `Villager` fallback path (`villager.gd:47-53`), which runs *after* the runner returns false — and the runner returns true here, so the conversation consumes the interaction and the quest is offered on the *next* talk. | Expected (TZ §12.2: dialogue nodes carry "последствия"; §6 loop: the NPC is the quest interface): talking to Mila offers her work. Actual: the first conversation is a greeting that ends by promising something it does not do; the player must talk to her twice. | Add `{"quest": "q02_gather_fangs", "action": "start"}` to the last node of `mila_intro`, matching how `edrik_intro:n3` does it. | open |

---

## What is genuinely good in the slice

I want to be precise here, because these are not trivial and they are the reason the game is
worth fixing rather than rewriting.

- **The combat verbs are real and the defensive game works.** `player.gd:395-399` gives dash
  i-frames (`_iframe_left = maxf(_iframe_left, DASH_IFRAMES)`), and BOT-007 independently confirms
  telegraph-before-damage: `telegraph_seen=true; trap_damage_at_distance=0; trap_damage_crossing=0`.
  BOT-003 confirms `max_control_ms=0` — the player is never locked out.
- **Six statuses and genuine elemental combos.** `status_component.gd:12` defines
  `BURN, CHILL, SHOCK, ROOT, BLIGHT, STUN`, and `combinations.gd` implements real cross-element
  interactions (`_fire_roots`, `_lightning_wet`, smoke zones, chain radius 70). BOT-004 confirms
  exact mana costs and cooldown blocking: `casts=4/4; exact_costs=4/4; cooldown_blocks=4; statuses=3`.
  This is more magic depth than most slices of this size carry.
- **Save/load is trustworthy.** BOT-009: `saved; gold=7 hp=100` — the ledger round-trips and the
  slot is cleaned up after.
- **The quest ledger is honest.** BOT-006: `reward=gold+60 xp+50 potions+2; retalk_state=done
  paid_again=false` — no double payment, which is a bug most projects of this kind ship with.
- **The ruins puzzle is a real spatial beat and it is not bypassable.** I tried to bypass it and
  failed (round 1, recorded as correct).

The problem is not the mechanics. The problem is that the mechanics are wrapped around a very
small, very repetitive set of reasons to use them.

---

## Scores

| Criterion | Score | One-line justification |
| --- | --- | --- |
| Полнота требований | **4/10** | Movement, combat, loot and save are all present and correct, but §12 (characters) and §12.2 (choices) are ~20 % delivered and the loop's terminal step is missing. |
| Корректность систем | **7/10** | Every slice mechanic I probed behaves exactly as documented — statuses, i-frames, telegraphs, save round-trip, no double reward; the one broken thing is the ending seam. |
| Игровое качество | **4/10** | Combat is good enough to be fun in short bursts, but 4 of 12 quests are the same fight, q10 is uncompletable when offered, and there is exactly one choice in the whole game. |
| UX и читаемость | **6/10** | Threat and resource state are readable and telegraphs are honest; the player is left with no signal about where a quest's material actually comes from (D3-R2) and no journal record of the story they were told (D6-R2). |
| Техническая надёжность | **8/10** | Suite and bots green again this round, probes clean, no flake observed; still no soak beyond 75 s and no replay. |

**Weighted design score: 4.8/10.** Slightly below round 1 — round 1's optimism about quest
variety did not survive reading the objective tables side by side.

---

## Closing criteria for this round

1. **D1-R2** — same as D1-R1: a bot finishes the game through the HUD.
2. **D2-R2 + D9-R2** — no two active quests share a target type in the same zone, and at least
   three distinct materials are consumed by crafting. A test asserts the drop table matches the
   fiction (no boar dropping a wolf fang).
3. **D3-R2** — every quest's target is obtainable in a zone the player can already reach when the
   quest becomes available; a test walks all 12 and asserts it.
4. **D4-R2 + D5-R2** — ≥8 NPCs have a real dialogue tree, ≥4 conversations have 2–3 options with
   flag effects, and every effectless option is either removed or labelled cosmetic.
5. **D6-R2** — the pilgrim's four fragments are a tracked quest and `crown` requires
   `pilgrim_truth_known`.

---

## What I could NOT verify

- **Fun.** No human played the slice. Whether combat *feels* good, whether the dash window is
  generous or punishing, whether 5 wolves in a clearing is boring or cozy — all unverified. I can
  prove the quests are repetitive from their data; I cannot prove the player minds.
- **Difficulty feel and death fairness.** BOT-011 proves a passive player takes damage
  (`hp=100->92`); nothing proves a competent human survives Act I.
- **Audio feedback.** Headless and windowed runs, never listened. Telegraph *sound* is unverified;
  only telegraph *geometry* is.
- **Readability at 1080p+ and on a small laptop screen.** Screenshots were captured at the base
  480×270 viewport.
- **Whether the pilgrim's monologues land on a reader.** I judged the text as a reader who wanted
  them to land; that is a bias I am declaring, not eliminating.
- **Input remapping persistence across sessions** — the code exists (`input_bindings.gd`) but I
  did not run a two-session remap test.

## Conflicts with other critics

None yet — `CRITIC_REPORTS/` contained only my own round-1 file when I started.

## Release blockers

D1-R2 (P0); D2-R2, D3-R2, D4-R2, D5-R2, D6-R2 (P1).

## Final recommendation

**REJECT.** The vertical slice is a competent *engine* slice and a weak *game* slice. Combat,
magic, loot accounting and saves are done properly and tested properly — I would not touch any of
them. The content wrapped around them is four copies of one forest fight, six silent NPCs, one
half-functional choice, and a story thread that says interesting things to a player who has no way
to act on them. Fix the meaning layer, not the machinery.
