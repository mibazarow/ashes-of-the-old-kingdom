# Сборка под macOS (только arm64)

Дата: 2026-11-20. Движок: Godot `4.7.2.stable.official.ed1daf0bf`, macOS на
Apple Silicon (arm64). Версия сборки: **001**.

## Статус

Сборка **выполнена и проверена запуском**. Готовый artifact:

```
build/macos/Pepl-macos-arm64.zip   (~28 МБ, внутри «Пепел старого королевства.app»)
```

Проверено реально (не на слово):

- `lipo -archs` по бинарнику внутри `.app` → `arm64` (чистый arm64, не universal,
  не x86_64);
- запуск бинарника из собранного `.pck` → код возврата `0`, баннер Godot и
  `OpenGL API 4.1 Metal ... Apple M5 Pro`, без `ERROR`/`SCRIPT ERROR`;
- кадр из собранной сборки: `[screenshot] saved=... err=0 size=(480, 270)` —
  значит упакованный `.pck` грузит главную сцену и рендерит;
- тесты `res://tests/test_core.gd` на коммите сборки → `checks: 1832  failures: 0`
  (53 группы); на текущем HEAD — `checks: 3470  failures: 0` (65 групп);
- чистый прогон `--quit-after 120` → `0` строк `ERROR|SCRIPT ERROR`.

> **Артефакт 001 устарел и перед раздачей обязан быть пересобран.** Тег
> `v001` указывает на `45e9902` (2026-11-20) — это коммит сборки, а не текущий
> `main`. От него до HEAD **35 коммитов**: четыре зоны вместо двух, 18 типов
> врагов и 5 боссов, 9 NPC и 12 квестов, финальный босс с тремя концовками,
> нить Паломника, музыка, главное меню и экран навыков, доступность. Тестов на
> нём было 1832 против 3470 сейчас. Лежащий в `build/macos/` zip — это игра
> состояния 2026-11-20, а не то, что сейчас в репозитории. Пересобрать по
> шагам ниже с текущего HEAD и только потом раздавать.

## Что нужно установить

Godot **4.7.2.stable** и шаблоны экспорта **ровно той же версии** — каталог
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/` с файлом
`macos.zip`. Версии шаблонов и редактора обязаны совпадать.

## Почему только arm64

Решение владельца: собирать **только arm64**. Universal (x86_64 + arm64) не
делаем, целевой Windows/x86 на этой машине не проверяем. Целевая машина —
Apple Silicon.

## Важный нюанс про шаблон macOS и как получается arm64

Официальный шаблон Godot 4.7.2 для macOS кладётся **одним universal-бинарником**
`macos_template.app/Contents/MacOS/godot_macos_release.universal` (внутри срезы
`x86_64` и `arm64`). Отдельного файла `godot_macos_release.arm64` в архиве
шаблонов **нет**. Экспортчик macOS подбирает файл шаблона по значению
`binary_format/architecture` пресета, поэтому:

- `architecture="arm64"` → Godot ищет `godot_macos_release.arm64` и падает
  («бинарный файл шаблона не найден»);
- `architecture="Universal"` (с большой буквы) → невалидное значение
  («Invalid architecture»);
- `architecture="universal"` (строчные) → совпадает с `...release.universal`,
  экспорт проходит.

Значит пресет обязан стоять в `universal`, а **arm64-only получается пост-обработкой**:
универсальный бинарник прорежется `lipo -thin arm64`, переподписан ad-hoc и
перепакован. Это единственный путь, который и работает со штатным шаблоном, и
даёт настоящий arm64-only артефакт.

Ещё одно требование движка: экспорт arm64/universal на macOS невозможен при
выключенном ETC2/ASTC. В `project.godot` добавлена строка
`textures/vram_compression/import_etc2_astc=true` (в секцию `[rendering]`).
Она аддитивна: рендерер `gl_compatibility` на Apple Silicon и так декодирует
ETC2/ASTC, поведение Windows-сборки и тестов не меняет (тесты остались
зелёными).

## Команда сборки

Шаг 1 — экспорт universal-шаблона во временный zip:

```bash
mkdir -p build/macos
godot --headless --path . --export-release "macOS" /tmp/pepl_universal.zip
```

Шаг 2 — прорезать бинарник до arm64, переподписать ad-hoc, перепаковать:

```bash
rm -rf /tmp/pepl_work && mkdir -p /tmp/pepl_work
unzip -q /tmp/pepl_universal.zip -d /tmp/pepl_work
APP="/tmp/pepl_work/Пепел старого королевства.app"
BIN="$APP/Contents/MacOS/Пепел старого королевства"
lipo -thin arm64 "$BIN" -output "$BIN.arm64" && mv "$BIN.arm64" "$BIN" && chmod +x "$BIN"
codesign --force --deep --sign - "$APP"
cd /tmp/pepl_work && rm -f /tmp/final.zip
ditto -c -k --keepParent "Пепел старого королевства.app" /tmp/final.zip
cp /tmp/final.zip build/macos/Pepl-macos-arm64.zip
```

Готово: `build/macos/Pepl-macos-arm64.zip`.

## Версия 001

`config/version="001"` в `project.godot` и `application/short_version` /
`application/version="001"` в пресете. Попадают в `Info.plist` как
`CFBundleShortVersionString=001` и `CFBundleVersion=001`. 001 — первый
пронумерованный релиз-срез; это номер сборки, а не обещание контента.

## Подпись: ad-hoc, без нотаризации

Сборка подписана **ad-hoc** (`codesign --sign -`): `Signature=adhoc`,
`TeamIdentifier=not set`. Нотаризации в Apple **нет** (`notarization=0`),
коммерческого Developer ID нет. `codesign --verify --deep --strict` проходит.
Минимальная macOS для arm64 — `11.00`.

## Как открыть на другом Mac

Из-за ad-hoc подписи и отсутствия нотаризации Gatekeeper по двойному клику
заблокирует запуск («не может быть открыт, так как от неизвестного разработчика
/ повреждён»). Варианты:

1. **Правой кнопкой → Открыть** (однократное подтверждение), либо
2. снять карантин после распаковки:

   ```bash
   ditto -x -k Pepl-macos-arm64.zip .
   xattr -dr com.apple.quarantine "Пепел старого королевства.app"
   open "Пепел старого королевства.app"
   ```

Работает на Apple Silicon (arm64) с macOS 11 и новее. На Intel Mac этот
артефакт **не запустится** — там только arm64-срез.

## Честно про риски

- **Эту сборку никто не прогонял руками как игру (не плейтестил).** Проверено только то, что `.pck`
  грузится, главная сцена инициализируется и отдаёт кадр 480x270, тесты
  зелёные и ошибок в логе нет. Полноценного игрового прогона человеком не было.
- Артефакт ad-hoc и без нотаризации — для распространения «из коробки» чужому
  пользователю потребуется нотаризация под реальным Developer ID.
- Пресет намеренно в `universal` (иначе штатный шаблон не находится); arm64
  гарантирует пост-обработка `lipo`. Если менять пресет — не забыть, что
  «arm64» в пресете с этим шаблоном не работает.
- В `project.godot` включён импорт ETC2/ASTC — это нужно для экспорта на
  Apple Silicon; при откате этой строки экспорт arm64/universal снова упадёт.
