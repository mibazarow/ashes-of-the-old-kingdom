# CRITIC-PLAYER — ROUND 2 (§22.3 аудит вертикального среза)

```text
CRITIC REPORT
Round: 2
Role: PLAYER (UX и арт-директор, spec §22.1)
Build / commit / run_id: 979db16 / PEPL-PLAYER-R2-2026-11-23
Score: 4.9/10     Verdict: REJECT
```

| Field | Value |
| --- | --- |
| Gate | §22.3 — vertical slice |
| Engine | Godot `4.7.2.stable.official.ed1daf0bf` |
| My scope this round | управление; **читаемость атак**; UI экранов; поведение врагов как вопрос читаемости |
| Independence | Same 14 self-rendered 480x270 frames as Round 1, same `/tmp/pngtool.py` measurements, plus source constants read on `979db16`. No fix landed between my rounds — this is the same build under a harder gate, so a lower score means a harder question, not a regression. |

§22.3 lists «читаемость атак» as a checked item. That is the headline of this round.

---

## 1. CRITIC-P1-09 | Severity: **P1** — the attack telegraph is invisible on every floor

This is the most serious finding of my entire audit, and the build asserts the opposite of it in a comment.

`scripts/ai/enemy.gd:6`:
> `## Every dangerous attack has a visible telegraph before the hitbox opens.`

It is not visible. The telegraph is a **bare `ColorRect` with no border, no outline and no texture**, and
its rendered colour is the scene colour *multiplied* by a `modulate`, which pushes it further into the
same warm family as the ground it is drawn on.

Source of truth:

```gdscript
# scenes/enemies/archer.tscn:48        color = Color(1, 0.6, 0.25, 0.5)   18x18 px
# scenes/enemies/lumberjack.tscn:49    color = Color(1, 0.28, 0.15, 0.6)  22x22 px
# scenes/enemies/captain_of_the_guard.tscn:52  color = Color(1, 0.35, 0.25, 0.5)  26x26 px
# scripts/ai/enemy.gd:897              telegraph.modulate = Color(1.0, 0.35, 0.25, 0.55)
# scripts/ai/enemy.gd:918              telegraph.modulate.a = 0.25 + 0.45 * t
```

Effective alpha is `tscn.a × modulate.a`, so the warning ramps from **0.12 to 0.35** (archer, captain) and
**0.15 to 0.42** (lumberjack). Blending those over the four measured floor colours:

| Enemy | rendered RGB | floor | start of warning | peak of warning |
| --- | --- | --- | --- | --- |
| archer | `RGB(255,54,16)` | grass | **1.13:1** | **1.36:1** |
| archer | | dirt/peach | **1.11:1** | **1.33:1** |
| archer | | stone | **1.09:1** | **1.22:1** |
| archer | | dungeon stone | **1.02:1** | **1.02:1** |
| lumberjack | `RGB(255,25,10)` | grass | **1.19:1** | **1.58:1** |
| lumberjack | | dirt/peach | **1.16:1** | **1.50:1** |
| lumberjack | | stone | **1.15:1** | **1.37:1** |
| captain | `RGB(255,31,16)` | grass | **1.16:1** | **1.45:1** |
| captain | | dungeon stone | **1.06:1** | **1.10:1** |

**Full range across all three enemies, all four floors, and the entire warning ramp: 1.02:1 – 1.58:1.**
WCAG 1.4.11 requires **≥3:1** for a non-text graphic a player needs in order to understand what is
happening. The telegraph misses by a factor of two to three, and it is *weakest at the moment it first
appears* — exactly when the player has the most to do with the information.

The root cause is the same one as CRITIC-P1-01: a translucent warm red laid over a warm orange-yellow
floor. Warm-on-warm at 12–42% alpha is arithmetically incapable of separating.

**Expected:** the player sees the swing coming and moves. §24 lists this as a named risk:
*«AI врага читерит → Нечестный бой … Профилактика: Телеграфы … независимая проверка критиком».*
I am that independent check, and I report it as failing.
**Actual:** the warning is the same colour as the ground. Combat resolves to reaction to the sprite
itself rather than to the warning, which removes the entire defensive layer of the design.
**Risk / impact:** this is not an aesthetic preference and §22 forbids me to let it be excused as
«так задумано» where it contradicts the ТЗ. It makes the combat unfair-feeling in a way no balance pass
can repair, because the information the player is being punished for missing is not on screen.
**Recommended fix (any one, cheapest first):**
1. Give the telegraph a hard **1px dark outline** (`draw_rect` on a `_draw()`, or a second larger dark
   ColorRect behind it). An outline separates at any alpha and is ~5 lines of code.
