import SwiftUI

/// Compare-workflow tools: injector sheet, appearance, font scale, status bars.
struct DeviceToolsMenu: View {
    @ObservedObject var workspace: WorkspaceStore
    @Binding var showInjector: Bool
    @State private var isBusy = false
    @State private var statusMessage: String?

    var body: some View {
        Menu {
            Button("Open URL & Push…") {
                showInjector = true
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

            Divider()

            Toggle(
                "Mirror input across devices",
                isOn: Binding(
                    get: { workspace.inputMirroringEnabled },
                    set: { workspace.setInputMirroringEnabled($0) }
                )
            )
            .help(
                "Replay taps and scrolls from one device pane onto the other visible device pane."
            )

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
        .help("Deep links, push, appearance, status bars, and input mirroring")
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
