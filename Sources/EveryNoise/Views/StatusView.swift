import SwiftUI

struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.controller
        let settings = model.settings

        Form {
            Section {
                StatusHeader(status: controller.status, isRunning: controller.isRunning) {
                    controller.toggle()
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }

            if let warning {
                Section {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }

            Section("Сигнал") {
                LabeledContent("Частота") {
                    ValueText(frequencyText)
                }
                LabeledContent("Периодичность") {
                    ValueText(settings.interval.title)
                }
                LabeledContent("Длительность импульса") {
                    ValueText(settings.duration.title)
                }
                LabeledContent("Уровень") {
                    ValueText(controller.levelText)
                }
            }

            Section("Вывод") {
                LabeledContent("Устройство") {
                    ValueText(controller.device?.name ?? "не определено")
                }
                LabeledContent("Подключение") {
                    ValueText(controller.device?.transport.title ?? "—")
                }
                LabeledContent("Частота дискретизации") {
                    ValueText(sampleRateText)
                }
                LabeledContent("Удержание маршрута") {
                    ValueText(controller.isHoldingRoute ? "включено" : "выключено")
                }
                LabeledContent("Громкость системы") {
                    ValueText(volumeText)
                }
            }

            Section("Расписание") {
                LabeledContent("Последний импульс") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ValueText(lastPulseText)
                    }
                }
                LabeledContent("Следующий импульс") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ValueText(nextPulseText)
                    }
                }
                LabeledContent("Импульсов с запуска") {
                    ValueText("\(controller.pulseCount)")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Страховка на случай, если слушатель HAL что-то пропустил.
            while !Task.isCancelled {
                model.controller.refreshDevice()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var warning: String? {
        let controller = model.controller
        if case .failed(let reason) = controller.status { return reason }
        if let device = controller.device, device.isSilenced {
            return "Вывод «\(device.name)» замьючен или громкость на нуле — усилитель не увидит сигнал."
        }
        if let device = controller.device, device.isAnalogAndQuiet {
            return "Системная громкость \(Int((device.volume ?? 0) * 100)) %: на аналоговом выходе сигнал может не дотянуть до порога детектора усилителя."
        }
        if let device = controller.device,
           device.transport.compressesAudio,
           !model.settings.adaptFrequencyToRoute,
           model.settings.preset.frequency > device.transport.recommendedMaxFrequency {
            return "\(device.transport.title) сжимает звук кодеком AAC и срезает всё выше ~18 кГц. Выберите пресет 17–18 кГц или включите подстройку частоты в настройках."
        }
        if let report = controller.lastReport, report.wasClamped, !model.settings.adaptFrequencyToRoute {
            return "Тон снижен до \(Int(report.frequency)) Гц: устройство работает на \(Int(report.sampleRate)) Гц. Поднимите частоту дискретизации в «Настройке Audio-MIDI» или выберите пресет ниже."
        }
        if let rate = controller.device?.sampleRate, rate > 0,
           !model.settings.adaptFrequencyToRoute,
           rate < model.settings.preset.requiredSampleRate {
            return "Для \(model.settings.preset.shortTitle) нужна частота дискретизации не ниже \(Int(model.settings.preset.requiredSampleRate)) Гц, а устройство работает на \(Int(rate)) Гц."
        }
        return nil
    }

    private var frequencyText: String {
        let controller = model.controller
        guard controller.isFrequencyAdapted else { return model.settings.preset.shortTitle }
        let transport = controller.device?.transport.title ?? "маршрут"
        return "\(controller.effectivePreset.shortTitle) · подстроено под \(transport)"
    }

    /// Внешние ЦАП часто не отдают громкость: сигнал идёт на 0 dBFS.
    private var volumeText: String {
        guard let device = model.controller.device else { return "—" }
        guard let volume = device.volume else { return "не регулируется устройством" }
        return String(format: "%.0f %%", volume * 100)
    }

    private var sampleRateText: String {
        guard let rate = model.controller.device?.sampleRate, rate > 0 else { return "—" }
        return String(format: "%.1f кГц", rate / 1000)
    }

    private var lastPulseText: String {
        guard let date = model.controller.lastPulseDate else { return "ещё не было" }
        let seconds = Int(Date().timeIntervalSince(date))
        return "\(date.formatted(date: .omitted, time: .standard)) · \(seconds) с назад"
    }

    private var nextPulseText: String {
        guard model.controller.isRunning, let date = model.controller.nextPulseDate else { return "—" }
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded()))
        return remaining == 0 ? "сейчас" : "через \(remaining) с"
    }
}

private struct StatusHeader: View {
    let status: KeeperStatus
    let isRunning: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.12), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(isRunning ? "Остановить" : "Запустить", action: toggle)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch status {
        case .running: "waveform.circle.fill"
        case .stopped: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .running: .green
        case .stopped: .secondary
        case .failed: .orange
        }
    }

    private var subtitle: String {
        switch status {
        case .running: "Усилитель получает неслышимый тон по расписанию"
        case .stopped: "Импульсы не воспроизводятся, усилитель может уснуть"
        case .failed(let reason): reason
        }
    }
}

struct ValueText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
