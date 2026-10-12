import SwiftUI

struct WorkspaceCommandActions {
    let refreshAll: () -> Void
    let clearCookies: () -> Void
    let clearAllWebsiteData: () -> Void
    let openLink: () -> Void
    let toggleInspector: () -> Void
    let openInspectorTab: (InspectorTab) -> Void
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
    var workspaceCommandActions: WorkspaceCommandActions? {
        get { self[WorkspaceCommandActionsKey.self] }
        set { self[WorkspaceCommandActionsKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommandActions)
    private var actions

    var body: some Commands {
        CommandMenu("Sources") {
            Button("Refresh all clients") {
                actions?.refreshAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Clear web cookies") {
                actions?.clearCookies()
            }
            .disabled(actions == nil)

            Button("Clear all website data") {
                actions?.clearAllWebsiteData()
            }
            .disabled(actions == nil)

            Divider()

            Button("Open Link…") {
                actions?.openLink()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandMenu("Inspect") {
            Button("Show or Hide Inspector") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)

            Divider()

            ForEach(InspectorTab.allCases) { tab in
                Button(tab.title) {
                    actions?.openInspectorTab(tab)
                }
                .disabled(actions == nil)
            }
        }
    }
}
