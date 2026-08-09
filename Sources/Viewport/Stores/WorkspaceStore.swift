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
    @Published private(set) var recordingQuality: RecordingQuality
    @Published private(set) var captureMode: CaptureMode
    @Published private(set) var screenshotPlatformLabelsEnabled: Bool
    @Published private(set) var highFrameRateCaptureAvailable: Bool
    @Published private(set) var inputMirroringEnabled: Bool
    @Published private(set) var synchronizedScrollingEnabled: Bool
    @Published private(set) var perfHUDEnabled: Bool
    /// When off (default), unfinished tools stay hidden from the Settings menu.
    @Published private(set) var experimentalFeaturesEnabled: Bool
    @Published private(set) var recentDeepLinks: [String]
    @Published private(set) var lastPushBundleID: String
    @Published private(set) var lastPushPayloadJSON: String

    private let defaults: UserDefaults
    private let visibleSourcesKey: String
    private let paneWeightsKey: String
    private let performanceProfileKey: String
    private let recordingQualityKey: String
    private let captureModeKey: String
    private let screenshotPlatformLabelsKey: String
    private let inputMirroringKey: String
    private let synchronizedScrollingKey: String
    private let perfHUDKey: String
    private let experimentalFeaturesKey: String
    private let recentDeepLinksKey: String
    private let lastPushBundleIDKey: String
    private let lastPushPayloadJSONKey: String
    private let automation = DeviceAutomationService()
    private var captureRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        visibleSourcesKey: String = "visibleSources",
        paneWeightsKey: String = "paneWeights",
        performanceProfileKey: String = "capturePerformanceProfile",
        recordingQualityKey: String = "recordingQuality",
        captureModeKey: String = "captureMode",
        screenshotPlatformLabelsKey: String = "screenshotPlatformLabelsEnabled",
        inputMirroringKey: String = "inputMirroringEnabled",
        synchronizedScrollingKey: String = "synchronizedScrollingEnabled",
        perfHUDKey: String = "perfHUDEnabled",
        experimentalFeaturesKey: String = "experimentalFeaturesEnabled",
        recentDeepLinksKey: String = "recentDeepLinks",
        lastPushBundleIDKey: String = "lastPushBundleID",
        lastPushPayloadJSONKey: String = "lastPushPayloadJSON",
        androidClient: any DeviceClient = AndroidDeviceClient(),
        iOSClient: any DeviceClient = IOSSimulatorClient()
    ) {
        self.defaults = defaults
        self.visibleSourcesKey = visibleSourcesKey
        self.paneWeightsKey = paneWeightsKey
        self.performanceProfileKey = performanceProfileKey
        self.recordingQualityKey = recordingQualityKey
        self.captureModeKey = captureModeKey
        self.screenshotPlatformLabelsKey = screenshotPlatformLabelsKey
        self.inputMirroringKey = inputMirroringKey
        self.synchronizedScrollingKey = synchronizedScrollingKey
        self.perfHUDKey = perfHUDKey
        self.experimentalFeaturesKey = experimentalFeaturesKey
        self.recentDeepLinksKey = recentDeepLinksKey
        self.lastPushBundleIDKey = lastPushBundleIDKey
        self.lastPushPayloadJSONKey = lastPushPayloadJSONKey
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
        recordingQuality = defaults.string(forKey: recordingQualityKey)
            .flatMap(RecordingQuality.init(rawValue:))
            ?? .high
        captureMode = defaults.string(forKey: captureModeKey)
            .flatMap(CaptureMode.init(rawValue:))
            ?? .direct
        screenshotPlatformLabelsEnabled = defaults.object(
            forKey: screenshotPlatformLabelsKey
        ) as? Bool ?? false
        highFrameRateCaptureAvailable = CGPreflightScreenCaptureAccess()
        inputMirroringEnabled = defaults.object(forKey: inputMirroringKey)
            as? Bool ?? false
        synchronizedScrollingEnabled = defaults.object(
            forKey: synchronizedScrollingKey
        ) as? Bool ?? false
        perfHUDEnabled = defaults.object(forKey: perfHUDKey) as? Bool ?? false
        experimentalFeaturesEnabled = defaults.object(
            forKey: experimentalFeaturesKey
        ) as? Bool ?? false
        recentDeepLinks = defaults.stringArray(forKey: recentDeepLinksKey) ?? []
        lastPushBundleID = defaults.string(forKey: lastPushBundleIDKey) ?? ""
        lastPushPayloadJSON = defaults.string(forKey: lastPushPayloadJSONKey)
            ?? DeviceAutomationService.defaultAPNsPayloadJSON

        // Experimental-gated prototypes must not stay active when the gate is off,
        // even if older defaults left mirroring/sync flags set.
        if !experimentalFeaturesEnabled {
            if inputMirroringEnabled {
                inputMirroringEnabled = false
                defaults.set(false, forKey: inputMirroringKey)
            }
            if synchronizedScrollingEnabled {
                synchronizedScrollingEnabled = false
                defaults.set(false, forKey: synchronizedScrollingKey)
            }
        }

        androidCapture.setPerformanceProfile(performanceProfile)
        iOSCapture.setPerformanceProfile(performanceProfile)
        androidCapture.setCaptureMode(captureMode)
        iOSCapture.setCaptureMode(captureMode)
        configureInputMirroring()
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
        var updatedWeights = paneWeights
        updatedWeights[leading] = max(leadingWeight, 0.01)
        updatedWeights[trailing] = max(trailingWeight, 0.01)
        paneWeights = updatedWeights
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

    func setRecordingQuality(_ quality: RecordingQuality) {
        guard recordingQuality != quality else { return }
        recordingQuality = quality
        defaults.set(quality.rawValue, forKey: recordingQualityKey)
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard captureMode != mode else { return }
        captureMode = mode
        defaults.set(mode.rawValue, forKey: captureModeKey)
        androidCapture.setCaptureMode(mode)
        iOSCapture.setCaptureMode(mode)
        refreshCaptures()
    }

    func setScreenshotPlatformLabelsEnabled(_ isEnabled: Bool) {
        guard screenshotPlatformLabelsEnabled != isEnabled else { return }
        screenshotPlatformLabelsEnabled = isEnabled
        defaults.set(isEnabled, forKey: screenshotPlatformLabelsKey)
    }

    func setInputMirroringEnabled(_ isEnabled: Bool) {
        guard inputMirroringEnabled != isEnabled else { return }
        inputMirroringEnabled = isEnabled
        defaults.set(isEnabled, forKey: inputMirroringKey)
        configureInputMirroring()
    }

    /// Prototype: enables device↔device input mirroring and optional web scroll nudges.
    func setSynchronizedScrollingEnabled(_ isEnabled: Bool) {
        guard synchronizedScrollingEnabled != isEnabled else { return }
        synchronizedScrollingEnabled = isEnabled
        defaults.set(isEnabled, forKey: synchronizedScrollingKey)
        if isEnabled, !inputMirroringEnabled {
            setInputMirroringEnabled(true)
        }
    }

    func setPerfHUDEnabled(_ isEnabled: Bool) {
        guard perfHUDEnabled != isEnabled else { return }
        perfHUDEnabled = isEnabled
        defaults.set(isEnabled, forKey: perfHUDKey)
    }

    func setExperimentalFeaturesEnabled(_ isEnabled: Bool) {
        guard experimentalFeaturesEnabled != isEnabled else { return }
        experimentalFeaturesEnabled = isEnabled
        defaults.set(isEnabled, forKey: experimentalFeaturesKey)
        if !isEnabled {
            setSynchronizedScrollingEnabled(false)
            setInputMirroringEnabled(false)
        }
    }

    func broadcastOpenURL(_ rawURL: String) async throws {
        _ = try await broadcastOpenURL(
            rawURL,
            targets: .both,
            alsoOpenWeb: false,
            web: nil
        )
    }

    @discardableResult
    func broadcastOpenURL(
        _ rawURL: String,
        targets: DeviceInjectionTargets,
        alsoOpenWeb: Bool,
        web: WebViewModel?
    ) async throws -> DeviceInjectionResult {
        guard let normalized = DeviceAutomationService.normalizedURL(rawURL) else {
            throw DeviceAutomationError.commandFailed("Enter a valid URL.")
        }

        var result = DeviceInjectionResult()
        let devices = selectedCaptureDevices(matching: targets)
        if devices.isEmpty && !(alsoOpenWeb && isVisible(.web) && web != nil) {
            throw DeviceAutomationError.noTarget(
                missingTargetMessage(for: targets)
            )
        }

        for device in devices {
            do {
                try await automation.openURL(normalized, on: device)
                result.succeeded.append(device.name)
            } catch let error as DeviceAutomationError {
                if case .unsupported(let message) = error {
                    result.skipped.append(message)
                } else {
                    result.skipped.append(
                        "\(device.name): \(error.localizedDescription)"
                    )
                }
            } catch {
                result.skipped.append(
                    "\(device.name): \(error.localizedDescription)"
                )
            }
        }

        if alsoOpenWeb, isVisible(.web), let web {
            web.address = normalized
            web.loadAddress()
            result.succeeded.append("Web")
        }

        rememberDeepLink(normalized)

        if !result.didSucceed {
            if let firstSkip = result.skipped.first {
                throw DeviceAutomationError.commandFailed(firstSkip)
            }
            throw DeviceAutomationError.noTarget(
                missingTargetMessage(for: targets)
            )
        }
        return result
    }

    @discardableResult
    func broadcastPush(
        payloadJSON: String,
        bundleID: String
    ) async throws -> DeviceInjectionResult {
        let devices = selectedCaptureDevices(matching: .iOS)
            .filter { $0.kind == .iOSSimulator }
        guard !devices.isEmpty else {
            throw DeviceAutomationError.noTarget(
                "Show iOS and select a Simulator. Push injection does not work on physical iPhones."
            )
        }

        var result = DeviceInjectionResult()
        for device in devices {
            do {
                try await automation.sendPush(
                    payloadJSON: payloadJSON,
                    bundleID: bundleID,
                    on: device
                )
                result.succeeded.append(device.name)
            } catch let error as DeviceAutomationError {
                if case .unsupported(let message) = error {
                    result.skipped.append(message)
                } else {
                    throw error
                }
            }
        }

        if result.didSucceed {
            setLastPushBundleID(bundleID)
            setLastPushPayloadJSON(payloadJSON)
        }

        if !result.didSucceed {
            if let firstSkip = result.skipped.first {
                throw DeviceAutomationError.commandFailed(firstSkip)
            }
            throw DeviceAutomationError.noTarget(
                "Show iOS and select a Simulator. Push injection does not work on physical iPhones."
            )
        }
        return result
    }

    @discardableResult
    func broadcastLocalNotification(
        title: String,
        body: String,
        tag: String
    ) async throws -> DeviceInjectionResult {
        let devices = selectedCaptureDevices(matching: .android)
        guard !devices.isEmpty else {
            throw DeviceAutomationError.noTarget(
                "Show Android and select a device or emulator."
            )
        }

        var result = DeviceInjectionResult()
        for device in devices {
            do {
                try await automation.postLocalNotification(
                    title: title,
                    body: body,
                    tag: tag,
                    on: device
                )
                result.succeeded.append(device.name)
            } catch {
                result.skipped.append(
                    "\(device.name): \(error.localizedDescription)"
                )
            }
        }

        if !result.didSucceed {
            if let firstSkip = result.skipped.first {
                throw DeviceAutomationError.commandFailed(firstSkip)
            }
            throw DeviceAutomationError.noTarget(
                "Show Android and select a device or emulator."
            )
        }
        return result
    }

    func setLastPushBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPushBundleID = trimmed
        defaults.set(trimmed, forKey: lastPushBundleIDKey)
    }

    func setLastPushPayloadJSON(_ json: String) {
        lastPushPayloadJSON = json
        defaults.set(json, forKey: lastPushPayloadJSONKey)
    }

    var hasAndroidInjectionTarget: Bool {
        isVisible(.android) && androidCapture.selectedDevice != nil
    }

    var hasIOSSimulatorInjectionTarget: Bool {
        isVisible(.iOS) && iOSCapture.selectedDevice?.kind == .iOSSimulator
    }

    var hasPhysicalIOSSelected: Bool {
        isVisible(.iOS) && iOSCapture.selectedDevice?.kind == .iOSDevice
    }

    func broadcastAppearance(_ appearance: DeviceAppearance) async throws {
        try await broadcast { try await automation.setAppearance(appearance, on: $0) }
    }

    func broadcastFontScale(_ scale: DeviceFontScale) async throws {
        try await broadcast { try await automation.setFontScale(scale, on: $0) }
    }

    func broadcastCleanStatusBar() async throws {
        try await broadcast { try await automation.applyCleanStatusBar(on: $0) }
    }

    func broadcastClearStatusBar() async throws {
        try await broadcast { try await automation.clearStatusBar(on: $0) }
    }

    private func rememberDeepLink(_ url: String) {
        var updated = recentDeepLinks.filter { $0 != url }
        updated.insert(url, at: 0)
        if updated.count > 8 {
            updated = Array(updated.prefix(8))
        }
        recentDeepLinks = updated
        defaults.set(updated, forKey: recentDeepLinksKey)
    }

    private func missingTargetMessage(
        for targets: DeviceInjectionTargets
    ) -> String {
        switch targets {
        case .android:
            "Show Android and select a device or emulator."
        case .iOS:
            "Show iOS and select a Simulator (or device for view-only)."
        default:
            "Show Android and/or iOS and select a device in each pane."
        }
    }

    private func broadcast(
        _ work: (StreamedDevice) async throws -> Void
    ) async throws {
        let devices = selectedCaptureDevices()
        guard !devices.isEmpty else {
            throw DeviceAutomationError.noTarget()
        }
        var lastError: Error?
        var succeeded = 0
        for device in devices {
            do {
                try await work(device)
                succeeded += 1
            } catch {
                lastError = error
            }
        }
        if succeeded == 0, let lastError { throw lastError }
    }

    private func selectedCaptureDevices(
        matching targets: DeviceInjectionTargets = .both
    ) -> [StreamedDevice] {
        var devices: [StreamedDevice] = []
        if targets.contains(.android),
           isVisible(.android),
           let device = androidCapture.selectedDevice {
            devices.append(device)
        }
        if targets.contains(.iOS),
           isVisible(.iOS),
           let device = iOSCapture.selectedDevice {
            devices.append(device)
        }
        return devices
    }

    private func configureInputMirroring() {
        if inputMirroringEnabled {
            androidCapture.mirrorTarget = iOSCapture
            iOSCapture.mirrorTarget = androidCapture
        } else {
            androidCapture.mirrorTarget = nil
            iOSCapture.mirrorTarget = nil
        }
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
