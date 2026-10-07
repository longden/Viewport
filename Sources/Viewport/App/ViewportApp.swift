import AppKit
import SwiftUI

@main
struct ViewportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Viewport", id: "workspace") {
            ContentView(workspace: appDelegate.workspace, recording: appDelegate.recording)
                .environmentObject(appDelegate.updates)
                .environmentObject(appDelegate.activity)
                .frame(minWidth: 760, minHeight: 620)
                .background(WindowChromeConfigurator())
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            WorkspaceCommands()
            UpdateCommands(updates: appDelegate.updates, activity: appDelegate.activity)
        }

        Window("Viewport Updates", id: "updates") {
            UpdatesView(updates: appDelegate.updates, activity: appDelegate.activity)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceStorage: WorkspaceStore?
    private var isWaitingForGuestShutdown = false
    private var hasConfirmedClose = false
    let activity = AppActivityStore()
    lazy var recording = WorkspaceRecordingService(activity: activity)
    lazy var updates = UpdateController(activity: activity)

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
            // A repeated quit may skip the guest shutdown wait, but must not
            // abandon a recording that is still being finalised.
            return recording.isStopping ? .terminateLater : .terminateNow
        }
        guard confirmClosingWorkspace() else {
            abandonTermination()
            return .terminateCancel
        }
        let recordingDecision = recording.isRecording ? confirmRecordingBeforeQuit() : nil
        guard recordingDecision != .cancel,
              activity.reserveTermination(allowRecording: true) else {
            abandonTermination()
            return .terminateCancel
        }
        isWaitingForGuestShutdown = true
        Task { @MainActor in
            switch recordingDecision {
            case .save:
                do {
                    // A cancelled save panel discards the recording; quitting continues.
                    _ = try await self.recording.stop()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The recording could not be saved"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    self.abandonTermination()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            case .discard:
                self.recording.cancel()
            case .cancel, nil:
                break
            }
            await Self.shutDownSessionGuests(
                workspace: self.workspaceStorage
            )
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The workspace window is Viewport: closing it quits through the shared
    /// termination flow (busy checks, recording save, guest shutdown), even
    /// when the Updates window is still open.
    func requestWorkspaceWindowClose() -> Bool {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }

    private enum RecordingQuitDecision {
        case save, discard, cancel
    }

    private func confirmRecordingBeforeQuit() -> RecordingQuitDecision {
        let alert = NSAlert()
        alert.messageText = "Save the recording before quitting?"
        alert.informativeText = "Viewport is still recording. If you don’t save it, the recording will be discarded."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func abandonTermination() {
        isWaitingForGuestShutdown = false
        hasConfirmedClose = false
        activity.cancelTermination()
        updates.terminationCancelled()
    }

    /// Returns `true` when the app may quit. Blocks while non-recording work
    /// is active, and shows a confirmation if Simulators or emulators are
    /// still running. Active recordings are handled by the quit flow.
    func confirmClosingWorkspace() -> Bool {
        if activity.activities.values.contains(where: { $0 != .recording }) {
            BusyActivityAlert.present(
                activity,
                verb: "closing",
                instruction: "Stop and save recordings or finish Build & Play before closing."
            )
            return false
        }
        if hasConfirmedClose || isWaitingForGuestShutdown {
            return true
        }
        guard let prompt = workspaceStorage?.sessionGuestClosePrompt else {
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
        return (NSApp.delegate as? AppDelegate)?.requestWorkspaceWindowClose() ?? true
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
