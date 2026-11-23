# CRITIC-PLAYER — ROUND 3 (§22.4 предрелизный аудит)

```text
CRITIC REPORT
Round: 3
Role: PLAYER (UX и арт-директор, spec §22.1)
Build / commit / run_id: 979db16 / PEPL-PLAYER-R3-2026-11-23
Score: 4.2/10     Verdict: REJECT
```

| Field | Value |
| --- | --- |
| Gate | §22.4 — pre-release |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| My scope this round | §22.4 «провести визуальную инспекцию всех зон: нет незакрытых пустот в тайлмапе, случайных спрайтов, обрезанных анимаций, неверного масштаба, **нечитабельных телеграфов** и пересечений слоёв»; плюс настройки, интерфейс, доступность |
| Independence | Same commit `979db16`, same 14 self-rendered frames, same `/tmp/pngtool.py`. No fix landed between my rounds; the score drops because §22.4 asks the hardest questions, not because the build regressed. |

**The same build was inspected three times.** Round 1 asked "is the style coherent", Round 2 asked "can
the player read an attack", Round 3 asks "can this ship". The answer stays no for the same root cause,
now measured across all four zones.

---

## 1. All-zone visual inspection (§22.4, item by item)

| §22.4 inspection target | Result | Evidence |
| --- | --- | --- |
| незакрытые пустоты в тайлмапе | **not found** in the 4 captured frames | no background-clear gaps visible in any zone frame |
| случайные спрайты | **not found** | no stray/misplaced sprite in any frame |
| обрезанные анимации | **unverifiable** | stills only — see §7 |
| неверный масштаб | **FOUND — P2-18** | player 14×15 vs enemies 14×14 |
| нечитабельные телеграфы | **FOUND — P1-09/P1-10, confirmed again** | 1.02–1.58:1, 1.06–1.51:1 |
| пересечения слоёв | **not found** in stills; **HUD layering is the real problem** | HUD has no plate, P1-02/P1-03 |
| distinct zones | **FOUND — P1-01, confirmed again** | one floor colour in all four zones |

I am reporting the clean rows as clean. I found no tilemap holes, no stray sprites and no z-fighting in
any of the four zone frames, and that is worth stating because it means the world *assembly* is sound.
What fails is the palette and the readability layer on top of it.

---

## 2. CRITIC-P1-18 | Severity: **P1** — enemies camouflage into their own zone floor

**Evidence:** `/tmp/x_world_ents.png` (6x nearest-neighbour of `/tmp/cp_world.png`), sprite pixels
segmented from background by the measured floor colour.

| Subject | body colour | vs the floor it stands on | fraction of sprite below 1.5:1 |
| --- | --- | --- | --- |
| **ENEMY-B** | head `RGB(242,173,125)` | peach `RGB(255,173,93)` → **1.03:1** | **51%** |
| **ENEMY-A** | body `RGB(160,159,77)` | grass `RGB(173,188,58)` → **1.33:1** | high |
| ENEMY-A | body vs floor speckle `RGB(230,124,68)` | **1.03:1** | — |
| Player | dark `RGB(20,27,27)` | grass → **9.47:1** | 7% |
| Player | maroon `RGB(84,60,82)` / `RGB(143,62,86)` | high | — |
| Player | white visor | highest-contrast pixel in frame | — |

**Half of ENEMY-B's pixels are below 1.5:1 against the dirt floor of the zone it spawns in**, and its head
is 1.03:1 — the same colour as the ground. ENEMY-A's olive body is 1.33:1 against grass. Meanwhile the
player is deliberately, correctly high-contrast (9.47:1 dark body, white visor, 7% camouflaged).

So the art direction understood the requirement for the player and did not apply it to enemies. The
asymmetry is the finding: this is not a uniform "low contrast pixel style" choice, it is one half of the
readability rule implemented.

**Expected:** §22.1 asks me directly — *«Выделяются ли враги и интерактивные объекты?»* §24:
*«Игрок не видит угрозы и телеграфы»* is a listed risk with mandated prevention.
**Actual:** the player pops; the threats do not. In a zone with several enemies, the ones that camouflage
are the ones that reach you.
**Risk / impact:** combined with P1-09 (invisible telegraph), the enemy is invisible *while approaching*
and its warning is invisible *while attacking*. Those two defects compound: neither is fatal alone, and
together they remove the player's ability to see and respond to danger.
**Recommended fix:** the standard silhouette-contrast rule — enemies get a dark or saturated outline plus
a hue outside their spawn zone's floor family. The player already demonstrates the recipe in this build.
**Acceptance test after fix:** for every enemy type, ≥90% of sprite pixels ≥3:1 against the floor of every
zone it spawns in; no single sprite colour below 2:1.