2. Raise effective alpha to ≥0.7 and shift the hue **cool** (magenta/cyan) so it leaves the floor's family.
3. Draw the actual hitbox footprint as an outlined shape instead of a filled wash.
**Acceptance test after fix:** measured telegraph-vs-floor contrast **≥3:1 at the first frame of the
warning**, on all four zone floors, for all enemy types. Same script, same regions.

The same defect class covers traps — see CRITIC-P1-10.

## 2. CRITIC-P1-10 | Severity: **P1** — spike traps are near-invisible before and during their warning

**Evidence:** `scripts/world/spike_trap.gd`:

```gdscript
line 22  visual.color = Color(0.45, 0.3, 0.2, 0.35)          # idle plate — "here is a trap"
line 37  visual.color = Color(1.0, 0.35, 0.2, 0.25 + 0.5 * t) # telegraph
line 42  visual.color = Color(1.0, 0.2, 0.15, 0.8)            # active
```

| Phase | floor | contrast |
| --- | --- | --- |
| idle plate | grass | **1.49:1** |
| idle plate | dirt/peach | **1.53:1** |
| idle plate | stone | **1.35:1** |
| idle plate | dungeon stone | **1.15:1** |
| telegraph (whole ramp) | all four floors | **1.06:1 – 1.51:1** |

The idle plate is how a player is supposed to see the hazard *before* it arms. At 1.15–1.53:1 it is
effectively a slightly different shade of ground. The warning phase then fails the same way the enemy
telegraph does. Only the `active` phase at alpha 0.8 separates — and by then the hitbox is open, so the
information arrives after the damage.

**Expected:** §22.4 names «нечитабельных телеграфов» as an explicit visual-inspection target.
**Actual:** a hazard you cannot see until it has already hit you.
**Recommended fix:** same outline treatment as CRITIC-P1-09, plus a distinct idle marker (a metal-grey
plate rather than a brown wash, so it reads as manufactured against organic ground).
**Acceptance test after fix:** idle plate ≥3:1 against all four floors; telegraph ≥3:1 at first frame.

## 3. CRITIC-P1-11 | Severity: **P1** — the settings screen has no display or accessibility section

**Evidence:** `/tmp/cp_settings.png` + `scripts/ui/settings_panel.gd:414-421`. The screen has exactly two
sections, and the code confirms there are only two:

```gdscript
_controls_header.text = "  Управление" if _sound_open else "> Управление"
_sound_header.text    = "> Звук" if _sound_open else "  Звук"
```

There is no display section, no window/resolution control, no VFX-intensity or reduced-flash control, no
font scale, no colourblind option. The remap list itself is good — `REBINDABLE` covers 18 actions
including `pause` and `quick_slot_1..4`, and `R` resets the selected binding.

This matters specifically because of the hit flash. `scripts/player/player.gd:593-594`:
`_flash_timer = 0.12; modulate = Color(1.0, 0.45, 0.45)` and `scripts/ai/enemy.gd:419-423`:
`_flash_timer = 0.1; sprite.modulate = sprite_tint * Color(1.6, 1.2, 1.2)`. Both durations and both
colours are hardcoded with no user-facing reduction. In a crowded fight hits land several times per
second, and a photosensitive player has no way to turn that down. §24 requires exactly this mitigation:
*«Избыточный VFX → Игрок не видит угрозы и телеграфы → настройки интенсивности».*

Mitigating fact I want on record: I found **no camera shake anywhere in `scripts/`** (`grep -rn "shake" scripts/`
→ 0 matches). That genuinely lowers the photosensitivity risk and I am crediting it.

**Expected:** §22.1 gives me «доступность» as core scope; §23 stage 8 lists accessibility as a deliverable.
**Actual:** accessibility is limited to key remapping.
**Recommended fix:** add a third section «Экран» with at minimum a flash-intensity slider (a multiplier on
the two hardcoded flash colours is enough) and a font-scale setting.
**Acceptance test after fix:** with flash intensity at minimum, the measured player hit-flash delta is
≤10% of the current value; font scale at maximum raises `default_font_size` and no panel clips.

## 4. CRITIC-P1-12 | Severity: **P1** — the settings footer text fails even the 3:1 large-text floor

**Evidence:** `/tmp/x_settings_bottom.png`, background `RGB(17,20,21)`.

