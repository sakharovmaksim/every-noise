import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var localization = Localization.shared

        Form {
            Section {
                Picker(L("Периодичность"), selection: $settings.interval) {
                    ForEach(PulseInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Picker(L("Длительность импульса"), selection: $settings.duration) {
                    ForEach(PulseDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
            } header: {
                Text(L("Расписание"))
            } footer: {
                Text(L("Большинство усилителей засыпает через 10–20 минут тишины. Импульс раз в 30 секунд — с запасом; длиннее 1 секунды нужно, если детектор сигнала усилителя срабатывает медленно."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("Частота"), selection: $settings.preset) {
                    ForEach(TonePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text(settings.preset.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("Протестировать импульс")) {
                        model.controller.pulseNow()
                    }
                }
            } header: {
                Text(L("Тон"))
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.level, in: 0.01...1) {
                        Text(L("Уровень"))
                    } minimumValueLabel: {
                        Text(L("тихо"))
                            .font(.caption)
                    } maximumValueLabel: {
                        Text(L("громко"))
                            .font(.caption)
                    }
                    Text(String(format: "%.0f %% · %.0f dBFS", settings.level * 100, settings.levelDecibels))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text(L("Уровень сигнала"))
            } footer: {
                Text(L("Детектору усилителя обычно хватает нескольких милливольт. Начните с 10–15 %: этого достаточно, чтобы разбудить технику, и мало, чтобы нагружать твитеры. Поднимайте, если усилитель всё равно засыпает."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("Удержание маршрута"), selection: $settings.routeHold) {
                    ForEach(RouteHoldMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle(L("Подстраивать частоту под подключение"), isOn: $settings.adaptFrequencyToRoute)
            } header: {
                Text(L("Подключение усилителя"))
            } footer: {
                Text(L("AirPlay и Bluetooth разрывают сессию на тишине: усилитель успевает заснуть между импульсами, а начало следующего импульса съедается переподключением. В режиме удержания приложение непрерывно отдаёт ту же частоту на −70 dBFS — это на 40 дБ ниже порога слышимости и не нагружает твитеры, но маршрут остаётся живым. «Автоматически» включает удержание только для AirPlay, Bluetooth и составных устройств; для джека 3,5 мм и USB оно не нужно.\n\nПодстройка частоты нужна там же: кодек AAC режет всё выше ~18 кГц, поэтому на AirPlay и Bluetooth приложение играет 18 кГц вместо выбранных 19–22. Выбор в пикере «Частота» при этом не меняется — как только вернётесь на джек или USB, заиграет он."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("Язык"), selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Toggle(L("Приостанавливать при простое Mac"), isOn: $settings.pauseWhenIdle)
                Toggle(L("Запускать импульсы при старте приложения"), isOn: $settings.autoStart)
                Toggle(L("Запускать Every Noise при входе в систему"), isOn: $settings.launchAtLogin)
            } header: {
                Text(L("Приложение"))
            } footer: {
                Text(L("Пока приложение играет, macOS считает, что идёт звук, и не даёт Mac уснуть по бездействию. Поэтому после 5 минут без действий пользователя импульсы останавливаются, а аудиотракт отпускается — Mac засыпает как обычно. При первом же движении мыши импульсы возобновляются. Выключайте, только если Mac и так не должен спать.\n\nАвтозапуск работает только для приложения, лежащего в /Applications."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            BuildInfoSection()
        }
        .formStyle(.grouped)
        // Pop-up-кнопки AppKit кешируют заголовок выбранного пункта, поэтому при смене
        // языка пересоздаём форму целиком.
        .id(localization.language)
    }
}

private struct BuildInfoSection: View {
    private let info = BuildInfo.current
    @State private var copied = false

    var body: some View {
        Section {
            LabeledContent(L("Версия")) {
                ValueText(info.versionText)
            }
            if let tag = info.tag {
                LabeledContent(L("Тег")) { ValueText(tag) }
            }
            if let commit = info.commit {
                LabeledContent(L("Коммит")) { ValueText(commit) }
            }
            if let date = info.dateText {
                LabeledContent(L("Собрано")) { ValueText(date) }
            }
            if let architectures = info.architectures {
                LabeledContent(L("Архитектуры")) { ValueText(architectures) }
            }
            HStack {
                Spacer()
                Button(copied ? L("Скопировано") : L("Скопировать для отчёта")) {
                    info.copyReport()
                    copied = true
                }
                .disabled(copied)
            }
        } header: {
            Text(L("Сборка"))
        }
        .textSelection(.enabled)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
