import AppKit
import Foundation

/// Всё, кроме версии, подставляет `scripts/build-app.sh`.
struct BuildInfo: Sendable {
    let version: String
    let build: String
    let commit: String?
    let tag: String?
    let date: Date?
    let architectures: String?

    static let current = BuildInfo()

    private init() {
        version = BuildInfo.string("CFBundleShortVersionString") ?? "dev"
        build = BuildInfo.string("CFBundleVersion") ?? "0"
        commit = BuildInfo.string("GitCommit")
        tag = BuildInfo.string("GitTag")
        architectures = BuildInfo.string("BuildArchitectures")?.replacingOccurrences(of: " ", with: ", ")
        date = BuildInfo.string("BuildDate").flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Незаполненный плейсхолдер — это отсутствующее значение.
    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("__") else { return nil }
        return trimmed
    }

    var versionText: String { "\(version) (сборка \(build))" }

    var dateText: String? {
        date?.formatted(date: .abbreviated, time: .shortened)
    }

    var report: String {
        var lines = ["Every Noise \(versionText)"]
        if let tag { lines.append("Тег: \(tag)") }
        if let commit { lines.append("Коммит: \(commit)") }
        if let dateText { lines.append("Собрано: \(dateText)") }
        if let architectures { lines.append("Архитектуры: \(architectures)") }
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        return lines.joined(separator: "\n")
    }

    @MainActor
    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
