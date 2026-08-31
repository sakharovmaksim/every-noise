import AppKit
import Foundation

/// LaunchServices блокирует обычный повторный запуск, но `open -n`, прямой запуск
/// бинарника и копия в другой папке проходят мимо — проверяем сами.
enum SingleInstance {
    static func alreadyRunning() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == identifier && $0.processIdentifier != ownPID && !$0.isTerminated
        }
    }
}
