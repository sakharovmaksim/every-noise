# Every Noise — сборка и разработка

Как пользоваться приложением — в [README.md](README.md).

Требуется macOS 15+ и Command Line Tools (`xcode-select --install`). Xcode не нужен:
скрипт собирает бандл напрямую через `swiftc`.

## Сборка

```bash
./scripts/build-app.sh                                     # → dist/Every Noise.app
./scripts/build-app.sh --universal                         # arm64 + x86_64
./scripts/build-app.sh --version 1.0.0 --universal --zip   # + архив для релиза

cp -R "dist/Every Noise.app" /Applications && open -a "Every Noise"
```

Во вкладке «Настройки» приложение показывает сведения о сборке: версию, номер, коммит,
тег, дату и архитектуры. Всё, кроме версии, скрипт подставляет в `Info.plist` (`GitCommit`,
`GitTag`, `BuildDate`, `BuildArchitectures`), поэтому при сборке в обход скрипта эти строки
просто не отображаются.

Скрипт компилирует исходники (Swift 6, `-O -whole-module-optimization`, цель macOS 15.0),
склеивает архитектуры через `lipo`, собирает `.app` с `Info.plist` и иконкой и подписывает
ad-hoc подписью. Версия по умолчанию берётся из последнего git-тега, номер сборки — из
числа коммитов. Иконка при необходимости генерируется: `xcrun swift scripts/make-icon.swift
Resources/AppIcon.icns`.

`Package.swift` лежит для SourceKit-LSP и Xcode. Если `swift build` падает с
`Invalid manifest` и `has no member 'defaultIsolation'` — в вашей установке Command Line
Tools модуль `PackageDescription` рассинхронизирован с компилятором; собирайте скриптом,
он от SwiftPM не зависит.

## Релиз

По пушу тега `v*` workflow `.github/workflows/release.yml` собирает universal binary на
раннере `macos-26` и публикует релиз с архивом:

```bash
git tag -a v1.0.0 -m "Every Noise 1.0.0" && git push origin v1.0.0
```

Вручную: `./scripts/build-app.sh --version 1.0.0 --universal --zip`, затем
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
scripts/                            build-app.sh, make-icon.swift
```

## При правках

- Языковой режим Swift 6 со строгой конкурентностью и `-default-isolation MainActor`: UI
  на главном акторе, `LogFileWriter` и `AudioRouteMonitor` помечены `nonisolated` явно.
  Флаги продублированы в `Package.swift` и `scripts/build-app.sh` — правьте оба места.
- Новые файлы подхватываются автоматически: скрипт берёт всё из `Sources` через `find`.
- Геометрия волны продублирована в `scripts/make-icon.swift` и `Views/MenuBarIcon.swift`.
- Вторую копию отсекают два уровня: `LSMultipleInstancesProhibited` в `Info.plist` (ловит
  `open -n`) и проверка `SingleInstance` в `AppModel.init` (ловит прямой запуск бинарника
  и копию приложения из другой папки).
