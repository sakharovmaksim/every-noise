# Every Noise — building and development

For using the app see [README.md](README.md).

Requires macOS 15+ and the Command Line Tools (`xcode-select --install`). Xcode is not
needed: the bundle is built directly with `swiftc`.

## Building

`make` is the entry point; running it without arguments prints the list of targets:

```bash
make check                    # type-check without building anything
make app                      # → dist/Every Noise.app for the current architecture
make universal                # arm64 + x86_64
make release VERSION=1.0.0    # universal + zip for a release
make run                      # build and restart the local copy
make install                  # put it in /Applications and launch
make icon                     # regenerate Resources/AppIcon.icns
make log                      # tail the running app's log
make clean                    # remove .build and dist
```

The Settings tab shows build info: version, build number, commit, tag, date and
architectures. Everything except the version is written into `Info.plist` by the build
script (`GitCommit`, `GitTag`, `BuildDate`, `BuildArchitectures`), so a build made outside
the script simply omits those lines.

All the packaging work is done by `scripts/build-app.sh`; the Makefile is a thin wrapper
around it, so the script can also be called directly with `--universal`, `--zip` and
`--version`. The script compiles the sources (Swift 6, `-O -whole-module-optimization`,
target macOS 15.0), merges the architectures with `lipo`, assembles the `.app` with its
`Info.plist` and icon, and signs it ad-hoc. When `VERSION` is not set, the version comes
from the latest git tag and the build number from the commit count.

`Package.swift` is there for SourceKit-LSP and Xcode. If `swift build` fails with
`Invalid manifest` and `has no member 'defaultIsolation'`, the `PackageDescription` module
in your Command Line Tools installation is out of sync with the compiler; build through
`make`, which does not depend on SwiftPM.

## Releasing

On a `v*` tag push the `.github/workflows/release.yml` workflow runs the same targets you
run locally — `make check` and `make release VERSION=…` — on a `macos-26` runner and
publishes a release with the archive. If a release with that tag already exists the workflow
does not fail: it replaces the archive (`gh release upload --clobber`) and updates the title,
so re-running a build on the same tag is safe.

```bash
git tag -a v1.0.0 -m "Every Noise 1.0.0" && git push origin v1.0.0
```

Manually: `make release VERSION=1.0.0`, then
`gh release create v1.0.0 dist/EveryNoise-1.0.0.zip --title 1.0.0 --generate-notes`, or
upload the archive through the web interface. There is no notarization, so users have to
clear the quarantine flag themselves.

## Layout

```
Sources/EveryNoise/
  EveryNoiseApp.swift               scenes: Window + MenuBarExtra
  Model/AppModel.swift              root model, showing the window, quitting
  Model/Settings.swift              presets, intervals, route hold, launch at login
  Model/KeepAwakeController.swift   pulse scheduler, reaction to sleep and route changes
  Audio/ToneEngine.swift            AVAudioEngine: pulses and the hold carrier
  Audio/AudioOutputInspector.swift  CoreAudio HAL: device, connection type, mute
  Audio/AudioRouteMonitor.swift     HAL listeners: jack, AirPlay, format changes
  Support/AuditLog.swift            in-memory log + file with rotation
  Support/BuildInfo.swift           build info from Info.plist
  Support/SingleInstance.swift      guard against a second copy
  Support/Localization.swift        language switch, L() lookup
  Support/EnglishStrings.swift      English strings keyed by the Russian source
  Views/                            StatusView, SettingsView, LogView, MenuBarContent,
                                    MenuBarIcon
Resources/                          Info.plist and AppIcon.icns
images/                             icon and screenshots for the README
Makefile                            targets for local builds and CI
scripts/                            build-app.sh, make-icon.swift
```

## When making changes

- Swift 6 language mode with strict concurrency and `-default-isolation MainActor`: the UI
  runs on the main actor, while `LogFileWriter` and `AudioRouteMonitor` are marked
  `nonisolated` explicitly. The flags are duplicated in `Package.swift` and
  `scripts/build-app.sh` — edit both.
- New files are picked up automatically: both the Makefile and the script take everything
  under `Sources` via `find`.
- The wave geometry is duplicated in `scripts/make-icon.swift` and `Views/MenuBarIcon.swift`.
- Never assign to a property inside its own `didSet` in an `@Observable` class: the macro
  turns the property into a computed one, the write goes back through the setter and recurses
  until the stack overflows. Clamp values when reading them from storage instead.
- A running `AVAudioEngine` makes coreaudiod hold `PreventUserIdleSystemSleep` — check with
  `pmset -g assertions`. That is why the running app used to prevent the Mac from sleeping,
  and why there is a pause on user inactivity (`KeepAwakeController.watchIdle`, threshold
  `idleThreshold`) and a stop on `NSWorkspace.willSleepNotification`. Any change that keeps
  the engine running longer brings the problem back.
- A second copy is blocked at two levels: `LSMultipleInstancesProhibited` in `Info.plist`
  (catches `open -n`) and the `SingleInstance` check in `AppModel.init` (catches running the
  binary directly and a copy of the app from another folder).
- UI strings go through `L("русский текст")`, and the Russian source string is the dictionary
  key. Add every new string to `Support/EnglishStrings.swift`; a missing key falls back to
  the key itself.
