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

    private let defaults: UserDefaults
    private let visibleSourcesKey: String
    private var captureRefreshTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        visibleSourcesKey: String = "visibleSources",
        androidClient: any DeviceClient = AndroidDeviceClient(),
        iOSClient: any DeviceClient = IOSSimulatorClient()
    ) {
        self.defaults = defaults
        self.visibleSourcesKey = visibleSourcesKey
        androidDevices = DeviceManager(client: androidClient)
        iOSDevices = DeviceManager(client: iOSClient)

        let restored = defaults.stringArray(forKey: visibleSourcesKey)?
            .compactMap(ViewerSource.init(rawValue:))
        visibleSources = Set(restored ?? ViewerSource.allCases)

        if visibleSources.isEmpty {
            visibleSources = Set(ViewerSource.allCases)
        }
    }

    deinit {
        captureRefreshTask?.cancel()
        permissionRefreshTask?.cancel()
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

    func requestScreenRecordingAccess() {
        if CGRequestScreenCaptureAccess() {
            refreshCaptures()
            return
        }

        refreshCaptures()

        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }

    func recheckScreenRecordingAccess() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.refreshCaptures()
        }
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
        permissionRefreshTask?.cancel()
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
