# Пепел старого королевства — вертикальный срез

2D Action RPG, Godot 4.7.2, GDScript. Это **вертикальный срез** по ТЗ
`Pepl_staryogo_korolevstva_TZ_RPG_Godot_v2.md`: работающее ядро (движение, бой,
враги, квест, инвентарь, сохранения, логи, отладочный бот), а не полная игра.

## Запуск

```bash
# редактор
open /Applications/Godot.app --args --path /Users/mb/Downloads

# игра из терминала
godot --path /Users/mb/Downloads
```

Godot 4.7.2 уже установлен (`/Applications/Godot.app`, CLI `godot`).

## Управление

| Действие | Клавиша |
| --- | --- |
| Движение | W A S D / стрелки |
| Атака | ЛКМ, J, геймпад X |
| Рывок (неуязвимость) | Space, Shift |
| Взаимодействие, закрыть диалог | E |
| Инвентарь | I |
| Быстрый слот: настой здоровья / маны | 1 / 2 |
| Сохранить / загрузить слот 1 | F5 / F9 |
| Пауза | Esc |

Цель среза: поговорить с Эдриком (метка `!`), взять задание, убить трёх
пепельных волков у опушки, вернуться и сдать. Награда выдаётся ровно один раз.

## Что реализовано

- **Игрок** — `CharacterBody2D`, 8 направлений с нормализованной диагональю,
  атака с wind-up / active / recovery, рывок с i-frames, hit-stop, вспышка и
  цифры урона, смерть и возрождение.
- **Бой** — единый `DamageResolver`: `hit_id` не даёт одному удару ударить
  дважды, защита вычитается в одном месте, каждое попадание пишется в лог.
- **Враги** — два типа (ближний волк, дальний культист) с FSM
  IDLE → PATROL → INVESTIGATE → CHASE → ATTACK → STAGGER → DEAD, leash range,
  потеря цели, телеграф перед ударом, труп не атакует и не даёт лут дважды.
- **Мир** — `TileMapLayer` с процедурно собранным `TileSet` (коллизии у камня и
  деревьев), детерминированный сид, дорога, поляна, сундук, ловушка с
  предупреждением, подбираемый предмет.
- **Квест** — `QuestManager` на данных из `data/quests.json`, прогресс по
  событиям, сдача ровно один раз.
- **Инвентарь** — стеки, экипировка (оружие/броня), расходники на быстрых
  слотах, HUD с HP/MP/XP/золотом/трекером задания.
- **Сохранения** — 3 слота, запись `tmp → проверка → bak → rename`,
  версия схемы и миграция, битый слот не роняет игру.
- **Логи** — `user://debug_runs/<run_id>/`: `events.jsonl`, `combat.jsonl`,
  `decisions.jsonl`, `errors.log`, `run_meta.json`, `summary.md`. Ошибки движка
  попадают в `errors.log` через `OS.add_logger`.
- **Отладочный бот** — 6 сценариев, управляет игроком через тот же
  `InputSource`, что и человек; не телепортируется и не читает скрытое
  состояние. Умеет обходить препятствия и пишет свои решения в лог.

## Проверки

```bash
# тесты (exit code 1 при провале)
godot --headless --path . --script res://tests/test_core.gd

# боты
godot --headless --path . -- --bot=BOT-001   # дойти до NPC и взять квест
godot --headless --path . -- --bot=BOT-002   # полный цикл квеста
godot --headless --path . -- --bot=BOT-008   # убить врага
godot --headless --path . -- --bot=BOT-009   # save/load
godot --headless --path . -- --bot=BOT-010   # soak с движением по карте
godot --headless --path . -- --bot=BOT-011   # игрок получает урон

# профили поведения: cautious | normal | aggressive | explorer
godot --headless --path . -- --bot=BOT-002 --profile=cautious

# скриншот без ручного запуска
PEPEL_SCREENSHOT=/tmp/shot.png godot --path .
```

Актуальные результаты прогонов: `docs/TEST_REPORT.md`.

## Структура

```
scenes/     main, world, player, enemies, npcs, interactables, items, ui
scripts/    core, save, player, combat, ai, npc, quests, inventory, world, ui, debug_bot
data/       items.json, quests.json
assets/     сгенерированные 16x16 спрайты (см. docs/TODO_TEMP_ASSETS.md)
tests/      test_core.gd
tools/      генератор спрайтов, генератор InputMap
docs/       ARCHITECTURE.md, TEST_REPORT.md, ASSET_CREDITS.md, TODO_TEMP_ASSETS.md
```

## Ограничения этого среза

Одна зона, два типа врагов, один квест, один NPC. Полное ТЗ требует 5 зон,
18+ врагов, 4 боссов, 9 NPC, 12–16 квестов — это следующий объём работы, а не
скрытая часть текущего. Графика — сгенерированные заглушки, не финальный арт.
