import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class AppModel {
    static let mainWindowID = "main"

    let settings: AppSettings
    let log: AuditLog
    let controller: KeepAwakeController

    @ObservationIgnored private var isTerminating = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    init() {
        let log = AuditLog()

        // До создания движка, чтобы вторая копия не успела ничего сыграть.
        if let existing = SingleInstance.alreadyRunning() {
            log.warning(L("Every Noise уже запущен (PID %d) — активирую его и выхожу", existing.processIdentifier))
            log.flush()
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }

        let settings = AppSettings()
        self.log = log
        self.settings = settings
        self.controller = KeepAwakeController(settings: settings, log: log)

        settings.onLoginItemError = { [weak log] message in
            log?.error(L("Автозапуск не настроен: %@", message))
        }

        log.info(L("Every Noise запущен (%@)", version))
        if settings.autoStart {
            controller.start()
        } else {
            log.info(L("Автостарт выключен — ожидание команды пользователя"))
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForTermination()
            }
        }
    }

    /// Иконка в Dock нужна, чтобы работали меню и ⌘W.
    func showMainWindow(using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: Self.mainWindowID)
        NSApp.activate()
    }

    func mainWindowDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }

    func quit() {
        prepareForTermination()
        NSApp.terminate(nil)
    }

    private func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        controller.stop(reason: L("перед выходом из приложения"))
        log.info(L("Every Noise завершает работу"))
        log.flush()
    }
}