## 3. CRITIC-P2-19 | Severity: **P2** — no size hierarchy between player and enemies

**Evidence:** measured sprite extents — **player 14×15 px, enemies 14×14 px**. All three sampled enemies
share the same rounded-blob silhouette as each other and broadly as the player.

At 480×270 with a 14px actor, a 1px size difference is the entire hierarchy. Combined with the shared
blob outline, the frame reads as "several similar round things", and the only channel separating friend
from foe is colour — which P1-18 shows is unreliable for two of three enemies.

`enemy.gd:95-98` shows the intent was recognised:
> `## Colour of this enemy's own sprite, so a reused placeholder sprite still reads as a different creature.`

Colour alone is doing the job that silhouette and scale should do.
**Recommended fix:** differentiate silhouette (a tall thin archer, a wide low bruiser) and give bosses a
clearly larger footprint. Do not rely on tint.
**Acceptance test after fix:** enemies identifiable as friend/foe in a greyscale, blurred thumbnail of a
combat frame.

## 4. CRITIC-P2-20 | Severity: **P2** — the HUD sits directly on the world with no plate, in all zones

Round 1 established the fill-vs-grass ratios (1.06–1.19:1). Across all four zone frames the same
structural cause repeats: `x140, y0..32` is pure world — grass visible between the bars — and the zone
line, gold count and level label all float on whatever the ground happens to be.

The zone label colour `Color(0.66,0.80,0.68)` → `RGB(168,204,173)` measures against each floor:
grass **1.19:1**, dirt **1.05:1**, stone 1.73:1, dungeon stone 2.96:1. It only clears 3:1 on the darkest
floor, i.e. it works by accident in the dungeon and fails everywhere else.

The in-game panels prove the fix already exists in this codebase: they are opaque and their text measures
6.0–12.2:1. The HUD simply never got the same treatment.
**Recommended fix:** one dark plate behind the whole HUD column, matching `_panel_style()`.
**Acceptance test after fix:** every HUD string ≥4.5:1 in all four zone captures.

## 5. CRITIC-P2-21 | Severity: **P2** — duplicated zone announcement, one copy truncated

Carried from Round 1 (P2-07, P2-08) and re-confirmed in all three travel frames: the zone name appears
simultaneously in the HUD line and in a centred toast, and in the dungeon the HUD copy renders
**«Зона: Подземелье под руин…»** with a visible ellipsis (`/tmp/x_dungeon_zoneline.png`) because
`data/zones.json`'s «Подземелье под руинами» does not fit the `BAR_W + 20` = 112px column that a code
comment claims it fits.

Pre-release this matters more than it did in Round 1: it is the kind of defect a player screenshots and
posts. One of the two copies should go, and the surviving one must not truncate.

## 6. CRITIC-P2-22 | Severity: **P2** — no accessibility surface at all (re-confirmed, now blocking)

Round 2 raised this as P1-11. At the pre-release gate it stands unaddressed and now blocks release under
§23 stage 8 («accessibility» is a listed deliverable) and §24 («настройки интенсивности» is the mandated
prevention for the VFX-visibility risk).

Confirmed state on `979db16`:
- `settings_panel.gd:414-421` — exactly two sections, «Управление» and «Звук». No display, no VFX
  intensity, no font scale, no colourblind mode.
- `player.gd:593-594` — `_flash_timer = 0.12; modulate = Color(1.0, 0.45, 0.45)`, hardcoded.
- `enemy.gd:419-423` — `_flash_timer = 0.1; sprite.modulate = sprite_tint * Color(1.6, 1.2, 1.2)`, hardcoded.
- `hud.gd` `_make_theme()` — `default_font_size = 8`, no scale control.
- `grep -rn "shake" scripts/` → **0 matches**. No camera shake exists, which genuinely reduces
  photosensitivity exposure and I credit it here rather than inventing a risk.

The rarity-tier issue (P2-15: `common` vs `legendary` at **1.01:1** luminance) is also unmitigated in the
list view, since the Russian tier name only appears for the selected row.

## 7. What I could not verify — stated as limits, not as passes

§22 forbids substituting explanations for defects, and the same honesty applies to my own PASS rows.

- **Animation smoothness, clipped animations, VFX density, particle budget** — not judgeable from
  stills. §22.4 asks about «обрезанных анимаций»; I have **no verdict** on that row.
- **Frame-accurate telegraph pixels** — my 1.02–1.58:1 figures are `scene colour × modulate`, alpha-blended
  over floor colours measured from real frames. Inputs measured, compositing calculated. Whoever fixes
  P1-09 should produce a frozen warning frame to close it.
