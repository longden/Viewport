import Combine

@MainActor
final class UpdateInstallationCoordinator: ObservableObject {
    @Published private(set) var hasPendingInstallation = false
    private let activity: AppActivityStore
    private var installHandler: (() -> Void)?
    private var ownsTerminationReservation = false

    init(activity: AppActivityStore) {
        self.activity = activity
    }

    func postpone(_ handler: @escaping () -> Void) {
        installHandler = handler
        hasPendingInstallation = true
    }

    @discardableResult
    func resume() -> Bool {
        guard let installHandler, !activity.isTerminating,
              activity.reserveTermination() else { return false }
        ownsTerminationReservation = true
        // Retain this until Sparkle finishes/aborts, so cancelled termination can retry.
        installHandler()
        return true
    }

    func cancelTermination() {
        guard ownsTerminationReservation else { return }
        activity.cancelTermination()
        ownsTerminationReservation = false
    }

    func clear() {
        installHandler = nil
        hasPendingInstallation = false
        cancelTermination()
    }
}
