import AppKit
import SwiftUI

@main
struct ViewportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Viewport", id: "workspace") {
            ContentView(workspace: appDelegate.workspace)
                .frame(minWidth: 760, minHeight: 620)
                .background(WindowChromeConfigurator())
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            WorkspaceCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    private var workspaceStorage: WorkspaceStore?
    private var isWaitingForGuestShutdown = false
    private var hasConfirmedClose = false

    @MainActor
    var workspace: WorkspaceStore {
        if let workspaceStorage {
            return workspaceStorage
        }
        let store = WorkspaceStore()
        workspaceStorage = store
        return store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if isWaitingForGuestShutdown {
            return .terminateNow
        }
        guard confirmClosingWorkspace() else {
            return .terminateCancel
        }
        isWaitingForGuestShutdown = true
        Task { @MainActor in
            await Self.shutDownSessionGuests(
                workspace: self.workspaceStorage
            )
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Returns `true` when the window / app may close. Shows a confirmation if
    /// Simulators or emulators are still running.
    func confirmClosingWorkspace() -> Bool {
        if hasConfirmedClose || isWaitingForGuestShutdown {
            return true
        }
        let prompt = MainActor.assumeIsolated {
            workspaceStorage?.sessionGuestClosePrompt
        }
        guard let prompt else {
            hasConfirmedClose = true
            return true
        }

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed {
            hasConfirmedClose = true
        }
        return confirmed
    }

    @MainActor
    private static func shutDownSessionGuests(workspace: WorkspaceStore?) async {
        guard let workspace else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await workspace.terminateSessionStartedGuests()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

/// Flattens the titlebar/content seam so the toolbar and workspace share one
/// window surface (no separator shadow, no second background plate).
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeHostView {
        ChromeHostView()
    }

    func updateNSView(_ nsView: ChromeHostView, context: Context) {}
}

private final class ChromeHostView: NSView, NSWindowDelegate {
    private weak var previousWindowDelegate: NSWindowDelegate?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        installCloseConfirmation(on: window)
    }

    private func installCloseConfirmation(on window: NSWindow) {
        guard window.delegate !== self else { return }
        previousWindowDelegate = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let previousWindowDelegate,
           previousWindowDelegate.responds(
            to: #selector(NSWindowDelegate.windowShouldClose(_:))
           ),
           previousWindowDelegate.windowShouldClose?(sender) == false {
            return false
        }
        return (NSApp.delegate as? AppDelegate)?.confirmClosingWorkspace() ?? true
    }

    override func responds(to aSelector: Selector) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousWindowDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector) -> Any? {
        if previousWindowDelegate?.responds(to: aSelector) == true {
            return previousWindowDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}
