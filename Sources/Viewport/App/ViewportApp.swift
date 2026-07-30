import AppKit
import SwiftUI

@main
struct ViewportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Viewport", id: "workspace") {
            ContentView()
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 1_620, height: 980)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            WorkspaceCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