| Footer line | core | body-mean | verdict |
| --- | --- | --- | --- |
| line 1 | 5.28:1 | **3.84:1** | fails 4.5 |
| line 2 | 4.81:1 | **3.79:1** | fails 4.5 |
| «R сброс выбранного · Esc выход и сохранить» | **2.92:1** | **2.92:1** | **fails 3:1** |

2.92:1 is below the floor for *large* text, and this is 8px text. It is also the line that tells the
player how to leave the screen and how to undo a rebinding — the two things a stuck player most needs.

I checked whether the panel is merely clipped and it is **not**: the last footer line is inside the panel
(panel bottom y≈238) and is fully drawn. The problem is colour, not geometry.

Adjacent, same section: the **unselected** header «Звук» measures 4.48:1 core / **3.74:1** body-mean,
while the selected «Управление» measures 9.20:1 / 6.05:1. The selected/unselected pair is 1.6:1 apart, so
the only cue for "which section am I in" is a dimming that pushes the inactive one under 4.5:1.
**Recommended fix:** raise footer text to ≥4.5:1 and use a non-colour selection cue (the `>` glyph is
already there — lean on it and keep both headers at readable luminance).
**Acceptance test after fix:** every string on the settings screen ≥4.5:1 body-mean; inactive header
≥4.5:1.

## 5. CRITIC-P2-13 | Severity: **P2** — panels have no shared size grid; inventory is off-centre

**Evidence:** `/tmp/panels.json`, panel interior extents measured from the rendered frames.

| Panel | interior W×H | centre offset |
| --- | --- | --- |
| Кузнечный горн | 148 × 111 | 0.0 / 0.0 |
| Инвентарь | 166 × 131 | **−6.0 / 0.0** |
| Карта | 207 × 127 | 0.0 / 0.0 |
| Лавка | 224 × 120 | 0.0 / 0.0 |
| Настройки | 222 × 208 | 0.0 / 0.0 |
| Персонаж | 255 × 105 | 0.0 / 0.0 |
| Навыки | 272 × 215 | 0.0 / 0.0 |

Inventory is the only panel that is not horizontally centred, and it is off by 6px on a 480px-wide screen
— 1.25% of the width, visible as a lean against the otherwise-centred set. Interior widths span
**148→272px**, nearly 2×, with no shared padding step, so opening I → C → K → M resizes the frame every
time. Bottom margins also differ: skills leaves 27px, settings 31px, and the world controls band sits at
y≈248+, so both panels crowd the same strip.

**Good news, stated plainly:** panel *body* text passes everywhere — 6.0–12.2:1 (worst craft 6.01,
inventory 6.24, character 8.65, shop 8.74, skills 7.82). Panels are effectively **opaque** (zero
pure-world pixels inside any interior), and `_panel_style()` gives all of them the same 1px border
`Color(0.32,0.34,0.38,0.9)` and radius 2. The panel system is sound; only its geometry is inconsistent.
**Recommended fix:** one panel width (or two: narrow/wide) and one padding constant; centre inventory.
**Acceptance test after fix:** all panel interiors share a width from a fixed set; inventory cx offset ≤1px.

## 6. CRITIC-P2-14 | Severity: **P2** — the map interior is the one panel whose text fails

**Evidence:** `/tmp/x_map_zoom.png`, interior background `RGB(19,22,22)`; worst text band **3.92:1**.
Every other panel's body text clears 4.5:1; the map does not, because fog and marker colours sit inside
the same luminance band as the labels.
**Recommended fix:** raise label luminance or darken the fog fill; the fog is currently too close to the
text colour.
**Acceptance test after fix:** map interior text ≥4.5:1 body-mean in a live capture.

## 7. CRITIC-P2-15 | Severity: **P2** — in the item list, rarity is carried by colour alone

**Evidence:** `scripts/inventory/item_db.gd:19-25` and `hud.gd:951-954, 979`.

| Tier | rendered RGB | vs panel bg | vs common | vs legendary |
| --- | --- | --- | --- | --- |
| common | `RGB(209,214,204)` | 12.19:1 | — | **1.01:1** |
| uncommon | `RGB(117,219,107)` | 10.38:1 | 1.17:1 | **1.18:1** |
| rare | `RGB(107,168,250)` | 7.38:1 | 1.65:1 | 1.66:1 |
| epic | `RGB(189,128,242)` | 6.46:1 | 1.89:1 | 1.90:1 |
| legendary | `RGB(250,209,82)` | 12.28:1 | **1.01:1** | — |

