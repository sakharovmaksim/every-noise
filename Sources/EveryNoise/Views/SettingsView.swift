import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Picker("Периодичность", selection: $settings.interval) {
                    ForEach(PulseInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Picker("Длительность импульса", selection: $settings.duration) {
                    ForEach(PulseDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
            } header: {
                Text("Расписание")
            } footer: {
                Text("Большинство усилителей засыпает через 10–20 минут тишины. Импульс раз в 30 секунд — с запасом; длиннее 1 секунды нужно, если детектор сигнала усилителя срабатывает медленно.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Частота", selection: $settings.preset) {
                    ForEach(TonePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text(settings.preset.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Тон")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.level, in: 0.01...1) {
                        Text("Уровень")
                    } minimumValueLabel: {
                        Text("тихо")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("громко")
                            .font(.caption)
                    }
                    Text(String(format: "%.0f %% · %.0f dBFS", settings.level * 100, settings.levelDecibels))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Уровень сигнала")
            } footer: {
                Text("Детектору усилителя обычно хватает нескольких милливольт. Начните с 10–15 %: этого достаточно, чтобы разбудить технику, и мало, чтобы нагружать твитеры. Поднимайте, если усилитель всё равно засыпает.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Удержание маршрута", selection: $settings.routeHold) {
                    ForEach(RouteHoldMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Подстраивать частоту под подключение", isOn: $settings.adaptFrequencyToRoute)
            } header: {
                Text("Подключение усилителя")
            } footer: {
                Text("AirPlay и Bluetooth разрывают сессию на тишине: усилитель успевает заснуть между импульсами, а начало следующего импульса съедается переподключением. В режиме удержания приложение непрерывно отдаёт ту же частоту на −70 dBFS — это на 40 дБ ниже порога слышимости и не нагружает твитеры, но маршрут остаётся живым. «Автоматически» включает удержание только для AirPlay, Bluetooth и составных устройств; для джека 3,5 мм и USB оно не нужно.\n\nПодстройка частоты нужна там же: кодек AAC режет всё выше ~18 кГц, поэтому на AirPlay и Bluetooth приложение играет 18 кГц вместо выбранных 19–22. Выбор в пикере «Частота» при этом не меняется — как только вернётесь на джек или USB, заиграет он.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Запускать импульсы при старте приложения", isOn: $settings.autoStart)
                Toggle("Запускать Every Noise при входе в систему", isOn: $settings.launchAtLogin)
            } header: {
                Text("Приложение")
            } footer: {
                Text("Автозапуск работает только для приложения, лежащего в /Applications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            BuildInfoSection()
        }
        .formStyle(.grouped)
    }
}

private struct BuildInfoSection: View {
    private let info = BuildInfo.current
    @State private var copied = false

    var body: some View {
        Section {
            LabeledContent("Версия") {
                ValueText(info.versionText)
            }
            if let tag = info.tag {
                LabeledContent("Тег") { ValueText(tag) }
            }
            if let commit = info.commit {
                LabeledContent("Коммит") { ValueText(commit) }
            }
            if let date = info.dateText {
                LabeledContent("Собрано") { ValueText(date) }
            }
            if let architectures = info.architectures {
                LabeledContent("Архитектуры") { ValueText(architectures) }
            }
            HStack {
                Spacer()
                Button(copied ? "Скопировано" : "Скопировать для отчёта") {
                    info.copyReport()
                    copied = true
                }
                .disabled(copied)
            }
        } header: {
            Text("Сборка")
        }
        .textSelection(.enabled)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
