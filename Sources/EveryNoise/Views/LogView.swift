import AppKit
import SwiftUI

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LogLevel?

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Записей нет",
                    systemImage: "list.bullet.rectangle",
                    description: Text("События появятся, как только приложение начнёт воспроизводить импульсы.")
                )
            } else {
                List(entries) { entry in
                    LogRow(entry: entry)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Уровень", selection: $filter) {
                    Text("Все").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var entries: [LogEntry] {
        let all = model.log.entries.reversed()
        guard let filter else { return Array(all) }
        return all.filter { $0.level == filter }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.log.fileURL.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.log.fileURL])
            }
            Button("Очистить") {
                model.log.clear()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.level.symbol)
                .foregroundStyle(tint)
                .accessibilityLabel(entry.level.title)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private var tint: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
