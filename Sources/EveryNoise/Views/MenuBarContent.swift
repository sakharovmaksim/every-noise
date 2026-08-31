import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = Localization.shared.language
        @Bindable var settings = model.settings
        let controller = model.controller

        Section(statusLine) {
            Button(controller.isRunning ? L("Приостановить") : L("Запустить")) {
                controller.toggle()
            }
            Button(L("Воспроизвести сейчас")) {
                controller.pulseNow()
            }
        }

        Divider()

        Menu(L("Частота")) {
            Picker(L("Частота"), selection: $settings.preset) {
                ForEach(TonePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu(L("Периодичность")) {
            Picker(L("Периодичность"), selection: $settings.interval) {
                ForEach(PulseInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        Button(L("Открыть Every Noise")) {
            model.showMainWindow(using: openWindow)
        }
        .keyboardShortcut("o")

        Button(L("Выйти")) {
            model.quit()
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        let controller = model.controller
        switch controller.status {
        case .running:
            if let reason = controller.suspendedBy { return reason.shortText }
            return "\(model.settings.preset.shortTitle) · \(model.settings.interval.shortTitle)"
        case .stopped:
            return L("Остановлено")
        case .failed(let reason):
            return L("Ошибка: %@", reason)
        }
    }
}
