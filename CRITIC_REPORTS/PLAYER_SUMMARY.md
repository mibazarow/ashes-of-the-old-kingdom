# CRITIC-PLAYER — SUMMARY OF ALL THREE ROUNDS

| Field | Value |
| --- | --- |
| Role | CRITIC-PLAYER (spec §22.1) — UX и арт-директор: читаемость боя и окружения, UI, обучение, управление, визуальная целостность, доступность |
| Build audited in all three rounds | `979db16` |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` (`/opt/homebrew/bin/godot`) |
| Date | 2026-11-23 |
| Rounds | ROUND_1_PLAYER.md (§22.2 pre-production) · ROUND_2_PLAYER.md (§22.3 vertical slice) · ROUND_3_PLAYER.md (§22.4 pre-release) |
| Independence | I built none of this. Every number is read off a screenshot I rendered myself or computed from a constant in the shipped source on this commit. Nothing taken from `PROCESS.md` or `README.md` on trust. |
| Method | 14 real-renderer captures at 480×270 via `PEPEL_SCREENSHOT`; pure-Python WCAG measurement (`/tmp/pngtool.py`, `/tmp/panelmeasure.py`) because PIL is unavailable |

**The same commit was audited three times.** No fix landed between rounds, so the rounds are not a
timeline of progress — they are three different gates applied to one unchanged build. Round 3 scores
lowest because §22.4 asks the hardest questions, not because the build got worse.

Note on commits: DESIGN audited `1f7cca0` and GODOT audited `19eb835`. My build is `979db16`. We did not
all score the identical tree, and §22.6 requires that be recorded rather than smoothed over.

---

## 1. Verdicts and scores side by side

| | Round 1 (§22.2) | Round 2 (§22.3) | Round 3 (§22.4) |
| --- | --- | --- | --- |
| Gate | before mass content | vertical slice | pre-release |
| **Verdict** | **REJECT** | **REJECT** | **REJECT** |
| Полнота требований | 6 | 6 | 5 |
| Корректность систем | 7 | 7 | 7 |
| Игровое качество | 4 | 4 | 4 |
| **UX и читаемость** (вес 25%) | **3** | **3** | **2** |
| Техническая надёжность | 7 | 7 | 7 |
| Weighted mean | 5.2 | 5.3 | 4.8 |
| **Reported player score** | **4.6** | **4.9** | **4.2** |

Scores are held below the weighted mean in every round because the open P1 defects sit in my primary
axis (UX и читаемость, 25% weight), not in the axes that scored well.

**Contribution to the overall score (§22.5):** Player Experience/Art × 0.25 →
`4.6×0.25 = 1.15`, `4.9×0.25 = 1.23`, `4.2×0.25 = 1.05` of the 10-point total, per round.

Round 2 scoring above Round 1 is not an inconsistency: once I had measured the panels rather than
guessed at them, they turned out genuinely sound (opaque, one consistent 1px border, body text
6.0–12.2:1). Round 3 is lowest because §22.4 forces enemy readability and all-zone inspection together.

---

## 2. The one finding that matters most

**The attack telegraph is invisible on every floor in the game.**

`scripts/ai/enemy.gd:6` asserts: *«Every dangerous attack has a visible telegraph before the hitbox opens.»*

The telegraph is a bare `ColorRect` — no border, no outline, no texture — whose rendered colour is the
scene colour **multiplied** by `modulate = Color(1.0, 0.35, 0.25, 0.55)`, with alpha ramping via
`modulate.a = 0.25 + 0.45*t`. Effective alpha is therefore only **0.12–0.42**, and the hue stays inside
the warm family of the ground it is drawn on.

| Enemy | rendered RGB | grass | dirt/peach | stone | dungeon stone |
| --- | --- | --- | --- | --- | --- |
| archer | `RGB(255,54,16)` | 1.13 → 1.36 | 1.11 → 1.33 | 1.09 → 1.22 | 1.02 → 1.02 |
| lumberjack | `RGB(255,25,10)` | 1.19 → 1.58 | 1.16 → 1.50 | 1.15 → 1.37 | 1.08 → 1.11 |
| captain of the guard | `RGB(255,31,16)` | 1.16 → 1.45 | 1.13 → 1.39 | 1.12 → 1.30 | 1.06 → 1.10 |

*(start-of-warning → peak-of-warning, contrast against that floor. Full range: **1.02:1 – 1.58:1**.
WCAG 1.4.11 requires ≥3:1 for a graphic a player needs in order to understand what is happening.)*

It is weakest at the instant it first appears — when the player has most to do with the information.
Spike traps fail identically (`spike_trap.gd:22,37`): idle plate **1.15–1.53:1**, telegraph ramp
**1.06–1.51:1**; only the `active` phase separates, and by then the hitbox is already open.

§24 names this exact risk and its required prevention: *«Избыточный VFX → Игрок не видит угрозы и
телеграфы → читаемая цветовая и форма-кодировка, настройки интенсивности»*. Neither half of that
prevention exists on this commit. §22 forbids me to accept «так задумано» where it contradicts the ТЗ,
and §22.4 lists «нечитабельных телеграфов» as an explicit inspection target.

The fix is roughly five lines: give the warning a hard 1px dark outline, or raise alpha and move the hue
cool. An outline separates at any alpha.

---

## 3. All findings across the three rounds

| ID | Sev | Finding | Evidence (measured) | Status |
| --- | --- | --- | --- | --- |
| CRITIC-P1-01 | P1 | All four zones share one byte-identical floor colour | `RGB(173,188,58)` = 65.2% / 79.35% / 38.9% / **92.05%** of sampled floor in forest/ruins/dungeon/fortress | open |
| CRITIC-P1-02 | P1 | World HUD text legible only by its drop shadow | zone line fill **1.13:1** vs grass, controls line **1.06:1**, gold **1.19:1**; 46.5–70.7% of band pixels <1.5:1; `_make_text` uses a 1px offset shadow, not an outline | open |
| CRITIC-P1-03 | P1 | Resource bars are colour-only | `_hp_label`/`_mp_label` captions overwritten by numbers in `_on_health`/`_on_mana`; XP has no label; HP vs MP **1.18:1**; no plate behind bars; XP bar forced to **3px** vs `BAR_H=7` | open |
| CRITIC-P1-04 | P1 | Anti-aliased OS font on pixel art | `_make_theme()` `SystemFont` Helvetica Neue/Arial/DejaVu, `default_font_size = 8`, upscaled from 480×270; platform-dependent metrics | open |
| CRITIC-P1-09 | P1 | **Attack telegraph invisible on every floor** | **1.02:1 – 1.58:1** across 3 enemies × 4 floors × whole warning ramp; bare ColorRect, no outline; effective alpha 0.12–0.42 | open |
| CRITIC-P1-10 | P1 | Spike traps near-invisible before and during warning | idle plate **1.15–1.53:1**; telegraph ramp **1.06–1.51:1**; only `active` (α0.8) separates, after the hitbox opens | open |
| CRITIC-P1-11 | P1 | No display/accessibility section in settings | `settings_panel.gd:414-421` — exactly two sections, «Управление» and «Звук»; flash hardcoded (`player.gd:593`, `enemy.gd:419`); no font scale; no colourblind mode | open |
| CRITIC-P1-12 | P1 | Settings footer fails even the 3:1 large-text floor | footer lines 3.84 / 3.79 / **2.92:1** body-mean vs `RGB(17,20,21)`; the 2.92 line is «R сброс выбранного · Esc выход и сохранить» | open |
| CRITIC-P1-18 | P1 | Enemies camouflage into their own zone floor | **ENEMY-B 51% of pixels <1.5:1** vs its spawn floor, head **1.03:1**; ENEMY-A body **1.33:1** vs grass; player correctly at **9.47:1**, 7% camouflaged | open |
| CRITIC-P2-05 | P2 | Always-visible control hint omits 2 actions | `hud.gd:362` lists no `pause`/Esc and no `quick_slot_1..4`, though `REBINDABLE` has all 18 and `README.md:111,113` document them | open |
| CRITIC-P2-06 | P2 | Menu rhythm 22px then 11px; panel darker than backdrop | baselines y=116,138,149,160,171; panel `RGB(13,15,20)` on backdrop `RGB(23,25,30)` | open |
| CRITIC-P2-07 | P2 | Zone announced twice | HUD line + centred toast simultaneously in ruins/dungeon/fortress | open |
| CRITIC-P2-08 | P2 | Dungeon zone name truncated | renders **«Зона: Подземелье под руин…»**; `data/zones.json` name is 22 chars vs `BAR_W+20`=112px; code comment asserts a fit the render falsifies | open |
| CRITIC-P2-13 | P2 | No shared panel size grid; inventory off-centre | interiors 148→272px wide; inventory cx **−6.0px**, all others 0.0; bottom margins 27px/31px crowding the y≈248 controls band | open |
| CRITIC-P2-14 | P2 | Map interior text fails | worst band **3.92:1** vs `RGB(19,22,22)`; every other panel clears 4.5:1 | open |
| CRITIC-P2-15 | P2 | Rarity is colour-only in the item list | pairwise luminance **1.01–1.90:1**; `common` vs `legendary` **1.01:1** (identical luminance); `RARITY_LABELS_RU` text exists but only for the selected row | open |
| CRITIC-P2-19 | P2 | No size hierarchy between player and enemies | player **14×15**, enemies **14×14**; shared rounded-blob silhouette; `enemy.gd:95-98` relies on tint alone | open |
| CRITIC-P2-20 | P2 | HUD floats on the world with no plate, all zones | `x140,y0..32` is pure grass; zone label vs floors 1.19/1.05/1.73/2.96:1 — clears 3:1 only in the dungeon, by accident | open |
| CRITIC-P2-21 | P2 | Duplicate + truncated zone announcement | P2-07 and P2-08 combined, re-confirmed at the pre-release gate | open |
| CRITIC-P2-22 | P2 | No accessibility surface (P1-11 at the release gate) | §23 stage 8 lists accessibility as a deliverable; §24 mandates «настройки интенсивности» | open |
| CRITIC-P3-16 | P3 | Panel backgrounds not unified | `RGB(20,23,24)` / `RGB(17,20,21)` / `RGB(19,22,22)` where one constant was intended | accepted |
| CRITIC-P3-17 | P3 | save/load not rebindable | `save_game`/`load_game` absent from `REBINDABLE`; F5/F9 fixed; `README.md:112` documents honestly | accepted |

### What I checked and found clean

Reporting the passes matters as much as the failures, and these are all measured, not assumed:

- **Panel body text passes everywhere** — 6.0–12.2:1 (worst craft 6.01, inventory 6.24, character 8.65,
  shop 8.74, skills 7.82). The panel system works; only its geometry is inconsistent.
- **Panels are effectively opaque** — zero pure-world-colour pixels inside any interior. No bleed-through.
- **One consistent panel chrome** — `_panel_style()` gives every panel the same 1px border
  `Color(0.32,0.34,0.38,0.9)` and radius 2.
- **Menu title and items pass** — 14.29:1 and 11.9–13.3:1 core.
- **All five rarity tiers clear 4.5:1 against the panel** (6.46–12.28:1) — the problem is tier-vs-tier
  separation, not visibility.
- **No camera shake anywhere** — `grep -rn "shake" scripts/` → 0 matches. This genuinely lowers
  photosensitivity exposure.
- **No tilemap holes, no stray sprites, no layer intersections** in any of the four zone frames.
- **The player sprite is correctly high-contrast** — 9.47:1 dark body, white visor, 7% camouflaged. The
  readability rule was understood; it was applied to only one actor.
- **The README controls table is complete** — `README.md:95-115` documents all 18 rebindable actions
  including quick slots and Esc.
- **14/14 probes rendered `err=0 size=(480, 270)`** with no crash and no missing-resource error in any log.

---

## 4. Corrections — three things I initially misread and disproved myself

Recorded so nobody re-reports them from a stale note:

1. **"Garbled text" in the skills and craft panels is correct Russian.** Upscaled crops read cleanly:
   skills «Летающий сгусток огня. Поджигает цель.» / «Дальность 260»; craft «Клык пепельного волка 3/4».
   Skills footer is «↑↓ выбор · E выбрать · L выучить · Esc закрыть».
2. **The settings panel is not clipped.** The last footer line is inside the panel (bottom y≈238); the
   world controls band is below at y≈248+. The defect there is colour (P1-12), not geometry.
3. **Panels are not translucent.** No world colour bleeds through any interior.

---

## 5. Release blockers

§22.4: *«Релиз запрещён при любом открытом P0 или P1.»* **Nine open P1** on `979db16`:
P1-01, P1-02, P1-03, P1-04, P1-09, P1-10, P1-11, P1-12, P1-18.

**This is a readability rejection, not a stability rejection.** The build boots, every screen renders, the
panels are well made, the manual is complete, there is no camera shake, no tilemap holes and no stray
sprites. What fails is narrower and more fundamental: a player cannot reliably see the things they must
react to. Reading §22.1's own question — *«Понятно ли игроку, что произошло? Выделяются ли враги?»* —
the answer for enemies and attacks is no, and it is no by a factor of two to three against a threshold
that exists precisely for this case.

### Conditions to close, cheapest first

| # | Close | Change | Acceptance test |
| --- | --- | --- | --- |
| 1 | **P1-09 + P1-10** | outlined, higher-alpha, cool-hued warning shapes (one change, two files) | telegraph **≥3:1 at the first warning frame** on all four floors, all enemy types |
| 2 | **P1-18** | enemy outline + hue outside each spawn zone's floor family | ≥90% of sprite pixels ≥3:1 vs the floor of every zone it spawns in |
| 3 | **P1-02 + P1-03 + P2-20** | one dark plate behind the HUD (reuse `_panel_style()`), restore HP/MP/XP captions, XP bar ≥5px | every HUD string ≥4.5:1 against the real floor pixels, all four zones |
| 4 | **P1-01** | distinct floor hue **and luminance band** per zone | no single RGB value >20% share in any zone sample; pairwise floor contrast ≥1.5:1 |
| 5 | **P1-11 + P1-12** | «Экран» settings section (flash intensity, font scale); footer ≥4.5:1 | minimum flash intensity cuts the measured flash delta ≥90%; no string <4.5:1 |
| 6 | **P1-04** | ship a pixel font as the theme default, keep SystemFont as fallback | no `SystemFont` default assignment; identical glyph metrics on two platforms |

Items 1–3 change how the game plays. Items 4–6 are palette and configuration decisions that should be
made **before** more zones are authored — P1-01 multiplies with every zone added on the current palette,
which is exactly the §22.2 gate.

---

## 6. Unverified assumptions (limits, not passes)

- **Animation smoothness, clipped animations, VFX density, particle budget** — not judgeable from stills.
  §22.4 asks about «обрезанных анимаций» and I have **no verdict** on that row.
- **Telegraph and trap figures are computed blends, not frozen-frame pixels.** Inputs are measured
  (floor colours sampled from real frames; colours and alphas read from shipped `.tscn`/`.gd`); only the
  compositing is arithmetic. A frame-accurate capture should close P1-09.
- **The `[E]` interact prompt** (`hud.gd:1473`) never rendered in any probe — no NPC in range. Present in
  code, unseen by me in all three rounds.
- **`journal` and `dialogue` interiors** — my panel detector failed to bound them; read visually only, no
  contrast figures claimed.
- **Long-session stability, soak, temporal layering** — outside my capture method; GODOT's territory.
- **All ratios are from the native 480×270 buffer.** The player sees an upscaled image, so my numbers are
  the optimistic case; upscaling softens text further.

---

## 7. Conflicts with other critics

None. My findings are measured contrast ratios on self-rendered frames plus arithmetic on shipped
constants; they do not overlap DESIGN's loop/economy analysis or GODOT's architecture review.

One foreseeable disagreement, recorded now per §22.6: if P1-09 is closed on the grounds that the
telegraph code path executes correctly, that is not a contradiction to average. The code running and the
warning being visible are different claims. §24 already settles it in favour of visibility.

Commit divergence is a real difference between my report and the other two: I scored `979db16`, DESIGN
scored `1f7cca0`, GODOT scored `19eb835`. Any cross-critic roll-up should note that.

---

## 8. How to reproduce my evidence

```bash
# 1. Render the fourteen screens with the real renderer (never --headless)
for p in menu world ruins dungeon fortress inventory character skills journal map shop craft dialogue settings; do
  PEPEL_SCREENSHOT=/tmp/cp_$p.png godot --path . > /tmp/log_$p.txt 2>&1
