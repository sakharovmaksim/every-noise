import Foundation
import Observation

enum LogLevel: String, CaseIterable, Sendable, Equatable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var title: String {
        switch self {
        case .info: L("Информация")
        case .warning: L("Предупреждение")
        case .error: L("Ошибка")
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct LogEntry: Identifiable, Sendable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

@Observable
final class AuditLog {
    private(set) var entries: [LogEntry] = []

    /// Выключенная запись не пишет ни в файл, ни в список: журнал замирает на том,
    /// что уже накоплено.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: enabledKey)
            record(.info, isEnabled ? L("Запись журнала включена") : L("Запись журнала выключена"))
        }
    }

    private let writer: LogFileWriter
    private let inMemoryLimit = 500
    private let defaults: UserDefaults
    private let enabledKey = "loggingEnabled"

    var fileURL: URL { writer.fileURL }
    var directoryURL: URL { writer.directoryURL }

    init(fileName: String = "every-noise.log", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/EveryNoise", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EveryNoise", isDirectory: true)
        writer = LogFileWriter(directoryURL: base, fileName: fileName)
        entries = writer.loadTail(limit: inMemoryLimit)
    }

    func log(_ level: LogLevel, _ message: String) {
        guard isEnabled else { return }
        record(level, message)
    }

    private func record(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > inMemoryLimit {
            entries.removeFirst(entries.count - inMemoryLimit)
        }
        writer.append(level: level, date: entry.date, message: message)
    }

    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }

    func clear() {
        entries.removeAll()
        writer.truncate()
        info(L("Журнал очищен"))
    }

    func flush() { writer.flush() }
}

nonisolated final class LogFileWriter: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL

    private let queue: DispatchQueue
    private let maxBytes: UInt64 = 512 * 1024
    private let generations = 5
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0

    /// Используется только внутри `queue`.
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directoryURL: URL, fileName: String) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(fileName)
        self.queue = DispatchQueue(label: "com.sakharovmaksim.every-noise.log", qos: .utility)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func append(level: LogLevel, date: Date, message: String) {
        queue.async { [self] in
            let line = "\(stamp.string(from: date)) [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded(incoming: UInt64(data.count))
            guard let handle = openHandle() else { return }
            do {
                try handle.write(contentsOf: data)
                currentSize += UInt64(data.count)
            } catch {
                closeHandle()
            }
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    func truncate() {
        queue.sync { [self] in
            closeHandle()
            try? Data().write(to: fileURL)
            currentSize = 0
        }
    }

    func loadTail(limit: Int) -> [LogEntry] {
        queue.sync { [self] in
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            // С заменой: повреждённый байт не должен стоить всей истории.
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
            return lines.compactMap { parse(String($0)) }
        }
    }

    private func parse(_ line: String) -> LogEntry? {
        // "2026-08-31 14:05:01.123 [INFO] message"
        guard line.count > 26, let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]") else { return nil }
        let stampText = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        guard let date = stamp.date(from: stampText) else { return nil }
        let levelText = String(line[line.index(after: open)..<close])
        let level = LogLevel(rawValue: levelText) ?? .info
        let message = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return LogEntry(date: date, level: level, message: message)
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        // O_APPEND: две копии приложения не перемешают строки посреди символа.
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return handle
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func rotateIfNeeded(incoming: UInt64) {
        guard currentSize + incoming > maxBytes else { return }
        closeHandle()
        let fm = FileManager.default
        try? fm.removeItem(at: rotated(index: generations))
        for index in stride(from: generations - 1, through: 1, by: -1) {
            let source = rotated(index: index)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.moveItem(at: source, to: rotated(index: index + 1))
        }
        try? fm.moveItem(at: fileURL, to: rotated(index: 1))
        fm.createFile(atPath: fileURL.path, contents: nil)
        currentSize = 0
        let notice = "\(stamp.string(from: Date())) [\(LogLevel.info.rawValue)] " + L("Ротация журнала: предыдущий файл сохранён как %@", rotated(index: 1).lastPathComponent) + "\n"
        if let data = notice.data(using: .utf8), let handle = openHandle() {
            try? handle.write(contentsOf: data)
            currentSize += UInt64(data.count)
        }
    }

    private func rotated(index: Int) -> URL {
        fileURL.appendingPathExtension(String(index))
    }
}
