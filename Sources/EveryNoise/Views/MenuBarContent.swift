import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = model.settings
        let controller = model.controller

        Section(statusLine) {
            Button(controller.isRunning ? "Приостановить" : "Запустить") {
                controller.toggle()
            }
            Button("Воспроизвести сейчас") {
                controller.pulseNow()
            }
            .disabled(!controller.isRunning)
        }

        Divider()

        Menu("Частота") {
            Picker("Частота", selection: $settings.preset) {
                ForEach(TonePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("Периодичность") {
            Picker("Периодичность", selection: $settings.interval) {
                ForEach(PulseInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        Button("Открыть Every Noise") {
            model.showMainWindow(using: openWindow)
        }
        .keyboardShortcut("o")

        Button("Выйти") {
            model.quit()
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        let controller = model.controller
        switch controller.status {
        case .running:
            return "\(model.settings.preset.shortTitle) · \(model.settings.interval.shortTitle)"
        case .stopped:
            return "Остановлено"
        case .failed(let reason):
            return "Ошибка: \(reason)"
        }
    }
}
