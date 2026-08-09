import SwiftUI

/// Deep-link and push injection for visible Android / iOS capture panes.
struct DeviceInjectorSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: InjectorTab = .deepLink
    @State private var deepLink = ""
    @State private var targets: DeviceInjectionTargets = .both
    @State private var alsoOpenWeb = false
    @State private var bundleID = ""
    @State private var pushPayload = DeviceAutomationService.defaultAPNsPayloadJSON
    @State private var notificationTitle = "Viewport"
    @State private var notificationBody = "Test notification"
    @State private var notificationTag = "viewport"
    @State private var isBusy = false
    @State private var statusMessage: String?

    private enum InjectorTab: String, CaseIterable, Identifiable {
        case deepLink
        case push

        var id: String { rawValue }

        var title: String {
            switch self {
            case .deepLink: "Deep Link"
            case .push: "Push"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Tab", selection: $selectedTab) {
                ForEach(InjectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Group {
                switch selectedTab {
                case .deepLink:
                    deepLinkContent
                case .push:
                    pushContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 420, idealHeight: 460)
        .onAppear {
            bundleID = workspace.lastPushBundleID
            pushPayload = workspace.lastPushPayloadJSON
            if deepLink.isEmpty, let recent = workspace.recentDeepLinks.first {
                deepLink = recent
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open URL & Push")
                    .font(.title3.weight(.semibold))
                Text("Fire deep links and test notifications into visible device panes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isBusy)

            if selectedTab == .deepLink {
                Button("Open") {
                    runPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRunPrimary || isBusy)
            }
        }
        .padding(16)
    }

    private var canRunPrimary: Bool {
        let hasURL = !deepLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasURL else { return false }
        return !effectiveDeepLinkTargets.isEmpty || alsoOpenWeb
    }

    private var deepLinkContent: some View {
        Form {
            TextField("https://… or myapp://", text: $deepLink)
                .textFieldStyle(.roundedBorder)

            if !workspace.recentDeepLinks.isEmpty {
                Section("Recent") {
                    ForEach(workspace.recentDeepLinks, id: \.self) { url in
                        Button(url) {
                            deepLink = url
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section("Targets") {
                HStack(spacing: 16) {
                    Toggle("Android", isOn: Binding(
                        get: { targets.contains(.android) },
                        set: { enabled in
                            if enabled {
                                targets.insert(.android)
                            } else {
                                targets.remove(.android)
                            }
                        }
                    ))
                    .disabled(!workspace.isVisible(.android))

                    Toggle("iOS", isOn: Binding(
                        get: { targets.contains(.iOS) },
                        set: { enabled in
                            if enabled {
                                targets.insert(.iOS)
                            } else {
                                targets.remove(.iOS)
                            }
                        }
                    ))
                    .disabled(!workspace.isVisible(.iOS))
                }

                Toggle("Also load in Web pane", isOn: $alsoOpenWeb)
                    .disabled(!workspace.isVisible(.web))

                if workspace.hasPhysicalIOSSelected, targets.contains(.iOS) {
                    Text("Physical iPhones are view-only — deep links need the Simulator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private var pushContent: some View {
        Form {
            Section("iOS Simulator") {
                if workspace.hasIOSSimulatorInjectionTarget {
                    TextField("Bundle ID", text: $bundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())

                    HStack {
                        Text("Presets")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Alert") {
                            pushPayload = DeviceAutomationService.defaultAPNsPayloadJSON
                        }
                        Button("Silent") {
                            pushPayload = DeviceAutomationService.silentAPNsPayloadJSON
                        }
                        Button("Custom data") {
                            pushPayload = DeviceAutomationService.customDataAPNsPayloadJSON
                        }
                    }

                    TextEditor(text: $pushPayload)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)

                    Button("Send push") {
                        run {
                            let result = try await workspace.broadcastPush(
                                payloadJSON: pushPayload,
                                bundleID: bundleID
                            )
                            statusMessage = result.summary(verb: "Pushed")
                        }
                    }
                    .disabled(
                        isBusy
                            || bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || pushPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                } else {
                    Text(
                        workspace.hasPhysicalIOSSelected
                            ? "Push injection works on iOS Simulator only. Select a Simulator in the iOS pane."
                            : "Show iOS and select a Simulator to send an APNs payload."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Android") {
                if workspace.hasAndroidInjectionTarget {
                    TextField("Title", text: $notificationTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Body", text: $notificationBody)
                        .textFieldStyle(.roundedBorder)
                    TextField("Tag (optional)", text: $notificationTag)
                        .textFieldStyle(.roundedBorder)
                    Text(
                        "Local system notification — does not go through FCM. Use Deep Link for app entry URLs."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Post local notification") {
                        run {
                            let result = try await workspace.broadcastLocalNotification(
                                title: notificationTitle,
                                body: notificationBody,
                                tag: notificationTag
                            )
                            statusMessage = result.summary(verb: "Posted")
                        }
                    }
                    .disabled(
                        isBusy
                            || notificationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || notificationBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                } else {
                    Text("Show Android and select a device to post a local notification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private func runPrimaryAction() {
        run {
            let result = try await workspace.broadcastOpenURL(
                deepLink,
                targets: effectiveDeepLinkTargets,
                alsoOpenWeb: alsoOpenWeb,
                web: web
            )
            statusMessage = result.summary(verb: "Opened")
        }
    }

    private var effectiveDeepLinkTargets: DeviceInjectionTargets {
        var resolved = targets
        if !workspace.isVisible(.android) {
            resolved.remove(.android)
        }
        if !workspace.isVisible(.iOS) {
            resolved.remove(.iOS)
        }
        return resolved
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        statusMessage = nil
        Task {
            do {
                try await work()
            } catch {
                statusMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
