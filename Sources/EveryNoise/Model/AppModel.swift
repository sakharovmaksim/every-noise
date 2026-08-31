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

        // Проверяем до создания аудиодвижка, чтобы вторая копия не успела ничего сыграть.
        if let existing = SingleInstance.alreadyRunning() {
            log.warning("Every Noise уже запущен (PID \(existing.processIdentifier)) — активирую его и выхожу")
            log.flush()
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }

        let settings = AppSettings()
        self.log = log
        self.settings = settings
        self.controller = KeepAwakeController(settings: settings, log: log)

        settings.onLoginItemError = { [weak log] message in
            log?.error("Автозапуск не настроен: \(message)")
        }

        log.info("Every Noise запущен (\(version))")
        if settings.autoStart {
            controller.start()
        } else {
            log.info("Автостарт выключен — ожидание команды пользователя")
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

    /// Показать главное окно: возвращаем иконку в Dock, чтобы работали меню и ⌘W.
    func showMainWindow(using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: Self.mainWindowID)
        NSApp.activate()
    }

    /// Окно закрыли — снова живём только в строке меню.
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
        controller.stop(reason: "перед выходом из приложения")
        log.info("Every Noise завершает работу")
        log.flush()
    }
}
