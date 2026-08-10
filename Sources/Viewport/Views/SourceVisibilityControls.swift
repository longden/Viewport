import SwiftUI

struct PendingTerminationAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () -> Void
}

struct SourceVisibilityButton: View {
    @ObservedObject var workspace: WorkspaceStore
    let source: ViewerSource
    let onRequestConfirm: (PendingTerminationAction) -> Void

    var body: some View {
        Button {
            if workspace.isVisible(source) {
                let guests = workspace.guestsToTerminate(for: source)
                if let guest = guests.first {
                    let title = guest.kind == .iOSSimulator
                        ? "Shut down Simulator?"
                        : "Shut down emulator?"
                    let message = "Hiding \(source.title) will shut down \(guest.name)."
                    onRequestConfirm(
                        PendingTerminationAction(
                            title: title,
                            message: message,
                            action: { workspace.setVisible(false, for: source) }
                        )
                    )
                    return
                }
            }
            workspace.toggle(source)
        } label: {
            Label(
                "\(workspace.isVisible(source) ? "Hide" : "Show") \(source.title)",
                systemImage: source.systemImage
            )
            .labelStyle(.iconOnly)
            .symbolVariant(workspace.isVisible(source) ? .fill : .none)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .foregroundStyle(
            workspace.isVisible(source)
                ? source.accentColor
                : Color.secondary
        )
        .disabled(
            workspace.orderedVisiblePanes.count == 1
                && workspace.isVisible(source)
        )
        .help(
            "\(workspace.isVisible(source) ? "Hide" : "Show") \(source.title)"
        )
        .accessibilityLabel(
            "\(workspace.isVisible(source) ? "Hide" : "Show") \(source.title)"
        )
    }
}

struct SourceVisibilityControls: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var pendingConfirm: PendingTerminationAction?

    var body: some View {
        HStack(spacing: 6) {
            ControlGroup {
                ForEach(ViewerSource.allCases) { source in
                    SourceVisibilityButton(
                        workspace: workspace,
                        source: source,
                        onRequestConfirm: { pendingConfirm = $0 }
                    )
                }
            }
            .controlSize(.regular)
            .fixedSize()

            Menu {
                Section("Add pane") {
                    Button("Add Android pane") {
                        _ = workspace.addPane(.android)
                    }
                    .disabled(!workspace.canAddPane(.android))

                    Button("Add iOS pane") {
                        _ = workspace.addPane(.iOS)
                    }
                    .disabled(!workspace.canAddPane(.iOS))
                }

                Section("Remove extra") {
                    Button("Remove extra Android pane") {
                        requestRemoveExtra(.android)
                    }
                    .disabled(workspace.paneCount(of: .android) < 2)

                    Button("Remove extra iOS pane") {
                        requestRemoveExtra(.iOS)
                    }
                    .disabled(workspace.paneCount(of: .iOS) < 2)
                }
            } label: {
                Label("Panes", systemImage: "rectangle.split.3x1")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .help(
                "Add a second Android or iOS pane (max \(PaneGridLayout.maximumPaneCount) panes)"
            )
            .accessibilityLabel("Manage panes")
        }
        .padding(.trailing, 10)
        .accessibilityLabel("Visible sources")
        .alert(
            pendingConfirm?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { if !$0 { pendingConfirm = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingConfirm = nil
            }
            Button("Shut Down & Close", role: .destructive) {
                pendingConfirm?.action()
                pendingConfirm = nil
            }
        } message: {
            Text(pendingConfirm?.message ?? "")
        }
    }

    private func requestRemoveExtra(_ source: ViewerSource) {
        if let guest = workspace.guestToTerminate(forExtraPane: source) {
            let title = guest.kind == .iOSSimulator
                ? "Shut down Simulator?"
                : "Shut down emulator?"
            let message = "Removing this pane will shut down \(guest.name)."
            pendingConfirm = PendingTerminationAction(
                title: title,
                message: message,
                action: { _ = workspace.removeExtraPane(source) }
            )
        } else {
            _ = workspace.removeExtraPane(source)
        }
    }
}
