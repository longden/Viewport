import SwiftUI

struct UpdateCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            // One entry: the Updates window checks on open and offers install.
            Button("Check for Updates…") {
                openWindow(id: "updates")
            }
            Divider()
        }
    }
}
