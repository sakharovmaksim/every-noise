import SwiftUI

struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = Localization.shared.language
        let controller = model.controller
        let settings = model.settings

        Form {
            Section {
                StatusHeader(status: controller.status, isRunning: controller.isRunning, suspendedBy: controller.suspendedBy) {
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

            Section(L("Сигнал")) {
                LabeledContent(L("Частота")) {
                    ValueText(frequencyText)
                }
                LabeledContent(L("Периодичность")) {
                    ValueText(settings.interval.title)
                }
                LabeledContent(L("Длительность импульса")) {
                    ValueText(settings.duration.title)
                }
                LabeledContent(L("Уровень")) {
                    ValueText(controller.levelText)
                }
            }

            Section(L("Вывод")) {
                LabeledContent(L("Устройство")) {
                    ValueText(controller.device?.name ?? L("не определено"))
                }
                LabeledContent(L("Подключение")) {
                    ValueText(controller.device?.transport.title ?? "—")
                }
                LabeledContent(L("Частота дискретизации")) {
                    ValueText(sampleRateText)
                }
                LabeledContent(L("Удержание маршрута")) {
                    ValueText(controller.isHoldingRoute ? L("включено") : L("выключено"))
                }
                LabeledContent(L("Громкость системы")) {
                    ValueText(volumeText)
                }
            }

            Section(L("Расписание")) {
                LabeledContent(L("Последний импульс")) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ValueText(lastPulseText)
                    }
                }
                LabeledContent(L("Следующий импульс")) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ValueText(nextPulseText)
                    }
                }
                LabeledContent(L("Импульсов с запуска")) {
                    ValueText("\(controller.pulseCount)")
                }
            }
        }
        .formStyle(.grouped)
        .id(Localization.shared.language)
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
            return L("Вывод «%@» замьючен или громкость на нуле — усилитель не увидит сигнал.", device.name)
        }
        if let device = controller.device, device.isAnalogAndQuiet {
            return L("Системная громкость %d %%: на аналоговом выходе сигнал может не дотянуть до порога детектора усилителя.", Int((device.volume ?? 0) * 100))
        }
        if let device = controller.device,
           device.transport.compressesAudio,
           !model.settings.adaptFrequencyToRoute,
           model.settings.preset.frequency > device.transport.recommendedMaxFrequency {
            return "\(device.transport.title) сжимает звук кодеком AAC и срезает всё выше ~18 кГц. Выберите пресет 17–18 кГц или включите подстройку частоты в настройках."
        }
        if let report = controller.lastReport, report.wasClamped, !model.settings.adaptFrequencyToRoute {
            return L("Тон снижен до %d Гц: устройство работает на %d Гц. Поднимите частоту дискретизации в «Настройке Audio-MIDI» или выберите пресет ниже.", Int(report.frequency), Int(report.sampleRate))
        }
        if let rate = controller.device?.sampleRate, rate > 0,
           !model.settings.adaptFrequencyToRoute,
           rate < model.settings.preset.requiredSampleRate {
            return L("Для %@ нужна частота дискретизации не ниже %d Гц, а устройство работает на %d Гц.", model.settings.preset.shortTitle, Int(model.settings.preset.requiredSampleRate), Int(rate))
        }
        return nil
    }

    private var frequencyText: String {
        let controller = model.controller
        guard controller.isFrequencyAdapted else { return model.settings.preset.shortTitle }
        let transport = controller.device?.transport.title ?? L("маршрут")
        return L("%@ · подстроено под %@", controller.effectivePreset.shortTitle, transport)
    }

    /// Внешние ЦАП часто не отдают громкость: сигнал идёт на 0 dBFS.
    private var volumeText: String {
        guard let device = model.controller.device else { return "—" }
        guard let volume = device.volume else { return L("не регулируется устройством") }
        return String(format: "%.0f %%", volume * 100)
    }

    private var sampleRateText: String {
        guard let rate = model.controller.device?.sampleRate, rate > 0 else { return "—" }
        return String(format: L("%.1f кГц"), rate / 1000)
    }

    private var lastPulseText: String {
        guard let date = model.controller.lastPulseDate else { return L("ещё не было") }
        let seconds = Int(Date().timeIntervalSince(date))
        return L("%@ · %d с назад", date.formatted(date: .omitted, time: .standard), seconds)
    }

    private var nextPulseText: String {
        if let reason = model.controller.suspendedBy { return reason.nextPulseText }
        guard model.controller.isRunning, let date = model.controller.nextPulseDate else { return "—" }
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded()))
        return remaining == 0 ? L("сейчас") : L("через %d с", remaining)
    }
}

private struct StatusHeader: View {
    let status: KeeperStatus
    let isRunning: Bool
    let suspendedBy: SuspendReason?
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

            Button(isRunning ? L("Остановить") : L("Запустить"), action: toggle)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        if suspendedBy != nil { return "moon.circle.fill" }
        return switch status {
        case .running: "waveform.circle.fill"
        case .stopped: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if suspendedBy != nil { return .secondary }
        return switch status {
        case .running: .green
        case .stopped: .secondary
        case .failed: .orange
        }
    }

    private var subtitle: String {
        if let suspendedBy { return suspendedBy.statusText }
        return switch status {
        case .running: L("Усилитель получает неслышимый тон по расписанию")
        case .stopped: L("Импульсы не воспроизводятся, усилитель может уснуть")
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
