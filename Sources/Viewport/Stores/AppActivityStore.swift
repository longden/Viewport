import Combine
import Foundation

/// Tracks operations which must finish before an updater may replace the app.
@MainActor
final class AppActivityStore: ObservableObject {
    enum Activity: String {
        case recording = "recording"
        case savingRecording = "saving a recording"
        case build = "Build & Play"
    }

    @Published private(set) var activities: [UUID: Activity] = [:]
    @Published private(set) var isTerminating = false

    var isBusy: Bool { !activities.isEmpty }
    var busyDescription: String {
        Set(activities.values.map(\.rawValue)).sorted().joined(separator: " and ")
    }

    func begin(_ activity: Activity) throws -> UUID {
        guard !isTerminating else {
            throw NSError(
                domain: "Viewport.Activity", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Viewport is preparing to close. Try again after cancelling the update or quit."]
            )
        }
        let token = UUID()
        activities[token] = activity
        return token
    }

    func update(_ token: UUID, to activity: Activity) {
        guard activities[token] != nil else { return }
        activities[token] = activity
    }

    func end(_ token: UUID) {
        activities.removeValue(forKey: token)
    }

    @discardableResult
    func reserveTermination(allowRecording: Bool = false) -> Bool {
        guard activities.values.allSatisfy({ allowRecording && $0 == .recording }) else {
            return false
        }
        isTerminating = true
        return true
    }

    func cancelTermination() {
        isTerminating = false
    }
}
