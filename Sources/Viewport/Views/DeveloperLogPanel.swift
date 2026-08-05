import AppKit
import SwiftUI

struct DeveloperLogPanel: View {
    @ObservedObject var store: DeveloperLogStore
    @State private var selectedSource = DeveloperLogSource.web
    @State private var searchText = ""
    @State private var levelFilter = LogLevelFilter.all

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            logContent
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.09))
                .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Log source", selection: $selectedSource) {
                ForEach(DeveloperLogSource.allCases) { source in
                    Label(source.title, systemImage: source.systemImage)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            statusLabel

            Picker(
                "Stored logs",
                selection: Binding(
                    get: {
                        DeveloperLogRetention(
                            rawValue: store.retentionLimitBytes
                        ) ?? .kilobytes512
                    },
                    set: store.setRetentionLimit
                )
            ) {
                ForEach(DeveloperLogRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Maximum log memory per source")

            Picker("Level", selection: $levelFilter) {
                ForEach(LogLevelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()

            TextField("Filter logs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)

            Button {
                store.togglePaused()
            } label: {
                Label(
                    store.isPaused ? "Resume logs" : "Pause logs",
                    systemImage: store.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .labelStyle(.iconOnly)
            .help(store.isPaused ? "Resume log display" : "Pause log display")

            Button {
                copyVisibleLogs()
            } label: {
                Label("Copy visible logs", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled(filteredEntries.isEmpty)
            .help("Copy visible logs")

            Button {
                store.clear(selectedSource)
            } label: {
                Label("Clear logs", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(store.entries(for: selectedSource).isEmpty)
            .help("Clear \(selectedSource.title) logs")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(
                store.isPaused
                    ? "Paused"
                    : store.status(for: selectedSource).label
            )
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 150, alignment: .leading)
    }

    private var logContent: some View {
        let entries = filteredEntries
        return ScrollViewReader { proxy in
            ZStack(alignment: .topLeading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(emptyTitle, systemImage: selectedSource.systemImage)
                            .font(.callout.weight(.medium))
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .onChange(of: entries.last?.id) {
                guard !store.isPaused, let id = entries.last?.id else {
                    return
                }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private var filteredEntries: [DeveloperLogEntry] {
        store.entries(for: selectedSource).filter { entry in
            levelFilter.includes(entry.level)
                && (searchText.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty || levelFilter != .all {
            return "No matching logs"
        }
        if store.isPaused {
            return "Paused"
        }
        return store.status(for: selectedSource).label
    }

    private var emptyMessage: String {
        if store.isPaused {
            return "New entries are retained and will appear when resumed."
        }
        return switch store.status(for: selectedSource) {
        case .streaming:
            "Logs will appear here as they arrive."
        case .idle:
            "Show and select a source to begin streaming."
        case .connecting:
            "Waiting for the log stream to start."
        case let .unavailable(message), let .failed(message):
            message
        }
    }

    private var statusColor: Color {
        if store.isPaused {
            return .orange
        }
        return switch store.status(for: selectedSource) {
        case .streaming: Color.green
        case .connecting: Color.orange
        case .failed: Color.red
        case .idle, .unavailable: Color.secondary
        }
    }

    private func copyVisibleLogs() {
        let text = filteredEntries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.timestamp)) "
                + "[\(entry.level.rawValue.uppercased())] \(entry.message)"
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    fileprivate static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct LogEntryRow: View {
    let entry: DeveloperLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timestamp)
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .leading)
            Text(entry.level.rawValue.uppercased())
                .foregroundStyle(levelColor)
                .frame(width: 64, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestamp: String {
        DeveloperLogPanel.timestampFormatter.string(from: entry.timestamp)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all
    case warnings
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All levels"
        case .warnings: "Warnings + errors"
        case .errors: "Errors"
        }
    }

    func includes(_ level: DeveloperLogLevel) -> Bool {
        switch self {
        case .all:
            true
        case .warnings:
            level == .warning || level == .error
        case .errors:
            level == .error
        }
    }
}
