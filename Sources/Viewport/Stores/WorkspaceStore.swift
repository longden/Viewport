import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    let androidCapture = WindowCaptureSession(source: .android)
    let iOSCapture = WindowCaptureSession(source: .iOS)
    let androidDevices: DeviceManager
    let iOSDevices: DeviceManager

    @Published private(set) var visibleSources: Set<ViewerSource>
    @Published private(set) var paneWeights: [ViewerSource: Double]
    @Published private(set) var performanceProfile: CapturePerformanceProfile
    @Published private(set) var captureMode: CaptureMode
    @Published private(set) var highFrameRateCaptureAvailable: Bool

    private let defaults: UserDefaults
    private let visibleSourcesKey: String
    private let paneWeightsKey: String
    private let performanceProfileKey: String
    private let captureModeKey: String
    private var captureRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        visibleSourcesKey: String = "visibleSources",
        paneWeightsKey: String = "paneWeights",
        performanceProfileKey: String = "capturePerformanceProfile",
        captureModeKey: String = "captureMode",
        androidClient: any DeviceClient = AndroidDeviceClient(),
        iOSClient: any DeviceClient = IOSSimulatorClient()
    ) {
        self.defaults = defaults
        self.visibleSourcesKey = visibleSourcesKey
        self.paneWeightsKey = paneWeightsKey
        self.performanceProfileKey = performanceProfileKey
        self.captureModeKey = captureModeKey
        androidDevices = DeviceManager(client: androidClient)
        iOSDevices = DeviceManager(client: iOSClient)

        let restored = defaults.stringArray(forKey: visibleSourcesKey)?
            .compactMap(ViewerSource.init(rawValue:))
        let restoredVisibility = Set(restored ?? ViewerSource.allCases)
        visibleSources = restoredVisibility.isEmpty
            ? Set(ViewerSource.allCases)
            : restoredVisibility

        let restoredWeights = defaults.dictionary(forKey: paneWeightsKey)
        paneWeights = Dictionary(uniqueKeysWithValues: ViewerSource.allCases.map {
            source in
            let value = restoredWeights?[source.rawValue] as? Double
            return (source, max(value ?? 1, 0.01))
        })

        performanceProfile = defaults.string(forKey: performanceProfileKey)
            .flatMap(CapturePerformanceProfile.init(rawValue:))
            ?? .smooth
        captureMode = defaults.string(forKey: captureModeKey)
            .flatMap(CaptureMode.init(rawValue:))
            ?? .direct
        highFrameRateCaptureAvailable = CGPreflightScreenCaptureAccess()

        androidCapture.setPerformanceProfile(performanceProfile)
        iOSCapture.setPerformanceProfile(performanceProfile)
        androidCapture.setCaptureMode(captureMode)
        iOSCapture.setCaptureMode(captureMode)
    }

    deinit {
        captureRefreshTask?.cancel()
    }

    var orderedVisibleSources: [ViewerSource] {
        ViewerSource.allCases.filter(visibleSources.contains)
    }

    func isVisible(_ source: ViewerSource) -> Bool {
        visibleSources.contains(source)
    }

    func toggle(_ source: ViewerSource) {
        setVisible(!isVisible(source), for: source)
    }

    func paneWeight(for source: ViewerSource) -> Double {
        paneWeights[source] ?? 1
    }

    func resizePanes(
        leading: ViewerSource,
        leadingWeight: Double,
        trailing: ViewerSource,
        trailingWeight: Double,
        persist: Bool
    ) {
        paneWeights[leading] = max(leadingWeight, 0.01)
        paneWeights[trailing] = max(trailingWeight, 0.01)
        if persist {
            persistPaneWeights()
        }
    }

    func persistPaneWeights() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: paneWeights.map {
                ($0.key.rawValue, $0.value)
            }),
            forKey: paneWeightsKey
        )
    }

    func setPerformanceProfile(_ profile: CapturePerformanceProfile) {
        guard performanceProfile != profile else { return }
        performanceProfile = profile
        defaults.set(profile.rawValue, forKey: performanceProfileKey)
        androidCapture.setPerformanceProfile(profile)
        iOSCapture.setPerformanceProfile(profile)
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard captureMode != mode else { return }
        captureMode = mode
        defaults.set(mode.rawValue, forKey: captureModeKey)
        androidCapture.setCaptureMode(mode)
        iOSCapture.setCaptureMode(mode)
        refreshCaptures()
    }

    func requestHighFrameRateCapture() {
        if CGPreflightScreenCaptureAccess() {
            highFrameRateCaptureAvailable = true
            refreshCaptures()
            return
        }

        // Open Settings first. After ad-hoc rebuilds macOS often keeps a stale
        // enabled "Viewport" row for an old code identity; the live binary still
        // needs a fresh grant (toggle off/on, or enable a second Viewport row).
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }

        highFrameRateCaptureAvailable = CGRequestScreenCaptureAccess()
        if highFrameRateCaptureAvailable {
            refreshCaptures()
        }
    }

    func refreshHighFrameRateCaptureAvailability() {
        let wasAvailable = highFrameRateCaptureAvailable
        highFrameRateCaptureAvailable = CGPreflightScreenCaptureAccess()
        if highFrameRateCaptureAvailable && !wasAvailable {
            refreshCaptures()
        }
    }

    func setVisible(_ isVisible: Bool, for source: ViewerSource) {
        if isVisible {
            visibleSources.insert(source)
            captureSession(for: source)?.refreshWindows()
        } else {
            guard visibleSources.count > 1 else { return }
            visibleSources.remove(source)
            captureSession(for: source)?.stopCapture()
        }

        persistVisibleSources()
    }

    func refreshCaptures() {
        highFrameRateCaptureAvailable = CGPreflightScreenCaptureAccess()
        androidCapture.refreshInputAccess()
        iOSCapture.refreshInputAccess()

        if isVisible(.android) {
            androidCapture.refreshWindows()
        }
        if isVisible(.iOS) {
            iOSCapture.refreshWindows()
        }
    }

    func refreshDevices() {
        androidDevices.refreshDevices()
        iOSDevices.refreshDevices()
    }

    func refreshAll() {
        refreshDevices()
        refreshCaptures()
    }

    func reconnectAfterDeviceLaunch() {
        captureRefreshTask?.cancel()
        captureRefreshTask = Task { [weak self] in
            for delay in [0.5, 1.5, 3.0, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.refreshCaptures()
            }
        }
    }

    func stopCaptures() {
        captureRefreshTask?.cancel()
        androidCapture.stopCapture()
        iOSCapture.stopCapture()
    }

    private func captureSession(
        for source: ViewerSource
    ) -> WindowCaptureSession? {
        switch source {
        case .web:
            nil
        case .android:
            androidCapture
        case .iOS:
            iOSCapture
        }
    }

    private func persistVisibleSources() {
        defaults.set(
            orderedVisibleSources.map(\.rawValue),
            forKey: visibleSourcesKey
        )
    }
}
