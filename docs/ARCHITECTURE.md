# Архитектура

## Поток данных

```
InputSource ──> Player / HUD
                   │
                   ├─> DamageResolver ──> HealthComponent / GameState
                   │                          │
                   │                          └─> EventBus (сигналы)
                   │                                   │
                   └─> Telemetry <─────────────────────┘
                          │
                          └─> user://debug_runs/<run_id>/
```

`EventBus` — единственный канал оповещения. Никто не держит прямых ссылок на
HUD, кроме сцены `main.tscn`.

## Autoload

| Имя | Файл | Ответственность |
| --- | --- | --- |
| `Telemetry` | `scripts/core/telemetry.gd` | Логи прогона, перехват ошибок движка |
| `EventBus` | `scripts/core/event_bus.gd` | Сигналы между системами |
| `GameState` | `scripts/core/game_state.gd` | HP/мана/XP/золото/инвентарь/флаги |
| `QuestManager` | `scripts/quests/quest_manager.gd` | Состояния квестов, выдача награды |
| `SaveManager` | `scripts/save/save_manager.gd` | Слоты, атомарная запись, миграции |
| `InputBindings` | `scripts/core/input_bindings.gd` | Переназначение клавиш, `user://settings/controls.json` |

Autoload'ов ровно шесть: всё остальное — сцены и компоненты.

## Ввод

`InputSource` (`scripts/core/input_source.gd`) — статический фасад. Человек
читает `Input`, бот подменяет источник через `InputSource.set_override()`.
И игрок, и HUD опрашивают только `InputSource`, поэтому у бота нет
привилегированного доступа: он не может вызвать `queue_free` у врага или
прочитать его HP.

Экран «Настройки управления» (`scripts/ui/settings_panel.gd`, открывается из
паузы) читает сырые `InputEvent` — иначе перехватить произвольную клавишу
нельзя. Бот сырые события не порождает, поэтому переназначение для него
недостижимо, а правки `InputMap` на его прогоны не влияют. Назначения пишет
`InputBindings` в `user://settings/controls.json` — отдельно от слотов
сохранения (ТЗ §18).

## Бой

`DamageResolver.resolve_hit(attacker, target, payload)`:

1. отбрасывает повторный `hit_id` для той же цели;
2. считает крит, вычитает `get_defense()` цели;
3. вызывает `receive_damage()` у цели;
4. пишет событие в `combat.jsonl`.

Удар игрока: `WINDUP 0.08 → ACTIVE 0.10 → RECOVERY 0.16`. Хитбокс открывается
только в ACTIVE, `hit_id` создаётся один раз на замах.

## Враги

`Enemy` (`scripts/ai/enemy.gd`) — явная FSM с таймером состояния. Телеграф —
`ColorRect`, который проявляется во время WINDUP; хитбокс открывается после.
Дальний враг стреляет снарядом (`Projectile`), урон всё равно идёт через
`DamageResolver`.

## Мир

`Forest` (`scripts/world/forest.gd`) собирает карту из детерминированного сида:
`TileSet` создаётся в рантайме, у камня и дерева есть коллизия. Спавны описаны
в одном месте, координаты в тайлах.

## Сохранения

```
user://saves/slot_N.tmp     запись
       ↓ проверка размера и парсинг
user://saves/slot_N.bak     предыдущий хороший слот
user://saves/slot_N.json    актуальный слот
```

`_migrate()` поднимает старые схемы; более новая схема не затирается, а
отклоняется с понятной ошибкой.

## Логи

`user://debug_runs/<run_id>/`

| Файл | Содержимое |
| --- | --- |
| `run_meta.json` | версия движка, платформа, время старта |
| `events.jsonl` | все игровые события |
| `combat.jsonl` | попадания, урон, `hit_id` |
| `decisions.jsonl` | решения бота и обходы препятствий |
| `errors.log` | ошибки движка через `OS.add_logger` |
| `summary.md` | итог прогона |

## Границы

Срез сознательно не содержит: сети, мультиплеера, боссов, нескольких зон,
локализации, экспортных пресетов. Это не «сделано молча» — см. README.
