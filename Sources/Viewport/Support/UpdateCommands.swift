import SwiftUI

struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateController
    @ObservedObject var activity: AppActivityStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            Section("Updates") {
                Button("Updates…") {
                    openWindow(id: "updates")
                }
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)

                if updates.hasPendingInstallation {
                    Button("Install Update and Restart") {
                        updates.installPendingUpdate()
                    }
                    .disabled(activity.isBusy || activity.isTerminating)
                }
            }
            Divider()
        }
    }
}
