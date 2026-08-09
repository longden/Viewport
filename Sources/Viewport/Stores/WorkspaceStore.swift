import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    let androidCapture = WindowCaptureSession(source: .android)
    let androidCaptureSecondary = WindowCaptureSession(source: .android)
    let iOSCapture = WindowCaptureSession(source: .iOS)
    let iOSCaptureSecondary = WindowCaptureSession(source: .iOS)
    let androidDevices: DeviceManager
    let iOSDevices: DeviceManager

    @Published private(set) var visibleSources: Set<ViewerSource>
    @Published private(set) var paneWeights: [ViewerSource: Double]
    @Published private(set) var paneLayout: PaneGridLayout
    @Published private(set) var performanceProfile: CapturePerformanceProfile
    @Published private(set) var recordingQuality: RecordingQuality
    @Published private(set) var captureMode: CaptureMode
    @Published private(set) var screenshotPlatformLabelsEnabled: Bool
    @Published private(set) var deviceBezelsEnabled: Bool
    @Published private(set) var highFrameRateCaptureAvailable: Bool
    @Published private(set) var inputMirroringEnabled: Bool
    @Published private(set) var synchronizedScrollingEnabled: Bool
    @Published private(set) var perfHUDEnabled: Bool
    /// When off (default), unfinished tools stay hidden from the Settings menu.
    @Published private(set) var experimentalFeaturesEnabled: Bool
    @Published private(set) var recentDeepLinks: [String]
    @Published private(set) var lastPushBundleID: String
    @Published private(set) var lastPushPayloadJSON: String
    @Published private(set) var preferHeadlessAndroidEmulators: Bool
    @Published private(set) var locationFavorites: [DeviceLocationCoordinate]
    @Published var focusedCaptureSource: ViewerSource?
    @Published var focusedCapturePaneID: UUID?

    private let defaults: UserDefaults
    private let visibleSourcesKey: String
    private let paneWeightsKey: String
    private let paneLayoutKey: String
    private let performanceProfileKey: String
    private let recordingQualityKey: String
    private let captureModeKey: String
    private let screenshotPlatformLabelsKey: String
    private let deviceBezelsKey: String
    private let inputMirroringKey: String
    private let synchronizedScrollingKey: String
    private let perfHUDKey: String
    private let experimentalFeaturesKey: String
    private let recentDeepLinksKey: String
    private let lastPushBundleIDKey: String
    private let lastPushPayloadJSONKey: String
    private let preferHeadlessAndroidKey: String
    private let locationFavoritesKey: String
    private let automation = DeviceAutomationService()
    private var captureRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        visibleSourcesKey: String = "visibleSources",
        paneWeightsKey: String = "paneWeights",
        paneLayoutKey: String = "paneGridLayout",
        performanceProfileKey: String = "capturePerformanceProfile",
        recordingQualityKey: String = "recordingQuality",
        captureModeKey: String = "captureMode",
        screenshotPlatformLabelsKey: String = "screenshotPlatformLabelsEnabled",
        deviceBezelsKey: String = "deviceBezelsEnabled",
        inputMirroringKey: String = "inputMirroringEnabled",
        synchronizedScrollingKey: String = "synchronizedScrollingEnabled",
        perfHUDKey: String = "perfHUDEnabled",
        experimentalFeaturesKey: String = "experimentalFeaturesEnabled",
        recentDeepLinksKey: String = "recentDeepLinks",
        lastPushBundleIDKey: String = "lastPushBundleID",
        lastPushPayloadJSONKey: String = "lastPushPayloadJSON",
        preferHeadlessAndroidKey: String = AndroidEmulatorLaunchArguments.preferHeadlessUserDefaultsKey,
        locationFavoritesKey: String = "locationFavorites",
        androidClient: (any DeviceClient)? = nil,
        iOSClient: any DeviceClient = IOSSimulatorClient()
    ) {
        self.defaults = defaults
        self.visibleSourcesKey = visibleSourcesKey
        self.paneWeightsKey = paneWeightsKey
        self.paneLayoutKey = paneLayoutKey
        self.performanceProfileKey = performanceProfileKey
        self.recordingQualityKey = recordingQualityKey
        self.captureModeKey = captureModeKey
        self.screenshotPlatformLabelsKey = screenshotPlatformLabelsKey
        self.deviceBezelsKey = deviceBezelsKey
        self.inputMirroringKey = inputMirroringKey
        self.synchronizedScrollingKey = synchronizedScrollingKey
        self.perfHUDKey = perfHUDKey
        self.experimentalFeaturesKey = experimentalFeaturesKey
        self.recentDeepLinksKey = recentDeepLinksKey
        self.lastPushBundleIDKey = lastPushBundleIDKey
        self.lastPushPayloadJSONKey = lastPushPayloadJSONKey
        self.preferHeadlessAndroidKey = preferHeadlessAndroidKey
        self.locationFavoritesKey = locationFavoritesKey
        androidDevices = DeviceManager(
            client: androidClient ?? AndroidDeviceClient(defaults: defaults)
        )
        iOSDevices = DeviceManager(client: iOSClient)

        let restoredWeights = defaults.dictionary(forKey: paneWeightsKey)
        let initialPaneWeights = Dictionary(uniqueKeysWithValues: ViewerSource.allCases.map {
            source in
            let value = restoredWeights?[source.rawValue] as? Double
            return (source, max(value ?? 1, 0.01))
        })

        let initialVisibility: Set<ViewerSource>
        let initialLayout: PaneGridLayout
        if let data = defaults.data(forKey: paneLayoutKey),
           let restoredLayout = try? JSONDecoder().decode(
            PaneGridLayout.self,
            from: data
           ),
           !restoredLayout.nodes.isEmpty {
            initialLayout = restoredLayout
            initialVisibility = Set(
                restoredLayout.nodes.compactMap(\.viewerSource)
            )
        } else {
            let restored = defaults.stringArray(forKey: visibleSourcesKey)?
                .compactMap(ViewerSource.init(rawValue:))
            let restoredVisibility = Set(restored ?? ViewerSource.allCases)
            initialVisibility = restoredVisibility.isEmpty
                ? Set(ViewerSource.allCases)
                : restoredVisibility
            initialLayout = PaneGridLayout.fromVisibleSources(
                initialVisibility,
                weights: initialPaneWeights
            )
        }
        paneWeights = initialPaneWeights
        visibleSources = initialVisibility
        paneLayout = initialLayout

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
        deviceBezelsEnabled = defaults.object(forKey: deviceBezelsKey)
            as? Bool ?? false
        highFrameRateCaptureAvailable = ScreenRecordingPermission.isGranted
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
        preferHeadlessAndroidEmulators = defaults.object(
            forKey: preferHeadlessAndroidKey
        ) as? Bool ?? true
        if let data = defaults.data(forKey: locationFavoritesKey),
           let favorites = try? JSONDecoder().decode(
            [DeviceLocationCoordinate].self,
            from: data
           ) {
            locationFavorites = favorites
        } else {
            locationFavorites = Self.defaultLocationFavorites
        }

        // Sync-scroll stays experimental; mirroring is a first-class compare tool.
        if !experimentalFeaturesEnabled, synchronizedScrollingEnabled {
            synchronizedScrollingEnabled = false
            defaults.set(false, forKey: synchronizedScrollingKey)
        }

        for session in allCaptureSessions {
            session.setPerformanceProfile(performanceProfile)
            session.setCaptureMode(captureMode)
        }
        configureSiblingDeviceAvoidance()
        configureInputMirroring()
    }

    deinit {
        captureRefreshTask?.cancel()
    }

    var orderedVisibleSources: [ViewerSource] {
        ViewerSource.allCases.filter(visibleSources.contains)
    }

    var orderedVisiblePanes: [PaneGridNode] {
        paneLayout.nodes
    }

    var allCaptureSessions: [WindowCaptureSession] {
        [androidCapture, androidCaptureSecondary, iOSCapture, iOSCaptureSecondary]
    }

    func isVisible(_ source: ViewerSource) -> Bool {
        visibleSources.contains(source)
    }

    func paneCount(of source: ViewerSource) -> Int {
        paneLayout.count(of: source)
    }

    func canAddPane(_ source: ViewerSource) -> Bool {
        paneLayout.canAddPane(source: source)
    }

    /// Selected devices in visible Android / iOS capture panes.
    func visibleSelectedDevices() -> [StreamedDevice] {
        selectedCaptureDevices()
    }

    func toggle(_ source: ViewerSource) {
        setVisible(!isVisible(source), for: source)
    }

    @discardableResult
    func addPane(_ source: ViewerSource) -> Bool {
        guard source != .web || !isVisible(.web) else { return false }
        guard canAddPane(source) else { return false }
        var layout = paneLayout
        guard layout.addPane(
            source: source,
            weight: paneWeights[source] ?? 1
        ) != nil else {
            return false
        }
        paneLayout = layout
        visibleSources.insert(source)
        // New secondary panes start empty and wait for Play / a free device.
        // Do not auto-attach the sibling's running emulator (avoids duplication).
        captureSession(for: source, slot: paneLayout.count(of: source) - 1)?
            .refreshWindows()
        configureInputMirroring()
        persistVisibleSources()
        persistPaneLayout()
        return true
    }

    @discardableResult
    func removeExtraPane(_ source: ViewerSource) -> Bool {
        guard paneCount(of: source) > 1 else { return false }
        let removedSlot = paneLayout.nodes
            .filter { $0.source == source.rawValue }
            .map(\.slot)
            .max() ?? 1
        guard let node = paneLayout.nodes.last(where: {
            $0.source == source.rawValue && $0.slot == removedSlot
        }) else {
            return false
        }
        return removePane(id: node.id)
    }

    /// Removes an extra device pane (slot ≥ 1), stops its stream, and shuts down
    /// the emulator / Simulator that was selected there.
    @discardableResult
    func removePane(id: UUID) -> Bool {
        guard let node = paneLayout.nodes.first(where: { $0.id == id }),
              node.viewerSource != nil,
              node.slot >= 1 else {
            return false
        }

        let session = captureSession(for: node)
        let deviceToStop = session?.selectedDevice
        session?.clearSelection()

        var layout = paneLayout
        layout.removePane(id: id)
        paneLayout = layout

        if focusedCapturePaneID == id {
            focusedCapturePaneID = nil
        }

        configureInputMirroring()
        persistPaneLayout()

        if let deviceToStop {
            Task { [weak self] in
                try? await self?.automation.terminateGuest(deviceToStop)
            }
        }
        return true
    }

    /// Starts an AVD / Simulator into a specific pane with a loading state,
    /// without cloning the sibling pane's live device.
    func launch(_ device: LaunchableDevice, into session: WindowCaptureSession) {
        guard device.source == session.source else { return }
        focusedCaptureSource = session.source
        session.prepareForPendingLaunch(named: device.name)
        switch device.source {
        case .android:
            androidDevices.launch(device)
        case .iOS:
            iOSDevices.launch(device)
        case .web:
            break
        }
    }

    func paneWeight(for source: ViewerSource) -> Double {
        paneWeights[source] ?? 1
    }

    func paneWeight(forPaneID id: UUID) -> Double {
        paneLayout.nodes.first { $0.id == id }?.weight ?? 1
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

        var layout = paneLayout
        if let leadingIndex = layout.nodes.firstIndex(where: {
            $0.source == leading.rawValue && $0.slot == 0
        }) {
            layout.nodes[leadingIndex].weight = max(leadingWeight, 0.01)
        }
        if let trailingIndex = layout.nodes.firstIndex(where: {
            $0.source == trailing.rawValue && $0.slot == 0
        }) {
            layout.nodes[trailingIndex].weight = max(trailingWeight, 0.01)
        }
        paneLayout = layout

        if persist {
            persistPaneWeights()
            persistPaneLayout()
        }
    }

    func resizePanes(
        leadingID: UUID,
        leadingWeight: Double,
        trailingID: UUID,
        trailingWeight: Double,
        persist: Bool
    ) {
        var layout = paneLayout
        guard let leadingIndex = layout.nodes.firstIndex(where: { $0.id == leadingID }),
              let trailingIndex = layout.nodes.firstIndex(where: { $0.id == trailingID })
        else {
            return
        }
        layout.nodes[leadingIndex].weight = max(leadingWeight, 0.01)
        layout.nodes[trailingIndex].weight = max(trailingWeight, 0.01)
        paneLayout = layout

        var nextWeights = paneWeights
        if let leadingSource = layout.nodes[leadingIndex].viewerSource {
            nextWeights[leadingSource] = layout.nodes[leadingIndex].weight
        }
        if let trailingSource = layout.nodes[trailingIndex].viewerSource {
            nextWeights[trailingSource] = layout.nodes[trailingIndex].weight
        }
        paneWeights = nextWeights

        if persist {
            persistPaneWeights()
            persistPaneLayout()
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
        for session in allCaptureSessions {
            session.setPerformanceProfile(profile)
        }
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
        for session in allCaptureSessions {
            session.setCaptureMode(mode)
        }
        refreshCaptures()
    }

    func setScreenshotPlatformLabelsEnabled(_ isEnabled: Bool) {
        guard screenshotPlatformLabelsEnabled != isEnabled else { return }
        screenshotPlatformLabelsEnabled = isEnabled
        defaults.set(isEnabled, forKey: screenshotPlatformLabelsKey)
    }

    func setDeviceBezelsEnabled(_ isEnabled: Bool) {
        guard deviceBezelsEnabled != isEnabled else { return }
        deviceBezelsEnabled = isEnabled
        defaults.set(isEnabled, forKey: deviceBezelsKey)
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
        !selectedCaptureDevices(matching: .android).isEmpty
    }

    var hasIOSSimulatorInjectionTarget: Bool {
        selectedCaptureDevices(matching: .iOS)
            .contains { $0.kind == .iOSSimulator }
    }

    var hasPhysicalIOSSelected: Bool {
        selectedCaptureDevices(matching: .iOS)
            .contains { $0.kind == .iOSDevice }
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

    func setPreferHeadlessAndroidEmulators(_ isEnabled: Bool) {
        guard preferHeadlessAndroidEmulators != isEnabled else { return }
        preferHeadlessAndroidEmulators = isEnabled
        defaults.set(isEnabled, forKey: preferHeadlessAndroidKey)
    }

    func broadcastSetClipboard(_ text: String) async throws {
        try await broadcast { try await automation.setClipboard(text, on: $0) }
    }

    func pasteClipboard(_ text: String, to source: ViewerSource) async throws {
        guard let device = selectedCaptureDevice(for: source) else {
            throw DeviceAutomationError.noTarget(
                missingTargetMessage(for: source == .android ? .android : .iOS)
            )
        }
        try await automation.setClipboard(text, on: device)
    }

    func pasteClipboardToFocusedDevice() async throws {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw DeviceAutomationError.commandFailed("Mac clipboard is empty.")
        }

        if let source = focusedCaptureSource {
            try await pasteClipboard(text, to: source)
            return
        }

        try await broadcastSetClipboard(text)
    }

    func copyClipboardFromDevice(source: ViewerSource) async throws -> String {
        guard let device = selectedCaptureDevice(for: source) else {
            throw DeviceAutomationError.noTarget(
                missingTargetMessage(for: source == .android ? .android : .iOS)
            )
        }
        let text = try await automation.getClipboard(from: device)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    func broadcastLocation(
        latitude: Double,
        longitude: Double,
        alsoSetWeb: Bool = false,
        web: WebViewModel? = nil
    ) async throws {
        try await broadcast {
            try await automation.setLocation(
                latitude: latitude,
                longitude: longitude,
                on: $0
            )
        }
        if alsoSetWeb, isVisible(.web), let web {
            web.setMockGeolocation(latitude: latitude, longitude: longitude)
        }
    }

    func broadcastRotateClockwise() async throws {
        try await broadcast { try await automation.rotateClockwise(on: $0) }
    }

    func rotateFocusedDevice() async throws {
        if let source = focusedCaptureSource,
           let device = selectedCaptureDevice(for: source) {
            try await automation.rotateClockwise(on: device)
            return
        }
        try await broadcastRotateClockwise()
    }

    func addLocationFavorite(
        name: String,
        latitude: Double,
        longitude: Double
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DeviceAutomationError.commandFailed("Enter a favorite name.")
        }
        try DeviceAutomationService.validateCoordinate(
            latitude: latitude,
            longitude: longitude
        )
        var updated = locationFavorites.filter { $0.name != trimmedName }
        updated.insert(
            DeviceLocationCoordinate(
                name: trimmedName,
                latitude: latitude,
                longitude: longitude
            ),
            at: 0
        )
        if updated.count > 12 {
            updated = Array(updated.prefix(12))
        }
        locationFavorites = updated
        persistLocationFavorites()
    }

    func removeLocationFavorite(_ favorite: DeviceLocationCoordinate) {
        locationFavorites.removeAll { $0.id == favorite.id }
        persistLocationFavorites()
    }

    private static let defaultLocationFavorites: [DeviceLocationCoordinate] = [
        DeviceLocationCoordinate(
            name: "Apple Park",
            latitude: 37.3349,
            longitude: -122.0090
        ),
        DeviceLocationCoordinate(
            name: "London",
            latitude: 51.5074,
            longitude: -0.1278
        ),
        DeviceLocationCoordinate(
            name: "Tokyo",
            latitude: 35.6762,
            longitude: 139.6503
        )
    ]

    private func persistLocationFavorites() {
        guard let data = try? JSONEncoder().encode(locationFavorites) else {
            return
        }
        defaults.set(data, forKey: locationFavoritesKey)
    }

    private func selectedCaptureDevice(for source: ViewerSource) -> StreamedDevice? {
        switch source {
        case .android:
            guard isVisible(.android) else { return nil }
            if let focusedCapturePaneID,
               let node = paneLayout.nodes.first(where: { $0.id == focusedCapturePaneID }),
               node.viewerSource == .android {
                // Honor the focused pane exclusively — don't fall through to primary.
                return captureSession(for: node)?.selectedDevice
            }
            return androidCapture.selectedDevice
                ?? androidCaptureSecondary.selectedDevice
        case .iOS:
            guard isVisible(.iOS) else { return nil }
            if let focusedCapturePaneID,
               let node = paneLayout.nodes.first(where: { $0.id == focusedCapturePaneID }),
               node.viewerSource == .iOS {
                return captureSession(for: node)?.selectedDevice
            }
            return iOSCapture.selectedDevice
                ?? iOSCaptureSecondary.selectedDevice
        case .web:
            return nil
        }
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
        var seenIDs = Set<String>()
        for node in paneLayout.nodes {
            guard let source = node.viewerSource else { continue }
            switch source {
            case .android:
                guard targets.contains(.android) else { continue }
            case .iOS:
                guard targets.contains(.iOS) else { continue }
            case .web:
                continue
            }
            guard let device = captureSession(for: node)?.selectedDevice,
                  seenIDs.insert(device.id).inserted else {
                continue
            }
            devices.append(device)
        }
        return devices
    }

    private func configureSiblingDeviceAvoidance() {
        for session in allCaptureSessions {
            let source = session.source
            session.deviceIDsOccupiedBySiblingPanes = { [weak self, weak session] in
                guard let self, let session else { return [] }
                return Set(
                    self.allCaptureSessions
                        .filter { $0 !== session && $0.source == source }
                        .compactMap(\.selectedDeviceID)
                )
            }
        }
    }

    private func configureInputMirroring() {
        let visibleSessions = orderedVisiblePanes.compactMap { captureSession(for: $0) }
        for session in allCaptureSessions {
            if inputMirroringEnabled {
                session.setMirrorTargets(visibleSessions)
            } else {
                session.setMirrorTargets([])
            }
        }
    }

    /// Capture sessions for macro replay on the chosen OS target(s).
    func captureSessions(forMacroTarget target: MacroReplayTarget) -> [WindowCaptureSession] {
        let visible = orderedVisiblePanes.compactMap { captureSession(for: $0) }
        switch target {
        case .android:
            return visible.filter { $0.source == .android }
        case .iOS:
            return visible.filter { $0.source == .iOS }
        case .both:
            return visible
        }
    }

    func requestHighFrameRateCapture() {
        if ScreenRecordingPermission.isGranted {
            highFrameRateCaptureAvailable = true
            refreshCaptures()
            return
        }

        highFrameRateCaptureAvailable = ScreenRecordingPermission.requestAccess()
        if highFrameRateCaptureAvailable {
            refreshCaptures()
        }
    }

    func refreshHighFrameRateCaptureAvailability() {
        let wasAvailable = highFrameRateCaptureAvailable
        highFrameRateCaptureAvailable = ScreenRecordingPermission.isGranted
        if highFrameRateCaptureAvailable && !wasAvailable {
            refreshCaptures()
        }
    }

    func setVisible(_ isVisible: Bool, for source: ViewerSource) {
        if isVisible {
            visibleSources.insert(source)
            if paneLayout.count(of: source) == 0 {
                var layout = paneLayout
                _ = layout.addPane(source: source, weight: paneWeights[source] ?? 1)
                paneLayout = layout
            }
            for node in paneLayout.nodes where node.source == source.rawValue {
                captureSession(for: node)?.refreshWindows()
            }
        } else {
            guard paneLayout.nodes.count > 1 else { return }
            // Keep at least one pane overall.
            let remaining = paneLayout.nodes.filter { $0.source != source.rawValue }
            guard !remaining.isEmpty else { return }
            for node in paneLayout.nodes where node.source == source.rawValue {
                captureSession(for: node)?.stopCapture()
            }
            var layout = paneLayout
            layout.removePanes(of: source)
            paneLayout = layout
            visibleSources.remove(source)
        }

        persistVisibleSources()
        persistPaneLayout()
        configureInputMirroring()
    }

    func refreshCaptures() {
        highFrameRateCaptureAvailable = ScreenRecordingPermission.isGranted
        for session in allCaptureSessions {
            session.refreshInputAccess()
        }

        for node in paneLayout.nodes {
            captureSession(for: node)?.refreshWindows()
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
                // Only reconnect panes that are waiting — leave live siblings alone
                // so launching into a new pane does not flicker/duplicate the old one.
                for session in self.allCaptureSessions where session.needsLaunchReconnect {
                    session.refreshWindows()
                }
            }
        }
    }

    func stopCaptures() {
        captureRefreshTask?.cancel()
        for session in allCaptureSessions {
            session.stopCapture()
        }
    }

    func captureSession(for node: PaneGridNode) -> WindowCaptureSession? {
        guard let source = node.viewerSource else { return nil }
        return captureSession(for: source, slot: node.slot)
    }

    func captureSession(
        for source: ViewerSource,
        slot: Int = 0
    ) -> WindowCaptureSession? {
        // Only primary (0) and secondary (1) sessions exist today.
        guard slot >= 0, slot < PaneGridLayout.maximumDevicePanesPerSource else {
            assertionFailure("Unsupported capture slot \(slot) for \(source)")
            return nil
        }
        switch source {
        case .web:
            return nil
        case .android:
            return slot == 0 ? androidCapture : androidCaptureSecondary
        case .iOS:
            return slot == 0 ? iOSCapture : iOSCaptureSecondary
        }
    }

    private func persistVisibleSources() {
        defaults.set(
            orderedVisibleSources.map(\.rawValue),
            forKey: visibleSourcesKey
        )
    }

    private func persistPaneLayout() {
        guard let data = try? JSONEncoder().encode(paneLayout) else { return }
        defaults.set(data, forKey: paneLayoutKey)
    }
}
