import SwiftUI

struct SourceVisibilityButton: View {
    @ObservedObject var workspace: WorkspaceStore
    let source: ViewerSource

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { workspace.isVisible(source) },
                set: { workspace.setVisible($0, for: source) }
            )
        ) {
            Image(systemName: source.systemImage)
                .frame(width: 16, height: 16)
        }
        .toggleStyle(.button)
        .tint(source.accentColor)
        .controlSize(.small)
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
