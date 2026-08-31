import AppKit
import Foundation

/// Защита от второй копии приложения.
///
/// LaunchServices не даёт запустить второй экземпляр того же бандла при обычном открытии,
/// но `open -n`, прямой запуск бинарника внутри бандла и вторая копия приложения в другой
/// папке это ограничение обходят. Две копии — двойные импульсы, гонка за настройками и
/// перемешанный журнал, поэтому проверяем сами.
enum SingleInstance {
    /// Другой уже запущенный экземпляр с тем же bundle id, если он есть.
    static func alreadyRunning() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == identifier && $0.processIdentifier != ownPID && !$0.isTerminated
        }
    }
}
