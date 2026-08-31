import SwiftUI

struct MainWindowView: View {
    private enum Section: Hashable {
        case status, settings, log
    }

    @Environment(AppModel.self) private var model
    @State private var section: Section = .status

    var body: some View {
        let _ = Localization.shared.language
        TabView(selection: $section) {
            Tab(L("Статус"), systemImage: "waveform", value: Section.status) {
                StatusView()
            }
            Tab(L("Настройки"), systemImage: "slider.horizontal.3", value: Section.settings) {
                SettingsView()
            }
            Tab(L("Журнал"), systemImage: "list.bullet.rectangle", value: Section.log) {
                LogView()
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .onDisappear {
            model.mainWindowDidClose()
        }
    }
}
