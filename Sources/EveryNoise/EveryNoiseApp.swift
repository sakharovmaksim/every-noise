import SwiftUI

@main
struct EveryNoiseApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Every Noise", id: AppModel.mainWindowID) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: 680, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            switch model.controller.status {
            case .running:
                Image(nsImage: MenuBarIcon.wave(active: true))
                    .accessibilityLabel("Every Noise — работает")
            case .stopped:
                Image(nsImage: MenuBarIcon.wave(active: false))
                    .accessibilityLabel("Every Noise — остановлено")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityLabel("Every Noise — ошибка")
            }
        }
    }
}