done

# 2. Measure: WCAG luminance/contrast, text-vs-background clustering, panel bounding boxes
python3 /tmp/pngtool.py contrast <r,g,b> <r,g,b>
python3 /tmp/panelmeasure.py            # writes /tmp/panels.json

# 3. Zoom a region for visual reading (nearest-neighbour, no resampling blur)
python3 /tmp/pngtool.py crop /tmp/cp_world.png 100 100 140 130 6 /tmp/x_world_ents.png
```

PIL is not installed on this host, which is why `/tmp/pngtool.py` decodes PNG directly. Both scripts are
reusable as-is: re-running them after a fix re-measures the whole matrix with no new tooling. Per §22.6,
closure must be confirmed by an independent critic re-viewing these frames, not self-certified.

---

## 9. Final recommendation

**REJECT in all three rounds. Do not release, and do not author more zones yet.**

Close conditions 1–3 first — an outlined warning shape, an enemy outline, and a HUD plate. Those three
changes address the defects that make the game feel unfair, and they are small. Then decide the per-zone
palette and the font, because both are cheap now and expensive after content exists.

I would raise the player score above 7 on the strength of items 1–3 alone. The underlying build is
sound: fourteen screens render cleanly, the panel system is consistent and its text passes, the manual is
complete, and the player sprite proves the team already knows the contrast rule. What is missing is
applying that same rule to everything the player has to react to.
