# CRITIC-PLAYER — ROUND 1 (§22.2 аудит до массовой разработки)

```text
CRITIC REPORT
Round: 1
Role: PLAYER (UX и арт-директор, spec §22.1)
Build / commit / run_id: 979db16 / PEPL-PLAYER-R1-2026-11-23
Score: 4.6/10     Verdict: REJECT
```

| Field | Value |
| --- | --- |
| Gate | §22.2 — before mass content production |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf`, `/opt/homebrew/bin/godot` |
| My scope | визуальное единообразие стиля, читаемость пиксельных спрайтов, контраст окружения, доступность управления и интерфейса |
| Independence | I wrote none of this. Every number below is either read off a screenshot I rendered myself or computed from a constant in the shipped source on `979db16`. Nothing taken from `PROCESS.md` or `README.md` on trust. |
| Not repeated here | DESIGN and GODOT findings. See `DESIGN_SUMMARY.md`, `GODOT_SUMMARY.md`. |

## How I produced the evidence

Screenshots were rendered by the real renderer (not `--headless`), through the project's own hook:

```bash
PEPEL_SCREENSHOT=/tmp/cp_world.png godot --path .            # + 13 more probes
```

14 frames at **480x270** (raw viewport), all `err=0 size=(480, 270)`, logs in `/tmp/log_*.txt`:
`menu world ruins dungeon fortress inventory character skills journal map shop craft dialogue settings`.
PIL is not installed, so I wrote a pure-Python PNG decoder (`/tmp/pngtool.py`) that does WCAG relative
luminance, contrast, histogram clustering of text vs background, and panel bounding-box detection.
Every contrast ratio below is `(L1+0.05)/(L2+0.05)` on sRGB-decoded pixels from those frames.
Reference thresholds used: **4.5:1** body text, **3:1** large text and non-text UI graphics (WCAG 1.4.11).

---

## 1. First contact — what a new player sees

The menu is the strongest thing in the build. It is the only screen where the text passes comfortably,
because it is the only screen where text sits on a dark plate instead of on the world.

| Element | Colour as rendered | core contrast | body-mean contrast | verdict |
| --- | --- | --- | --- | --- |
| Title «Пепел старого королевства» | `RGB(245,220,128)` | 14.29:1 | 14.03:1 | pass |
| Menu items | — | 11.9–13.3:1 | 8.2–9.8:1 | pass |
| Disabled item | `RGB(187,192,181)` | 10.41:1 | 7.00:1 | pass, but see CRITIC-P1-06 |
| Subtitle «сборка 001» | — | 5.43:1 | **4.17:1** | **fails 4.5** |
| Bottom hint line | — | 5.53:1 | **4.21:1** | **fails 4.5** |

Then the player presses Enter and the game stops being a dark-panel game. Everything below is the world.

---

## 2. Findings

### CRITIC-P1-01 | Severity: **P1** — all four zones share one byte-identical floor colour

**Evidence:** `/tmp/cp_world.png`, `/tmp/cp_ruins.png`, `/tmp/cp_dungeon.png`, `/tmp/cp_fortress.png`,
sampled region x150..200 y100..140 (floor, no entities).

| Zone | `RGB(173,188,58)` share of sampled floor | second colour |
| --- | --- | --- |
| Лесной край | 65.20% | peach `RGB(255,173,93)` 19.7% |
| Руины у опушки | **79.35%** | peach `RGB(255,173,93)` 14.3% |
| Подземелье под руинами | 38.90% | — |
| Древняя крепость | **92.05%** | — |

The exact same 8-bit value `RGB(173,188,58)` is the dominant floor pixel in a sunlit forest, in ruins,
in an underground dungeon and in an ancient fortress. Peach `RGB(255,173,93)` is likewise identical in
forest and ruins. The dungeon is the only zone that partially diverges, and the fortress is the *least*
divergent of all — a fortress interior reads as 92% forest grass.

**Expected:** §23 stage 1 gate requires «единый master tileset/палитра» *and* distinct zones; §22.2 asks
me to audit «контраст окружения». A player should know they changed zones before any text tells them.
**Actual:** terrain colour carries zero zone information. Zone identity is delivered **only** by a text
label — which is itself the least legible label in the HUD (CRITIC-P1-02) and is truncated in the
dungeon (CRITIC-P2-04).
**Risk / impact:** the world has no spatial memory. Four areas play as one area four times. This is a
pre-production finding precisely because §22.2 forbids mass content on an unresolved style defect —
every additional zone built on this palette inherits it.
**Recommended fix:** give each zone a distinct floor hue *and* luminance band, not just a prop set. Keep
one master palette, but reserve a different luminance per zone (forest mid-yellow-green, ruins cold grey,
dungeon dark desaturated, fortress warm dark stone). Re-measure with the same script.
**Acceptance test after fix:** the four sampled regions must not share any single RGB value above 20%
share, and pairwise floor contrast between zones ≥ 1.5:1.

### CRITIC-P1-02 | Severity: **P1** — world HUD text is legible only by its drop shadow

**Evidence:** `/tmp/cp_world.png`, `/tmp/x_world_hud.png` (6x nearest-neighbour), `/tmp/x_world_ctrl.png`.

| HUD element | glyph fill | fill vs grass | shadow vs grass |
| --- | --- | --- | --- |
| Zone line (`Color(0.66,0.80,0.68)` → `RGB(168,204,173)`) | `RGB(169,200,147)` measured | **1.13:1** | 9.15:1 |
| Controls hint line | `RGB(180,189,141)` | **1.06:1** | — |
| Gold «0 з.» | `RGB(211,198,78)` | **1.19:1** | — |

`RGB(168,204,173)` against the floors it floats on: grass **1.19:1**, dirt/peach **1.05:1**, stone 1.73:1,
dungeon stone 2.96:1. Between **46.5% and 70.7%** of the pixels inside the label bands are below 1.5:1
against the grass behind them.

The reason is structural, not incidental: `hud.gd` `_make_text()` applies a **1px drop shadow**
(`font_shadow_color` alpha 0.85, offset 1,1). A shadow is not an outline. It protects the bottom and
right edge of a glyph and leaves the top and left edge sitting on raw grass. What survives at 1.13:1 is
the shadow, not the text.

**Expected:** §22.5 «Игрок понимает цель, угрозу, эффект действия и состояние ресурсов» — 10/10 meaning.
**Actual:** the always-on control reference and the zone name are the two least readable strings in the
game, on the surface they are drawn over.
**Risk / impact:** a new player cannot read the control hints during play, which is the only moment they
need them. The README documents the controls well (see CRITIC-P2-05), so the game is only playable by
someone who read the manual first.
**Recommended fix:** put the HUD on an opaque or heavily darkened plate (the panels already do this and
their text passes at 6.0–12.2:1 — the technique exists in this codebase), or switch the world text to a
true 4-side outline instead of a 1px offset shadow. Either fix is local to `_make_text`/HUD layout.
**Acceptance test after fix:** body-mean contrast of every HUD string ≥ 4.5:1 against the *floor pixel
directly behind it*, measured per zone with `/tmp/panelmeasure.py`, not against a synthetic background.

### CRITIC-P1-03 | Severity: **P1** — the resource bars are colour-only

**Evidence:** `scripts/ui/hud.gd` — `_hp_label = _make_bar_label("HP")`, then in `_on_health()`:
`_hp_label.text = "%d" % current`. Same pattern for MP. `_on_xp()` sets no label at all.
Plus `/tmp/cp_world.png` region x140..235 y0..32.

Two separate defects in one:

1. **The labels are destroyed on the first signal.** "HP" and "MP" exist only for the frames before the
   first `health_changed`/`mana_changed` emit, i.e. never in normal play. They are replaced by numbers.
   XP has no label at any point.
2. **There is no plate behind the bars.** x140,y0..32 is pure grass — grass is visible in the gaps
   *between* the bars. HP `RGB(199,56,61)` vs grass **2.41:1**, MP `RGB(61,117,209)` vs grass **2.05:1**,
   and HP vs MP **1.18:1** against each other.

**Expected:** a player glancing at the HUD knows which bar is which and how full each is.
**Actual:** three unlabelled coloured strips floating on grass, two of which are 1.18:1 apart, with the
third (XP) forced to **3px** tall while HP/MP are 7px (`BAR_H = 7.0`, XP bar `Vector2(BAR_W+20, 3)`),
and `show_percentage = false`.
**Risk / impact:** red/green/blue is the sole channel. For a deuteranope, red and green at 1.18:1
luminance separation are the same bar. The 3px XP strip is below any reasonable minimum target height.
**Recommended fix:** restore static "HP"/"MP"/"XP" captions outside the value label instead of reusing
the same label; put all three bars on the dark panel plate the menus already use; raise XP to ≥ 5px.
**Acceptance test after fix:** a screenshot of live play shows three readable captions; bar-to-bar
luminance separation ≥ 3:1; each bar ≥ 5px tall at 480x270.

### CRITIC-P1-04 | Severity: **P1** — the font is anti-aliased OS sans, not a pixel font

**Evidence:** `hud.gd` `_make_theme()`:
`SystemFont` with `font_names = ["Helvetica Neue","Arial Unicode MS","Arial","DejaVu Sans","sans-serif"]`,
`default_font_size = 8`.

The game renders at 480x270 and is upscaled. Every glyph is therefore an 8px anti-aliased Helvetica
stretched by a non-integer factor, sitting on 1px-crisp pixel art. Three consequences, all observable:

- **Style break.** The art is hard-edged indexed-looking pixels; the type is soft greyscale AA. This is
  the single most visible style inconsistency in the build and it is present on *every* screen.
- **Platform dependence.** `Helvetica Neue` exists on this macOS host and nowhere else. On Linux the
  same build falls through to DejaVu Sans, on Windows to Arial — different metrics, different wrapping,
  different truncation. The dungeon zone-line truncation (CRITIC-P2-04) is therefore not even
  reproducible-guaranteed across platforms.
- **No scaling.** There is no font-scale setting (see CRITIC-P1-07 in Round 3), so 8px is the floor.

**Expected:** §23 stage 1 gate: «собрать тестовую комнату… проверить масштаб, палитру, фильтрацию».
**Actual:** filtering/scale was never reconciled between the type layer and the sprite layer.
**Recommended fix:** ship a bitmap pixel font as the theme's default `font`, with the SystemFont kept as
a fallback for glyphs it lacks. This also removes the platform dependence.
**Acceptance test after fix:** `git grep -n "SystemFont" scripts/` returns no default-font assignment;
screenshots on two platforms show identical glyph metrics.

### CRITIC-P2-05 | Severity: **P2** — the always-visible control hint omits two actions

**Evidence:** `hud.gd:362`:
`"WASD · ЛКМ удар · ПКМ умение · Space рывок · E действие · I инв · J журнал · M карта · C персонаж · K навыки · F5/F9"`.
`project.godot` `[input]` defines **20 actions**. `scripts/core/input_bindings.gd:13` `REBINDABLE` lists 18,
**including** `pause` and `quick_slot_1..4`.

So the manual and the remap screen are both complete — `README.md:111` documents «Быстрый слот 1–4 … 1 2 3 4»
and `README.md:113` documents «Пауза | Esc». The gap is narrow and specific: the **only control reference
visible during play** is the one that omits Esc and the quick slots. Esc is discoverable only by pressing
it, and quick slots are discoverable only in the README or by scrolling the settings list.
**Recommended fix:** add `Esc пауза` and `1–4 слот` to the hint string, or accept the length cost and drop
the redundant `F5/F9` half to make room.
**Acceptance test after fix:** every action in `REBINDABLE` is either named in the hint line or named in a
panel that is open at the moment the action becomes relevant.

### CRITIC-P2-06 | Severity: **P2** — menu item rhythm is 22px then 11px

**Evidence:** `/tmp/cp_menu.png`, item baselines at y=116, 138, 149, 160, 171.
Pitch 116→138 = **22px**; 138→149→160→171 = **11px**. The first gap is exactly double the rest.
Also: the panel plate is `RGB(13,15,20)` while the backdrop behind it is `RGB(23,25,30)` — the panel is
*darker* than what it sits on, so the border is doing all the separation work alone.
**Recommended fix:** one consistent `separation` value in the menu VBox; make the panel lighter than its
backdrop, as the in-game panels already are.
**Acceptance test after fix:** measured pitch between all menu items varies by ≤ 1px.

### CRITIC-P2-07 | Severity: **P2** — zone entry announces itself twice

**Evidence:** `/tmp/cp_ruins.png`, `/tmp/cp_dungeon.png`, `/tmp/cp_fortress.png` each show the zone name
both in the HUD zone line and in a centred toast, simultaneously.
**Recommended fix:** drop the duplicate once the HUD line is made legible (CRITIC-P1-02), or keep the
toast and drop the permanent line.
**Acceptance test after fix:** one zone name on screen at any instant after travel.

### CRITIC-P2-08 | Severity: **P2** — the dungeon zone name is truncated

**Evidence:** `/tmp/x_dungeon_zoneline.png` renders **«Зона: Подземелье под руин…»** with a visible
ellipsis. Source: `data/zones.json` `"dungeon": {"name": "Подземелье под руинами"}` (22 chars),
`hud.gd` sets `clip_text = true` + `OVERRUN_TRIM_ELLIPSIS` on a `BAR_W + 20` = 112px column.
The code comment above that block asserts the column «fits the longest name in data/zones.json at the 8 px
theme font». **The shipped data falsifies that comment.** Note this also depends on CRITIC-P1-04: the
font is a system font, so whether the name fits is decided by the host OS.
**Recommended fix:** widen the column, shorten the display name, or allow the label to use the full HUD
width. Do not leave a comment asserting a fit that the render contradicts.
**Acceptance test after fix:** all four names from `data/zones.json` render with no ellipsis at 480x270.

---

## 3. Scores (§22.5, CRITIC-PLAYER weights)

| Критерий | Вес | Балл | Обоснование в одну строку |
| --- | --- | --- | --- |
| Полнота требований | 15% | 6 | All §22.2 items exist and are inspectable; nothing is a stub. |
| Корректность систем | 20% | 7 | 14/14 probes rendered `err=0`; no crash, no missing resource in any log. |
| Игровое качество | 20% | 4 | Round 1 does not test feel, but the world is visually one zone (P1-01). |
| **UX и читаемость** | **25%** | **3** | HUD text 1.06–1.19:1, bars colour-only, font mismatched to the art. |
| Техническая надёжность | 20% | 7 | Deterministic capture hook worked exactly as documented. |
| Weighted mean | | **5.2** | |
| **Reported player score** | | **4.6** | Held below the mean: three of the four P1s are in my primary axis. |

## 4. Verdict: **REJECT**

§22.2 states the gate directly: *«не переходить к массовому созданию контента при открытых P0/P1 по
архитектуре, стилю, основному циклу или данным».* I have four open P1 in **стиль** and **контраст
окружения**. Mass zone content built on `RGB(173,188,58)` multiplies CRITIC-P1-01 by every future zone.

Conditions to close (each has an acceptance test above):
**P1-01** distinct zone floors · **P1-02** HUD text ≥4.5:1 against real floor pixels ·
**P1-03** labelled bars on a plate · **P1-04** shipped pixel font as theme default.

## 5. Unverified assumptions

- Animation smoothness, motion readability and VFX density **cannot** be judged from stills. I make no
  claim about them in Round 1. Round 3 addresses telegraphs from source constants instead.
- I could not place the player next to an NPC during a probe, so the `[E]` interact prompt
  (`hud.gd:1473`) was never rendered. It exists in code; I did not see it on screen.
- Contrast figures are computed on the 480x270 native buffer. The player sees an upscaled version;
  upscaling does not improve the measured ratios but softens them further, so my numbers are the
  optimistic case.
- `journal` and `dialogue` panel bounding boxes were not auto-detected by `/tmp/panelmeasure.py`; I read
  those two frames visually only and drew no contrast conclusions from them.

## 6. Conflicts with other critics

None. DESIGN and GODOT report on loop/systems and do not measure rendered contrast. If a later round of
mine contradicts a PASS from either, §22.6 applies and the contradiction goes to the technical lead with
both sets of numbers, not to an average.

## 7. Release blockers

CRITIC-P1-01, CRITIC-P1-02, CRITIC-P1-03, CRITIC-P1-04. §22.4: «Релиз запрещён при любом открытом P0 или P1.»

## 8. Final recommendation

Do not author more zones yet. Spend one pass on the palette-per-zone decision and the font decision —
both are cheap now and expensive after content exists. Then re-run my capture set; `/tmp/panelmeasure.py`
and `/tmp/pngtool.py` will re-measure the whole matrix without new work.
