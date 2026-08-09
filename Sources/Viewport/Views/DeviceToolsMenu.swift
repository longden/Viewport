import SwiftUI

/// Compare-workflow tools: appearance, font scale, status bars, and optional
/// experimental compare helpers.
struct DeviceToolsMenu: View {
    @ObservedObject var workspace: WorkspaceStore
    @Binding var showInjector: Bool
    @Binding var showLocation: Bool
    @Binding var showNetworkOverlay: Bool
    @Binding var showOverlayDiff: Bool
    @Binding var showBatchSnapshots: Bool
    @Binding var showInteractionMacros: Bool
    @Binding var showBuildPlay: Bool
    @State private var isBusy = false
    @State private var statusMessage: String?

    var body: some View {
        Menu {
            Section("Build") {
                Button("Build & Play…") {
                    showBuildPlay = true
                }
            }

            Section("Appearance") {
                ForEach(DeviceAppearance.allCases) { appearance in
                    Button("\(appearance.title) on all devices") {
                        run {
                            try await workspace.broadcastAppearance(appearance)
                        }
                    }
                    .disabled(isBusy)
                }
            }

            Section("Font scale (Android)") {
                ForEach(DeviceFontScale.allCases) { scale in
                    Button(scale.title) {
                        run {
                            try await workspace.broadcastFontScale(scale)
                        }
                    }
                    .disabled(isBusy)
                }
            }

            Section("Status bar") {
                Button("Clean status bars") {
                    run {
                        try await workspace.broadcastCleanStatusBar()
                    }
                }
                .disabled(isBusy)
                Button("Clear status bar overrides") {
                    run {
                        try await workspace.broadcastClearStatusBar()
                    }
                }
                .disabled(isBusy)
            }

            Section("Clipboard") {
                Button("Paste Mac clipboard to devices") {
                    run {
                        try await workspace.pasteClipboardToFocusedDevice()
                    }
                }
                .disabled(isBusy)

                Button("Copy from Android") {
                    run {
                        _ = try await workspace.copyClipboardFromDevice(source: .android)
                    }
                }
                .disabled(isBusy || !workspace.hasAndroidInjectionTarget)

                Button("Copy from iOS") {
                    run {
                        _ = try await workspace.copyClipboardFromDevice(source: .iOS)
                    }
                }
                .disabled(isBusy || !workspace.hasIOSSimulatorInjectionTarget)
            }

            Section("Location") {
                Button("Set location…") {
                    showLocation = true
                }
            }

            Section("Inject") {
                Button("Open URL & Push…") {
                    showInjector = true
                }
            }

            Section("Compare") {
                Toggle(
                    "Mirror input across devices",
                    isOn: Binding(
                        get: { workspace.inputMirroringEnabled },
                        set: { workspace.setInputMirroringEnabled($0) }
                    )
                )
                .help(
                    "Replay taps and scrolls from any device pane onto every other visible device pane."
                )

                Button("Interaction macros…") {
                    showInteractionMacros = true
                }
            }

            if workspace.experimentalFeaturesEnabled {
                Section("Experimental") {
                    Toggle("Web network overlay", isOn: $showNetworkOverlay)

                    Button("Onion-skin overlay…") {
                        showOverlayDiff = true
                    }

                    Button("Batch URL snapshots…") {
                        showBatchSnapshots = true
                    }

                    Toggle(
                        "Synchronized scrolling (prototype)",
                        isOn: Binding(
                            get: { workspace.synchronizedScrollingEnabled },
                            set: { workspace.setSynchronizedScrollingEnabled($0) }
                        )
                    )
                    .help(
                        "Prototype: enables input mirroring and continuously nudges the web pane while device swipes move (web pane must be visible)."
                    )
                }
            }

            if let statusMessage {
                Divider()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        } label: {
            Label("Device tools", systemImage: "wrench.and.screwdriver")
        }
        .help("Appearance, status bars, inject, compare tools, and optional experimental helpers")
        .disabled(isBusy)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        statusMessage = nil
        Task {
            do {
                try await work()
                statusMessage = "Done"
            } catch {
                statusMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
