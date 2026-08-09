import SwiftUI

struct SourceVisibilityButton: View {
    @ObservedObject var workspace: WorkspaceStore
    let source: ViewerSource

    var body: some View {
        Button {
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

    var body: some View {
        HStack(spacing: 6) {
            ControlGroup {
                ForEach(ViewerSource.allCases) { source in
                    SourceVisibilityButton(
                        workspace: workspace,
                        source: source
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
                        _ = workspace.removeExtraPane(.android)
                    }
                    .disabled(workspace.paneCount(of: .android) < 2)

                    Button("Remove extra iOS pane") {
                        _ = workspace.removeExtraPane(.iOS)
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
    }
}