All five tiers clear 4.5:1 against the panel, so none of them is hard to *see*. The problem is
**separation between tiers**: pairwise luminance contrast is 1.01–1.90:1, and `common` vs `legendary` is
**1.01:1 — identical luminance, differing only in hue**. To a red-green colourblind player, scanning the
list for "which of these is the rare one" is not possible by luminance.

I want to be precise about the mitigation, because the code deliberately built one: `RARITY_LABELS_RU`
renders «обычное / необычное / редкое / эпическое / легендарное», and the comment on it states the intent
that colour never stands in for a description. That text **does exist** — but only in the single
selected-row detail line. The list rows themselves are colour-coded with no glyph.
**Recommended fix:** prefix each row with a one-character tier marker (◆/●/▲) or a short tag, so tier
survives without hue. The label infrastructure is already there.
**Acceptance test after fix:** tier is identifiable in a greyscale screenshot of the inventory list.

## 8. CRITIC-P3-16 | Severity: **P3** — panel background colours are not unified

inventory/character/skills/shop/craft `RGB(20,23,24)`, settings `RGB(17,20,21)`, map `RGB(19,22,22)`.
Three values where one was intended. Not visible side by side because panels never overlap, but it means
`_panel_style()` is being called with per-screen colours rather than one constant. Cosmetic.

## 9. CRITIC-P3-17 | Severity: **P3** — save/load are not rebindable

`save_game`/`load_game` exist in `project.godot` but are absent from `REBINDABLE`, so F5/F9 are fixed.
`README.md:112` documents them honestly. Only a problem on layouts where F5/F9 are taken by the OS.

---

## 10. Scores (§22.5, CRITIC-PLAYER weights)

| Критерий | Вес | Балл | Обоснование |
| --- | --- | --- | --- |
| Полнота требований | 15% | 6 | All slice screens exist and work; accessibility section absent (§23 stage 8). |
| Корректность систем | 20% | 7 | Every panel opened and closed cleanly in its probe; no stuck modal observed. |
| Игровое качество | 20% | 4 | Combat readability is the slice's core and it fails (P1-09). |
| **UX и читаемость** | **25%** | **3** | Telegraph 1.02–1.58:1, traps 1.06–1.51:1, footer 2.92:1. |
| Техническая надёжность | 20% | 7 | Panel system is consistent in style and opaque; geometry is the only flaw. |
| Weighted mean | | **5.3** | |
| **Reported player score** | | **4.9** | Held below the mean for three P1 in my primary axis. |

## 11. Verdict: **REJECT**

§22.3: *«Повторная оценка проводится после исправления P0/P1. Только после их закрытия разрешается
контентное расширение.»* Open P1 from this round: **P1-09** (telegraph), **P1-10** (traps),
**P1-11** (no accessibility section), **P1-12** (footer contrast) — plus P1-01…P1-04 still open from
Round 1 on the same commit.

Conditions to close are listed with acceptance tests above. P1-09 and P1-10 share one fix (outlined
warning shapes) and are the cheapest high-impact changes in the build.

## 12. Unverified assumptions

- The telegraph and trap figures are **computed blends from shipped constants**, not pixels sampled from
  a frozen warning frame. I could not guarantee capturing the 0.12–0.42s warning window in a still. The
  arithmetic is `scene colour × modulate`, alpha-blended over floor colours I measured from real frames,
  so the inputs are measured and only the compositing is calculated. A frame-accurate capture would
  confirm, and I recommend whoever fixes P1-09 produce one.
- I did not observe an enemy attacking, dying, or a player taking damage in any captured frame. Enemy
  *behaviour* is DESIGN/GODOT territory; I report only whether the warning is visible.
- The `[E]` interact prompt never rendered in a probe (no NPC in range). Still unverified in Round 2.
- `journal` and `dialogue` interiors were read visually only; my panel detector did not bound them.

## 13. Conflicts with other critics

None found. If GODOT's report treats the telegraph as correct because the code path runs, that is not a
contradiction with me: a warning that executes at 1.02:1 against the ground is simultaneously "working"
as code and "not visible" as UX. §22.6 would route that to the technical lead, and my position is that
§24 already settles it in favour of the readability requirement.

## 14. Release blockers

CRITIC-P1-09, CRITIC-P1-10, CRITIC-P1-11, CRITIC-P1-12 (+ Round 1 P1-01…P1-04).

## 15. Final recommendation

Fix P1-09 and P1-10 together as one change — outlined, higher-alpha, cool-hued warning shapes — and
re-measure. That single change removes the worst defect in the build for a few lines in two files.
