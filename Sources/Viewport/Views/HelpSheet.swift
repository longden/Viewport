import AppKit
import SwiftUI

struct HelpSheet: View {
    @ObservedObject var androidDevices: DeviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var report: AndroidSetupReport?
    @State private var isChecking = true
    @State private var showCreateSheet = false
    @State private var copiedCommandID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(
                        "Viewport needs a few tools on this Mac to list, create, and stream devices. Recheck after installing anything."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    statusSection

                    installGuidesSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task {
            await refreshReport()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateAndroidEmulatorSheet(manager: androidDevices)
        }
        .onChange(of: androidDevices.devices.count) {
            Task { await refreshReport() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("This Mac")

            if isChecking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking this Mac…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let report {
                VStack(spacing: 10) {
                    ForEach(report.items) { item in
                        checkRow(item)
                    }
                }

                if report.canCreateEmulators {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label(
                            "Create Android emulator…",
                            systemImage: "plus.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text(
                        "Once Android Studio (or the Android CLI) and a system image are installed, you can create an emulator here."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var installGuidesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Install guides")

            Text(
                "Copy a brew command into Terminal, or open a download page. Homebrew: https://brew.sh"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            VStack(spacing: 10) {
                ForEach(SetupInstallGuides.all) { guide in
                    installGuideRow(guide)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Help")
                    .font(.title2.weight(.semibold))
                Text("Setup & downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await refreshReport() }
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .disabled(isChecking)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func checkRow(_ item: SetupCheckItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol(item.status))
                    .foregroundStyle(statusColor(item.status))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if item.status != .ready {
                installActions(
                    command: item.installCommand,
                    commandID: "check-\(item.id)",
                    url: item.installURL,
                    urlTitle: item.installURLTitle
                )
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func installGuideRow(_ guide: SetupInstallGuide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guide.title)
                .font(.body.weight(.medium))
            Text(guide.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = guide.command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            installActions(
                command: guide.command,
                commandID: "guide-\(guide.id)",
                url: guide.url,
                urlTitle: guide.urlTitle
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    private func installActions(
        command: String?,
        commandID: String,
        url: URL?,
        urlTitle: String?
    ) -> some View {
        if command != nil || url != nil {
            HStack(spacing: 8) {
                if let command {
                    Button {
                        copyCommand(command, id: commandID)
                    } label: {
                        Label(
                            copiedCommandID == commandID ? "Copied" : "Copy command",
                            systemImage: copiedCommandID == commandID
                                ? "checkmark"
                                : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(
                            urlTitle ?? "Open link",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func statusSymbol(_ status: SetupCheckStatus) -> String {
        switch status {
        case .ready:
            "checkmark.circle.fill"
        case .missing:
            "xmark.circle.fill"
        case .optionalMissing:
            "exclamationmark.circle"
        }
    }

    private func statusColor(_ status: SetupCheckStatus) -> Color {
        switch status {
        case .ready:
            .green
        case .missing:
            .red
        case .optionalMissing:
            .orange
        }
    }

    private func copyCommand(_ command: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommandID = id

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCommandID == id {
                copiedCommandID = nil
            }
        }
    }

    private func refreshReport() async {
        isChecking = true
        report = await AndroidSetupDiagnostics().evaluate()
        isChecking = false
    }
}
