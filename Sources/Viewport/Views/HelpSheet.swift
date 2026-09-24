import AppKit
import SwiftUI

struct HelpSheet: View {
    @ObservedObject var androidDevices: DeviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var report: AndroidSetupReport?
    @State private var isChecking = true
    @State private var showCreateSheet = false
    @State private var copiedCommandID: String?
    @State private var showInstalledDetails = false
    @State private var installAlertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(
                        "Viewport needs a few tools on this Mac to list, create, and stream devices. Use Install to run a brew command in Terminal. Viewport checks again when you return."
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
        .frame(minWidth: 520, minHeight: 520)
        .task {
            await refreshReport()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateAndroidEmulatorSheet(manager: androidDevices)
        }
        .onChange(of: androidDevices.devices.count) {
            Task { await refreshReport() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await refreshReport() }
        }
        .alert(
            "Couldn’t start install",
            isPresented: Binding(
                get: { installAlertMessage != nil },
                set: { if !$0 { installAlertMessage = nil } }
            )
        ) {
            if installAlertMessage?.contains("Homebrew") == true {
                Button("Open brew.sh") {
                    NSWorkspace.shared.open(SetupTerminalInstaller.homebrewURL)
                    installAlertMessage = nil
                }
            }
            Button("OK", role: .cancel) {
                installAlertMessage = nil
            }
        } message: {
            Text(installAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("This Mac")

            VStack(alignment: .leading, spacing: 12) {
                if isChecking {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking this Mac…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } else if let report {
                    let attentionItems = report.items.filter { $0.status != .ready }
                    let installedItems = report.items.filter { $0.status == .ready }

                    if attentionItems.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Everything Viewport needs is installed.")
                                .font(.body.weight(.medium))
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(attentionItems) { item in
                                checkRow(item, compact: false)
                            }
                        }
                    }

                    if report.shouldShowPhysicalAndroidTip {
                        Text(
                            "USB Android phones only need ADB — scrcpy is optional for smoother streaming. Emulators still need the SDK, Emulator package, and a system image."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if !installedItems.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                showInstalledDetails.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(
                                        .degrees(showInstalledDetails ? 90 : 0)
                                    )
                                Text(
                                    installedItems.count == report.items.count
                                        ? "Installed tools (\(installedItems.count))"
                                        : "Already installed (\(installedItems.count))"
                                )
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            showInstalledDetails ? "Expanded" : "Collapsed"
                        )

                        if showInstalledDetails {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(installedItems) { item in
                                    checkRow(item, compact: true)
                                }
                            }
                            .padding(.top, 4)
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
                    } else if attentionItems.contains(where: {
                        ["sdk", "android-cli", "system-images", "emulator"].contains($0.id)
                    }) {
                        Text(
                            "Once Android Studio (or the Android CLI) and a system image are installed, you can create an emulator here."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var installGuidesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Install guides")

            if isChecking {
                Text("Matching guides to what’s installed…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let neededGuides = report?.neededInstallGuides ?? SetupInstallGuides.all

                if neededGuides.isEmpty {
                    Text(
                        "Nothing left to install for the guides below. Recheck anytime after changing tools."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "Only showing what’s still missing. Install opens Terminal with the brew command. Viewport checks again when you return. Homebrew: https://brew.sh"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                    VStack(spacing: 10) {
                        ForEach(neededGuides) { guide in
                            installGuideRow(guide)
                        }
                    }
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

    private func checkRow(_ item: SetupCheckItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol(item.status))
                    .foregroundStyle(statusColor(item.status))
                    .frame(width: 16)

                if compact {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                } else {
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
            }

            if !compact, item.status != .ready {
                installActions(
                    command: item.installCommand,
                    commandID: "check-\(item.id)",
                    url: item.installURL,
                    urlTitle: item.installURLTitle
                )
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, compact ? 2 : 4)
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
                        runInstall(command)
                    } label: {
                        Label("Install", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        copyCommand(command, id: commandID)
                    } label: {
                        Label(
                            copiedCommandID == commandID ? "Copied" : "Copy",
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

    private func runInstall(_ command: String) {
        Task {
            do {
                try await SetupTerminalInstaller.runInTerminal(command)
            } catch {
                installAlertMessage = error.localizedDescription
            }
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
