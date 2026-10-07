import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published private(set) var hasPendingInstallation = false
    @Published private(set) var isUpdaterStarted = false

    let configuration: UpdateConfiguration
    private let activity: AppActivityStore
    private let installation: UpdateInstallationCoordinator
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []

    init(activity: AppActivityStore, configuration: UpdateConfiguration = .current) {
        self.activity = activity
        installation = UpdateInstallationCoordinator(activity: activity)
        self.configuration = configuration
        super.init()
        installation.$hasPendingInstallation
            .sink { [weak self] in self?.hasPendingInstallation = $0 }
            .store(in: &subscriptions)
    }

    /// Called after the first-launch setup sheet has finished.
    func start() {
        guard configuration.isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
        controller.startUpdater()
        isUpdaterStarted = true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func installPendingUpdate() {
        guard installation.hasPendingInstallation, !activity.isTerminating else { return }
        guard installation.resume() else {
            showBusyAlert()
            return
        }
    }

    func terminationCancelled() {
        installation.cancelTermination()
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        installation.postpone(installHandler)
        // Return to Sparkle before alerting or invoking its continuation.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if activity.isBusy {
                showBusyAlert()
            } else {
                installPendingUpdate()
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearInstallation()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        clearInstallation()
    }

    private func clearInstallation() {
        installation.clear()
    }

    private func showBusyAlert() {
        BusyActivityAlert.present(
            activity,
            verb: "updating",
            instruction: "When it finishes, choose Install Update and Restart from the Viewport menu or Updates window."
        )
    }
}