- **Interact prompt `[E] …`** (`hud.gd:1473`) — never rendered in any probe; no NPC in range. Exists in
  code, unseen by me.
- **Long-session stability, soak, layering over time** — outside my capture method. GODOT's territory.
- **`journal` and `dialogue` interiors** — my panel detector failed to bound them; read visually only, no
  contrast figures claimed for those two frames.
- **Upscaling** — all numbers are from the native 480×270 buffer. The player sees an upscaled image, so
  my ratios are the *optimistic* case.

## 8. Scores (§22.5, CRITIC-PLAYER weights)

| Критерий | Вес | Балл | Обоснование |
| --- | --- | --- | --- |
| Полнота требований | 15% | 5 | All screens and zones exist; accessibility deliverable (§23 stage 8) absent. |
| Корректность систем | 20% | 7 | 14/14 probes `err=0`; no crash, no missing resource, no stuck modal. |
| Игровое качество | 20% | 4 | Threats camouflage and warnings are invisible; combat reads as unfair. |
| **UX и читаемость** | **25%** | **2** | Telegraph 1.02–1.58:1, traps 1.06–1.51:1, 51% of one enemy camouflaged, HUD 1.05–1.19:1, footer 2.92:1. |
| Техническая надёжность | 20% | 7 | No tilemap holes, no stray sprites, no layer intersections, no shake. |
| Weighted mean | | **4.8** | |
| **Reported player score** | | **4.2** | Held below the mean: five open P1, all in my primary axis. |

Round 1 → 2 → 3: **4.6 → 4.9 → 4.2**. Round 2 scored higher than Round 1 only because the panel system
turned out to be genuinely sound (opaque, consistent border, body text 6.0–12.2:1) once I measured it.
Round 3 is the lowest because §22.4 forces the enemy-readability and all-zone questions together.

## 9. Verdict: **REJECT**

§22.4, verbatim: *«Релиз запрещён при любом открытом P0 или P1.»*

Open P1 on `979db16`: **P1-01** zone floors · **P1-02** HUD text · **P1-03** colour-only bars ·
**P1-04** system font · **P1-09** attack telegraph · **P1-10** trap telegraph · **P1-11** no accessibility
section · **P1-12** settings footer 2.92:1 · **P1-18** enemy camouflage.

This is a **readability rejection, not a stability rejection**, and I want that distinction on the record
so the report is not over-read. The build is not broken: it boots, all fourteen screens render, panels
are well made, the manual is complete, there is no camera shake, no tilemap holes and no stray sprites.
What fails is narrower and more fundamental — a player cannot reliably see the things they must react to.

Conditions to close, cheapest first, each with an acceptance test above:

1. **P1-09 + P1-10** — outlined, higher-alpha, cool-hued warning shapes. One change, two files, removes
   the worst defect in the build.
2. **P1-18** — enemy outline + hue outside each spawn zone's floor family.
3. **P1-02 + P1-03 + P2-20** — one dark plate behind the HUD, restore HP/MP/XP captions, XP bar ≥5px.
4. **P1-01** — a distinct floor luminance band per zone.
5. **P1-11 + P1-12** — «Экран» settings section with flash intensity and font scale; footer ≥4.5:1.
6. **P1-04** — ship a pixel font as the theme default.

Items 1–3 are the ones that change how the game plays. Items 4–6 are palette and configuration decisions
that should be made before more zones are authored, not after.

## 10. Conflicts with other critics

None. My findings are measured contrast ratios on self-rendered frames and arithmetic on shipped
constants; they do not overlap DESIGN's loop/economy analysis or GODOT's architecture review. If a
developer closes P1-09 on the grounds that the telegraph code executes correctly, that is not a
disagreement to average (§22.6) — the code running and the warning being visible are different claims,
and §24 already names telegraph visibility as the requirement.

## 11. Release blockers

All nine P1 above. Per §22.6, data safety, unprovability of progression, progress loss and engine
crashes outrank aesthetics — none of those are at issue here, and none of my blockers are aesthetic
preference: each is a measured failure of a graphic the player needs in order to act, against a
threshold the industry applies to exactly that case.

## 12. Final recommendation

Do not release. Do not author more zones either — P1-01 multiplies with every zone added on the current
palette. Close items 1–3 first and re-run my capture set: `/tmp/pngtool.py` and `/tmp/panelmeasure.py`
re-measure the entire matrix from fourteen screenshots with no new tooling, so re-verification after the
fix is cheap and, per §22.6, must be done by an independent critic rather than self-certified.
