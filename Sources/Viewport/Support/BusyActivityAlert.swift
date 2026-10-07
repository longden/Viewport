import AppKit

/// The "finish your current work" alert shared by the quit flow and the updater.
enum BusyActivityAlert {
    @MainActor
    static func present(_ activity: AppActivityStore, verb: String, instruction: String) {
        let alert = NSAlert()
        alert.messageText = "Finish your current work before \(verb)"
        alert.informativeText = "Viewport is busy with \(activity.busyDescription). \(instruction)"
        alert.runModal()
    }
}
