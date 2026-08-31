import AppKit
import SwiftUI

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LogLevel?

    var body: some View {
        let _ = Localization.shared.language
        @Bindable var log = model.log

        VStack(spacing: 0) {
            // Полоса нужна только над списком: на пустом журнале то же самое говорит заглушка.
            if !model.log.isEnabled, !entries.isEmpty {
                Label(L("Запись выключена — новые события не сохраняются"), systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
                Divider()
            }

            if entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Picker(L("Уровень"), selection: $filter) {
                    Text(L("Все")).tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.log.isEnabled {
            ContentUnavailableView(
                L("Запись выключена"),
                systemImage: "pause.circle",
                description: Text(L("Новые события не сохраняются. Включите запись флажком внизу."))
            )
        } else if filter != nil {
            ContentUnavailableView(
                L("Ничего не найдено"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(L("Записей выбранного уровня нет — снимите фильтр."))
            )
        } else {
            ContentUnavailableView(
                L("Записей нет"),
                systemImage: "list.bullet.rectangle",
                description: Text(L("События появятся, как только приложение начнёт воспроизводить импульсы."))
            )
        }
    }

    private var entries: [LogEntry] {
        let all = model.log.entries.reversed()
        guard let filter else { return Array(all) }
        return all.filter { $0.level == filter }
    }

    private var footer: some View {
        @Bindable var log = model.log

        return HStack(spacing: 12) {
            Toggle(L("Запись"), isOn: $log.isEnabled)
                .help(L("Записывать события в журнал и в файл"))
                .fixedSize()

            Text(model.log.fileURL.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button(L("Показать в Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([model.log.fileURL])
            }
            Button(L("Очистить")) {
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
