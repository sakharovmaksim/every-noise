# Every Noise — сборка и разработка

Как пользоваться приложением — в [README.md](README.md).

Требуется macOS 15+ и Command Line Tools (`xcode-select --install`). Xcode не нужен:
бандл собирается напрямую через `swiftc`.

## Сборка

Точка входа — `make`, список целей покажет `make` без аргументов:

```bash
make check                    # проверить типы, ничего не собирая
make app                      # → dist/Every Noise.app под текущую архитектуру
make universal                # arm64 + x86_64
make release VERSION=1.0.0    # universal + zip для релиза
make run                      # собрать и перезапустить локальную копию
make install                  # положить в /Applications и запустить
make icon                     # перегенерировать Resources/AppIcon.icns
make log                      # tail журнала работающего приложения
make clean                    # удалить .build и dist
```

Во вкладке «Настройки» приложение показывает сведения о сборке: версию, номер, коммит,
тег, дату и архитектуры. Всё, кроме версии, скрипт подставляет в `Info.plist` (`GitCommit`,
`GitTag`, `BuildDate`, `BuildArchitectures`), поэтому при сборке в обход скрипта эти строки
просто не отображаются.

Всю работу по упаковке делает `scripts/build-app.sh`, Makefile — тонкая обёртка над ним,
так что скрипт можно вызывать и напрямую с флагами `--universal`, `--zip`, `--version`.
Скрипт компилирует исходники (Swift 6, `-O -whole-module-optimization`, цель macOS 15.0),
склеивает архитектуры через `lipo`, собирает `.app` с `Info.plist` и иконкой и подписывает
ad-hoc подписью. Если `VERSION` не задан, версия берётся из последнего git-тега, а номер
сборки — из числа коммитов.

`Package.swift` лежит для SourceKit-LSP и Xcode. Если `swift build` падает с
`Invalid manifest` и `has no member 'defaultIsolation'` — в вашей установке Command Line
Tools модуль `PackageDescription` рассинхронизирован с компилятором; собирайте через
`make`, он от SwiftPM не зависит.

## Релиз

По пушу тега `v*` workflow `.github/workflows/release.yml` запускает на раннере `macos-26`
те же цели, что и вы локально — `make check` и `make release VERSION=…`, — и публикует
релиз с архивом. Если релиз с таким тегом уже есть, workflow
не падает, а заменяет в нём архив (`gh release upload --clobber`) и обновляет заголовок —
так что перезапуск сборки на том же теге безопасен:

```bash
git tag -a v1.0.0 -m "Every Noise 1.0.0" && git push origin v1.0.0
```

Вручную: `make release VERSION=1.0.0`, затем
`gh release create v1.0.0 dist/EveryNoise-1.0.0.zip --title 1.0.0 --generate-notes` или загрузка архива
через веб-интерфейс. Нотаризации нет, поэтому пользователю нужно снять карантин.

## Структура

```
Sources/EveryNoise/
  EveryNoiseApp.swift               сцены: Window + MenuBarExtra
  Model/AppModel.swift              корневая модель, показ окна, выход
  Model/Settings.swift              пресеты, интервалы, удержание маршрута, автозапуск
  Model/KeepAwakeController.swift   планировщик импульсов, реакция на сон и маршрут
  Audio/ToneEngine.swift            AVAudioEngine: импульсы и несущая удержания
  Audio/AudioOutputInspector.swift  CoreAudio HAL: устройство, тип подключения, mute
  Audio/AudioRouteMonitor.swift     слушатели HAL: джек, AirPlay, смена формата
  Support/AuditLog.swift            журнал в памяти + файл с ротацией
  Support/BuildInfo.swift           сведения о сборке из Info.plist
  Support/SingleInstance.swift      защита от второй копии приложения
  Views/                            StatusView, SettingsView, LogView, MenuBarContent,
                                    MenuBarIcon
Resources/                          Info.plist и AppIcon.icns
images/                             иконка и скриншоты для README
Makefile                            цели для локальной сборки и CI
scripts/                            build-app.sh, make-icon.swift
```

## При правках

- Языковой режим Swift 6 со строгой конкурентностью и `-default-isolation MainActor`: UI
  на главном акторе, `LogFileWriter` и `AudioRouteMonitor` помечены `nonisolated` явно.
  Флаги продублированы в `Package.swift` и `scripts/build-app.sh` — правьте оба места.
- Новые файлы подхватываются автоматически: и Makefile, и скрипт берут всё из `Sources`
  через `find`.
- Геометрия волны продублирована в `scripts/make-icon.swift` и `Views/MenuBarIcon.swift`.
- Запущенный `AVAudioEngine` заставляет coreaudiod держать `PreventUserIdleSystemSleep` —
  проверяется через `pmset -g assertions`. Из-за этого работающее приложение не давало Mac
  уснуть, и появилась пауза по простою пользователя (`KeepAwakeController.watchIdle`,
  порог `idleThreshold`) и остановка по `NSWorkspace.willSleepNotification`. Любая правка,
  которая держит движок дольше, вернёт проблему.
- Вторую копию отсекают два уровня: `LSMultipleInstancesProhibited` в `Info.plist` (ловит
  `open -n`) и проверка `SingleInstance` в `AppModel.init` (ловит прямой запуск бинарника
  и копию приложения из другой папки).
