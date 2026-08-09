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
            workspace.visibleSources.count == 1
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
        .padding(.trailing, 10)
        .accessibilityLabel("Visible sources")
    }
}
