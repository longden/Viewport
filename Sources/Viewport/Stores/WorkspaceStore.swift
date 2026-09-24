import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    let androidCapture = WindowCaptureSession(source: .android)
    let androidCaptureSecondary = WindowCaptureSession(source: .android)
    private let additionalAndroidCaptures = (0..<3).map { _ in WindowCaptureSession(source: .android) }
    let iOSCapture = WindowCaptureSession(source: .iOS)
    let iOSCaptureSecondary = WindowCaptureSession(source: .iOS)
    private let additionalIOSCaptures = (0..<3).map { _ in WindowCaptureSession(source: .iOS) }
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
    @Published private(set) var preferHeadlessAndroidEmulators: Bool
    @Published private(set) var preferHeadlessIOSSimulators: Bool
    @Published var focusedCaptureSource: ViewerSource?
    @Published var focusedCapturePaneID: UUID?

    /// Latest workspace row size from ``WorkspaceSplitView`` (for Reset Windows).
    private(set) var lastSplitContentSize: CGSize = PaneGridLayout.defaultSplitContentSize

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
    private let preferHeadlessAndroidKey: String
    private let preferHeadlessIOSKey: String
    private let automation = DeviceAutomationService()
    private var captureRefreshTask: Task<Void, Never>?
    private var sessionGuestTerminationTask: Task<Void, Never>?

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
        preferHeadlessAndroidKey: String = AndroidEmulatorLaunchArguments.preferHeadlessUserDefaultsKey,
        preferHeadlessIOSKey: String = IOSSimulatorClient.preferHeadlessUserDefaultsKey,
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
        self.preferHeadlessAndroidKey = preferHeadlessAndroidKey
        self.preferHeadlessIOSKey = preferHeadlessIOSKey
        androidDevices = DeviceManager(
            client: androidClient ?? AndroidDeviceClient(defaults: defaults)
        )
        iOSDevices = DeviceManager(client: iOSClient)

        let restoredWeights = defaults.dictionary(forKey: paneWeightsKey)
        let initialPaneWeights = Dictionary(uniqueKeysWithValues: ViewerSource.allCases.map {
            source in
            let value = restoredWeights?[source.rawValue] as? Double
            return (
                source,
                max(value ?? PaneGridLayout.preferredWeight(for: source), 0.01)
            )
        })

        let initialVisibility: Set<ViewerSource>
        let initialLayout: PaneGridLayout
        if let data = defaults.data(forKey: paneLayoutKey),
           let restoredLayout = try? JSONDecoder().decode(
            PaneGridLayout.self,
            from: data
           ),
           !restoredLayout.nodes.isEmpty {
            var normalized = restoredLayout
            normalized.normalizeCanonicalOrder()
            initialLayout = normalized
            initialVisibility = Set(
                normalized.nodes.compactMap(\.viewerSource)
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
        preferHeadlessAndroidEmulators = defaults.object(
            forKey: preferHeadlessAndroidKey
        ) as? Bool ?? true
        preferHeadlessIOSSimulators = defaults.object(
            forKey: preferHeadlessIOSKey
        ) as? Bool ?? true

        // Sync-scroll stays experimental; mirroring is a first-class compare tool.
        if !experimentalFeaturesEnabled, synchronizedScrollingEnabled {
            synchronizedScrollingEnabled = false
            defaults.set(false, forKey: synchronizedScrollingKey)
        }

        for session in allCaptureSessions {
            session.isPerfHUDEnabled = perfHUDEnabled
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
        paneLayout.canonicallyOrderedNodes
    }

    var allCaptureSessions: [WindowCaptureSession] {
        androidCaptureSessions + iOSCaptureSessions
    }

    var androidCaptureSessions: [WindowCaptureSession] {
        [androidCapture, androidCaptureSecondary] + additionalAndroidCaptures
    }

    var iOSCaptureSessions: [WindowCaptureSession] {
        [iOSCapture, iOSCaptureSecondary] + additionalIOSCaptures
    }

    private func captureSessions(for source: ViewerSource) -> [WindowCaptureSession] {
        switch source {
        case .android: androidCaptureSessions
        case .iOS: iOSCaptureSessions
        case .web: []
        }
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

    func canLaunchAnotherGuest(for source: ViewerSource) -> Bool {
        paneLayout.nodes.contains { node in
            node.viewerSource == source
                && captureSession(for: node)?.guestToTerminate == nil
        } || canAddPane(source)
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

    /// Closes a device pane and shuts down the guest attached to it.
    @discardableResult
    func closePane(id: UUID) -> Bool {
        guard let node = paneLayout.nodes.first(where: { $0.id == id }),
              let source = node.viewerSource,
              source == .android || source == .iOS else {
            return false
        }

        // Only pane for this platform: hide the column when others remain.
        if paneCount(of: source) == 1,
           paneLayout.nodes.count > 1 {
            setVisible(false, for: source)
            return true
        }

        let session = captureSession(for: node)
        let deviceToStop = session?.guestToTerminate
        session?.clearSelection()
        if !allCaptureSessions.contains(where: { $0.pendingLaunchName != nil }) {
            captureRefreshTask?.cancel()
            captureRefreshTask = nil
        }

        if paneLayout.nodes.count > 1 {
            var layout = paneLayout
            layout.removePane(id: id)
            paneLayout = layout

            if focusedCapturePaneID == id {
                focusedCapturePaneID = nil
            }

            configureInputMirroring()
            persistPaneLayout()
        }

        if let deviceToStop {
            terminatePaneGuest(deviceToStop)
        }
        return true
    }

    private func terminatePaneGuest(_ guest: StreamedDevice) {
        if guest.kind == .androidEmulator || guest.kind == .iOSSimulator {
            let manager = guest.source == .android ? androidDevices : iOSDevices
            if let launchable = (
                manager.sessionStartedGuestDevices + manager.bootedDevices
            ).first(where: { $0.matchesSessionGuest(guest) }) {
                manager.shutdown(launchable)
                return
            }
        }
        androidDevices.forgetSessionStarted(matching: guest)
        iOSDevices.forgetSessionStarted(matching: guest)
        Task { [weak self] in
            try? await self?.automation.terminateGuest(guest)
            self?.androidDevices.refreshDevices()
            self?.iOSDevices.refreshDevices()
        }
    }

    /// Removes an extra device pane (slot ≥ 1), stops its stream, and shuts down
    /// the emulator / Simulator that was selected there.
    @discardableResult
    func removePane(id: UUID) -> Bool {
        guard let node = paneLayout.nodes.first(where: { $0.id == id }),
              node.slot >= 1 else {
            return false
        }
        return closePane(id: id)
    }

    /// Starts an AVD / Simulator into a specific pane with a loading state,
    /// without cloning the sibling pane's live device.
    func focusCapture(source: ViewerSource, paneID: UUID?) {
        if focusedCaptureSource != source {
            focusedCaptureSource = source
        }
        if focusedCapturePaneID != paneID {
            focusedCapturePaneID = paneID
        }
    }

    func launch(_ device: LaunchableDevice, into session: WindowCaptureSession) {
        guard device.source == session.source else { return }
        if focusedCaptureSource != session.source {
            focusedCaptureSource = session.source
        }
        session.prepareForPendingLaunch(named: device.name, deviceID: device.guestID)
        // Poll for the guest while bootstatus runs so the pane connects as soon
        // as the runtime is Booted — even if bootstatus is slow or stalls.
        reconnectAfterDeviceLaunch()
        switch device.source {
        case .android:
            androidDevices.launch(device)
        case .iOS:
            iOSDevices.launch(device)
        case .web:
            break
        }
    }

    /// Launch into an empty pane, or open a new pane beside the existing guests.
    @discardableResult
    func launchInNewPane(
        _ device: LaunchableDevice,
        preferredSession: WindowCaptureSession? = nil
    ) -> Bool {
        guard !allCaptureSessions.contains(where: { session in
            session.source == device.source
                && (session.pendingLaunchDeviceID == device.guestID
                    || session.selectedDevice.map(device.matchesSessionGuest) == true)
        }) else { return false }
        let emptyNodes = paneLayout.canonicallyOrderedNodes.filter {
            $0.viewerSource == device.source
                && captureSession(for: $0)?.guestToTerminate == nil
        }
        var target = emptyNodes.first {
            captureSession(for: $0) === preferredSession
        } ?? emptyNodes.first
        if target == nil, addPane(device.source) {
            target = paneLayout.canonicallyOrderedNodes.last {
                $0.viewerSource == device.source
            }
        }
        guard let node = target, let session = captureSession(for: node) else {
            return false
        }
        focusCapture(source: device.source, paneID: node.id)
        launch(device, into: session)
        return true
    }

    /// Clears pending “Starting…” state after a launch failure/cancel.
    /// When `deviceID` is set, only panes waiting for that guest are cleared so
    /// superseding a boot into another pane does not wipe the new pending launch.
    func clearPendingLaunch(for source: ViewerSource, deviceID: String? = nil) {
        for session in allCaptureSessions where session.source == source {
            guard session.pendingLaunchName != nil else { continue }
            if let deviceID, session.pendingLaunchDeviceID != deviceID {
                continue
            }
            session.clearPendingLaunch()
        }
        // Launch-failure path: stop reconnect polling once nothing is still
        // waiting for a guest. Leave the task alone if another source still
        // has a pending launch.
        let stillWaiting = allCaptureSessions.contains { $0.pendingLaunchName != nil }
        if !stillWaiting {
            captureRefreshTask?.cancel()
            captureRefreshTask = nil
        }
    }

    /// Powers off a Simulator / emulator from the Play menu and clears any pane
    /// that was showing it.
    func shutdownGuest(_ device: LaunchableDevice) {
        switch device.source {
        case .android:
            for session in allCaptureSessions where session.source == .android {
                if session.pendingLaunchDeviceID == device.id {
                    session.clearSelection()
                    continue
                }
                if let selected = session.selectedDevice,
                   selected.kind == .androidEmulator,
                   selected.name == device.name
                    || selected.name.replacingOccurrences(of: " ", with: "_")
                        == device.id {
                    session.clearSelection()
                }
            }
            androidDevices.shutdown(device)
        case .iOS:
            for session in allCaptureSessions where session.source == .iOS {
                if session.selectedDeviceID == device.guestID
                    || session.pendingLaunchDeviceID == device.guestID {
                    session.clearSelection()
                }
            }
            iOSDevices.shutdown(device)
        case .web:
            break
        }
    }

    func shutdownAllGuests(for source: ViewerSource) {
        let paneGuests = paneLayout.nodes
            .filter { $0.viewerSource == source }
            .compactMap { captureSession(for: $0)?.guestToTerminate }
        let manager = source == .android ? androidDevices : iOSDevices
        let launchable = source == .android
            ? runningGuestsToPowerOff().android
            : runningGuestsToPowerOff().iOS
        for session in captureSessions(for: source) {
            session.clearSelection()
        }
        Task { [weak self] in
            await manager.shutdownAwaiting(launchable)
            for guest in paneGuests where !launchable.contains(where: {
                $0.matchesSessionGuest(guest)
            }) {
                try? await self?.automation.terminateGuest(guest)
            }
            manager.refreshDevices()
        }
    }

    func paneWeight(for source: ViewerSource) -> Double {
        paneWeights[source] ?? 1
    }

    func paneWeight(forPaneID id: UUID) -> Double {
        paneLayout.nodes.first { $0.id == id }?.weight ?? 1
    }

    func noteSplitContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        lastSplitContentSize = size
    }

    /// Restores aspect-fit device columns and gives leftover width to web.
    /// Keeps current panes/visibility; only resets widths.
    func resetPaneWindows() {
        let nodes = paneLayout.canonicallyOrderedNodes
        var aspects: [UUID: Double] = [:]
        for node in nodes {
            guard node.viewerSource == .android || node.viewerSource == .iOS,
                  let session = captureSession(for: node),
                  let frame = session.capturedFrameSize,
                  frame.height > 0 else {
                continue
            }
            aspects[node.id] = Double(frame.width / frame.height)
        }

        let widths = PaneGridLayout.balancedPaneWidths(
            nodes: nodes,
            contentSize: lastSplitContentSize,
            deviceAspectByNodeID: aspects
        )

        var layout = paneLayout
        var nextWeights = paneWeights
        for index in layout.nodes.indices {
            let node = layout.nodes[index]
            let width = max(
                widths[node.id]
                    ?? PaneGridLayout.minimumPaneWidth(forPaneCount: layout.nodes.count),
                0.01
            )
            layout.nodes[index].weight = width
            if node.slot == 0, let source = node.viewerSource {
                nextWeights[source] = width
            }
        }
        for source in ViewerSource.allCases where nextWeights[source] == nil {
            nextWeights[source] = PaneGridLayout.preferredWeight(for: source)
        }
        paneWeights = nextWeights
        paneLayout = layout

        persistPaneWeights()
        persistPaneLayout()
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
        for session in allCaptureSessions {
            session.isPerfHUDEnabled = isEnabled
        }
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

    func setPreferHeadlessIOSSimulators(_ isEnabled: Bool) {
        guard preferHeadlessIOSSimulators != isEnabled else { return }
        preferHeadlessIOSSimulators = isEnabled
        defaults.set(isEnabled, forKey: preferHeadlessIOSKey)
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

    func pressHomeOnFocusedDevice() async throws {
        guard let source = focusedCaptureSource ?? focusedDeviceSource(),
              let device = selectedCaptureDevice(for: source) else {
            throw DeviceAutomationError.commandFailed(
                "Select an Android or iOS device first."
            )
        }
        // Reuse the live pane HID client so we don't fight a second Indigo session.
        if source == .iOS,
           let session = focusedCaptureSession(for: .iOS),
           session.selectedDevice?.id == device.id {
            try await session.pressSystemHome()
            return
        }
        try await automation.pressHome(on: device)
    }

    func pressBackOnFocusedDevice() async throws {
        guard let source = focusedCaptureSource ?? focusedDeviceSource(),
              let device = selectedCaptureDevice(for: source) else {
            throw DeviceAutomationError.commandFailed(
                "Select an Android or iOS device first."
            )
        }
        if source == .iOS,
           let session = focusedCaptureSession(for: .iOS),
           session.selectedDevice?.id == device.id {
            try await session.pressSystemBack()
            return
        }
        try await automation.pressBack(on: device)
    }

    func focusedCaptureSession(for source: ViewerSource) -> WindowCaptureSession? {
        if let focusedCapturePaneID,
           let node = paneLayout.nodes.first(where: { $0.id == focusedCapturePaneID }),
           node.viewerSource == source {
            return captureSession(for: node)
        }
        return captureSessions(for: source).first { $0.selectedDevice != nil }
    }

    private func focusedDeviceSource() -> ViewerSource? {
        if androidCaptureSessions.contains(where: { $0.selectedDevice != nil }) { return .android }
        if iOSCaptureSessions.contains(where: { $0.selectedDevice != nil }) { return .iOS }
        return nil
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
            return androidCaptureSessions.compactMap(\.selectedDevice).first
        case .iOS:
            guard isVisible(.iOS) else { return nil }
            if let focusedCapturePaneID,
               let node = paneLayout.nodes.first(where: { $0.id == focusedCapturePaneID }),
               node.viewerSource == .iOS {
                return captureSession(for: node)?.selectedDevice
            }
            return iOSCaptureSessions.compactMap(\.selectedDevice).first
        case .web:
            return nil
        }
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

    /// Sessions backing a pane in the layout. Spare slot sessions stay idle.
    var paneCaptureSessions: [WindowCaptureSession] {
        paneLayout.nodes.compactMap { captureSession(for: $0) }
    }

    /// Panes still waiting for a launched guest. Spare sessions must not join:
    /// they would claim the new guest invisibly and block the waiting pane.
    var launchReconnectSessions: [WindowCaptureSession] {
        paneCaptureSessions.filter(\.needsLaunchReconnect)
    }

    private func configureSiblingDeviceAvoidance() {
        for session in allCaptureSessions {
            let source = session.source
            session.deviceIDsOccupiedBySiblingPanes = { [weak self, weak session] in
                guard let self, let session else { return [] }
                return Set(
                    self.paneCaptureSessions
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
        let isGranted = ScreenRecordingPermission.isGranted
        let wasAvailable = highFrameRateCaptureAvailable
        guard isGranted != wasAvailable else { return }
        highFrameRateCaptureAvailable = isGranted
        if isGranted {
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
            let devicesToStop = paneLayout.nodes
                .filter { $0.source == source.rawValue }
                .compactMap { captureSession(for: $0)?.guestToTerminate }
            for node in paneLayout.nodes where node.source == source.rawValue {
                captureSession(for: node)?.clearSelection()
            }
            var layout = paneLayout
            layout.removePanes(of: source)
            paneLayout = layout
            visibleSources.remove(source)

            for device in devicesToStop {
                terminatePaneGuest(device)
            }
        }

        persistVisibleSources()
        persistPaneLayout()
        configureInputMirroring()
    }

    func guestsToTerminate(for source: ViewerSource) -> [StreamedDevice] {
        guard isVisible(source) else { return [] }
        return paneLayout.nodes
            .filter { $0.source == source.rawValue }
            .compactMap { captureSession(for: $0)?.guestToTerminate }
    }

    func guestToTerminate(forExtraPane source: ViewerSource) -> StreamedDevice? {
        guard paneCount(of: source) >= 2,
              let node = paneLayout.nodes.filter({ $0.source == source.rawValue }).last else { return nil }
        return captureSession(for: node)?.guestToTerminate
    }

    func refreshCaptures() {
        let isGranted = ScreenRecordingPermission.isGranted
        if highFrameRateCaptureAvailable != isGranted {
            highFrameRateCaptureAvailable = isGranted
        }
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
            // Keep polling longer than a cold Simulator boot. Early ticks catch
            // the device as soon as it is Booted; later ticks recover if Surface
            // attach raced ahead of the framebuffer.
            for delay in [0.4, 1.0, 2.0, 4.0, 8.0, 15.0, 30.0, 60.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                // Only reconnect panes that are waiting — leave live siblings alone
                // so launching into a new pane does not flicker/duplicate the old one.
                for session in self.launchReconnectSessions {
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

    /// Alert copy when closing the app would power off running guests.
    var sessionGuestClosePrompt: SessionGuestClosePrompt? {
        let guests = runningGuestsToPowerOff()
        var androidNames = guests.android.map(\.name)
        var iOSNames = guests.iOS.map(\.name)
        for guest in runningPaneGuests() {
            switch guest.kind {
            case .androidEmulator:
                androidNames.append(guest.name)
            case .iOSSimulator:
                iOSNames.append(guest.name)
            case .androidDevice, .iOSDevice:
                continue
            }
        }
        return SessionGuestClosePrompt.make(
            androidNames: uniquedSortedNames(androidNames),
            iOSNames: uniquedSortedNames(iOSNames)
        )
    }

    /// Powers off running Simulators and emulators (panes, Play/create, and
    /// already-booted guests). Physical USB devices are left on. Safe to call
    /// more than once — later callers wait for the in-flight shutdown.
    func terminateSessionStartedGuests() async {
        if let sessionGuestTerminationTask {
            await sessionGuestTerminationTask.value
            return
        }

        stopCaptures()
        let androidManager = androidDevices
        let iosManager = iOSDevices
        let guests = runningGuestsToPowerOff()
        _ = androidManager.takeSessionStartedGuests()
        _ = iosManager.takeSessionStartedGuests()
        let paneGuests = runningPaneGuests()
        let task = Task { @MainActor in
            await androidManager.shutdownAwaiting(guests.android)
            await iosManager.shutdownAwaiting(guests.iOS)
            for guest in paneGuests {
                let covered = guests.android.contains { $0.matchesSessionGuest(guest) }
                    || guests.iOS.contains { $0.matchesSessionGuest(guest) }
                if !covered {
                    try? await self.automation.terminateGuest(guest)
                }
            }
        }
        sessionGuestTerminationTask = task
        await task.value
    }

    /// Running emulator / Simulator guests that closing Viewport should power off.
    func runningGuestsToPowerOff() -> (
        android: [LaunchableDevice],
        iOS: [LaunchableDevice]
    ) {
        (
            android: mergeLaunchableGuests(
                sessionStarted: androidDevices.sessionStartedGuestDevices,
                booted: androidDevices.bootedDevices,
                paneGuests: runningPaneGuests().filter { $0.kind == .androidEmulator }
            ),
            iOS: mergeLaunchableGuests(
                sessionStarted: iOSDevices.sessionStartedGuestDevices,
                booted: iOSDevices.bootedDevices,
                paneGuests: runningPaneGuests().filter { $0.kind == .iOSSimulator }
            )
        )
    }

    private func runningPaneGuests() -> [StreamedDevice] {
        var seen = Set<String>()
        var guests: [StreamedDevice] = []
        for session in allCaptureSessions {
            guard let guest = session.guestToTerminate else { continue }
            switch guest.kind {
            case .androidEmulator, .iOSSimulator:
                let key = "\(guest.source.rawValue)-\(guest.id)"
                if seen.insert(key).inserted {
                    guests.append(guest)
                }
            case .androidDevice, .iOSDevice:
                continue
            }
        }
        return guests
    }

    private func mergeLaunchableGuests(
        sessionStarted: [LaunchableDevice],
        booted: [LaunchableDevice],
        paneGuests: [StreamedDevice]
    ) -> [LaunchableDevice] {
        var byID: [String: LaunchableDevice] = [:]
        for device in sessionStarted + booted {
            if let existing = byID[device.guestID], !existing.isLightSim {
                continue
            }
            byID[device.guestID] = device
        }
        for guest in paneGuests {
            if byID.values.contains(where: { $0.matchesSessionGuest(guest) }) {
                continue
            }
            // Android pane IDs are ADB serials; `emu kill` needs that path, not AVD lookup.
            guard guest.kind == .iOSSimulator else { continue }
            byID[guest.id] = LaunchableDevice(
                id: guest.id,
                source: .iOS,
                name: guest.name,
                runtime: nil,
                state: .booted
            )
        }
        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func uniquedSortedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names.sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    func captureSession(for node: PaneGridNode) -> WindowCaptureSession? {
        guard let source = node.viewerSource else { return nil }
        return captureSession(for: source, slot: node.slot)
    }

    func captureSession(
        for source: ViewerSource,
        slot: Int = 0
    ) -> WindowCaptureSession? {
        guard slot >= 0, slot < PaneGridLayout.maximumDevicePanesPerSource else {
            assertionFailure("Unsupported capture slot \(slot) for \(source)")
            return nil
        }
        switch source {
        case .web:
            return nil
        case .android:
            return androidCaptureSessions[slot]
        case .iOS:
            return iOSCaptureSessions[slot]
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
