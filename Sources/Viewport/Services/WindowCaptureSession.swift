import AppKit
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface

enum CapturePhase: Equatable {
    case idle
    case searching
    case connecting
    case live
    case noWindow
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Waiting"
        case .searching: "Looking"
        case .connecting: "Connecting"
        case .live: "Live"
        case .noWindow: "Not found"
        case .failed: "Device error"
        }
    }
}

enum CaptureTransport: Equatable {
    case direct
    case usbDevice
    case scrcpy(frameRate: Int)
    case windowStream(frameRate: Int)
    case simulatorSurface
    case emulatorGrpc(frameRate: Int)

    /// Compact name for the device picker, e.g. `Pixel 7 (H.264)`.
    var shortLabel: String {
        switch self {
        case .direct:
            "ADB"
        case .usbDevice:
            "USB"
        case .scrcpy:
            "H.264"
        case .windowStream:
            "Window"
        case .simulatorSurface:
            "Surface"
        case .emulatorGrpc:
            "gRPC"
        }
    }
}

@MainActor
final class WindowCaptureSession: ObservableObject {
    let source: ViewerSource

    @Published private(set) var availableDevices: [StreamedDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var phase: CapturePhase = .idle
    @Published private(set) var inputAccess: InputAccessPhase
    @Published private(set) var capturedFrameSize: CGSize?
    @Published private(set) var transport: CaptureTransport = .direct
    @Published private(set) var framesPerSecond: Double = 0
    /// When set, this pane is waiting for a freshly launched emulator/Simulator.
    @Published private(set) var pendingLaunchName: String?

    private let frameClient: DeviceFrameClient
    private let hostWindowStream: HostWindowStream
    private let scrcpyDeviceStream: ScrcpyDeviceStream?
    private let iOSDeviceStream: IOSDeviceStream?
    private let androidInput: AndroidDeviceInput?
    private let iOSInput: IOSSimulatorHIDInput?
    private var captureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private let framePresenter: CaptureFramePresenter
    /// Readable from composite encode without hopping to MainActor.
    nonisolated let recordingFrameSlot: LatestLiveFrameSlot
    private let frameRateMeter = FrameRateMeter()
    private var fpsPublishTask: Task<Void, Never>?
    private var performanceProfile: CapturePerformanceProfile = .smooth
    private var captureMode: CaptureMode = .direct
    private var usesHostWindowStream = false
    private var activePointer: ActivePointer?
    /// Pointer gestures are forwarded to these sessions using the same
    /// normalized coordinates. Receivers set `isMirroringInput` so they do not
    /// re-fan-out (avoids mirror cycles).
    private var mirrorTargetBoxes: [WeakCaptureSessionBox] = []
    private var isMirroringInput = false
    /// Device IDs already claimed by sibling panes; preferred auto-select skips these.
    var deviceIDsOccupiedBySiblingPanes: () -> Set<String> = { [] }
    /// Optional sink for sync-scroll prototypes.
    var pointerEventSink: ((PointerEventPhase, CGPoint, TimeInterval?) -> Void)?
    private let simulatorSurfaceStream: IOSSimulatorSurfaceStream?
    private let emulatorGrpcStream: AndroidEmulatorGrpcStream?

    init(source: ViewerSource) {
        self.source = source
        let frameClient = DeviceFrameClient(source: source)
        self.frameClient = frameClient
        let presenter = CaptureFramePresenter()
        framePresenter = presenter
        recordingFrameSlot = presenter.recordingFrameSlot
        hostWindowStream = HostWindowStream()
        scrcpyDeviceStream = source == .android ? ScrcpyDeviceStream() : nil
        iOSDeviceStream = source == .iOS ? IOSDeviceStream() : nil
        simulatorSurfaceStream = source == .iOS ? IOSSimulatorSurfaceStream() : nil
        emulatorGrpcStream = source == .android ? AndroidEmulatorGrpcStream() : nil
        androidInput = source == .android ? AndroidDeviceInput() : nil
        let iOSInput = source == .iOS ? IOSSimulatorHIDInput() : nil
        self.iOSInput = iOSInput
        inputAccess = frameClient.isAvailable
            && (source != .iOS || iOSInput?.isAvailable == true)
            ? .ready
            : .permissionNeeded
    }

    deinit {
        captureTask?.cancel()
        refreshTask?.cancel()
        fpsPublishTask?.cancel()
        // `stop()` is nonisolated on each stream; do not use
        // MainActor.assumeIsolated — deinit may run off the main thread.
        hostWindowStream.stop()
        scrcpyDeviceStream?.stop()
        iOSDeviceStream?.stop()
        simulatorSurfaceStream?.stop()
        emulatorGrpcStream?.stop()
    }

    var selectedDevice: StreamedDevice? {
        availableDevices.first(where: { $0.id == selectedDeviceID })
    }

    var capturedWindowSize: CGSize? {
        capturedFrameSize
    }

    var liveStatus: String {
        switch transport {
        case .direct:
            "Live · Direct"
        case .usbDevice:
            "Live · USB"
        case let .scrcpy(frameRate):
            "Live · H.264 · \(frameRate) FPS"
        case let .windowStream(frameRate):
            "Live · \(frameRate) FPS"
        case .simulatorSurface:
            "Live · Surface"
        case let .emulatorGrpc(frameRate):
            "Live · gRPC · \(frameRate) FPS"
        }
    }

    func attachPreview(_ view: CapturePreviewNSView) {
        framePresenter.attach(view)
    }

    func detachPreview(_ view: CapturePreviewNSView) {
        framePresenter.detach(view)
    }

    func refreshInputAccess() {
        if selectedDevice?.supportsInput == false {
            inputAccess = .viewOnly
            return
        }
        inputAccess = frameClient.isAvailable
            && (source != .iOS || iOSInput?.isAvailable == true)
            ? .ready
            : .permissionNeeded
    }

    func requestInputAccess() {
        // Direct ADB and Simulator HID input do not use macOS Accessibility.
        refreshInputAccess()
    }

    func setPerformanceProfile(_ profile: CapturePerformanceProfile) {
        guard performanceProfile != profile else { return }
        performanceProfile = profile
        guard let selectedDeviceID,
              phase == .live
                || captureTask != nil
                || usesHostWindowStream else { return }
        startCapture(
            deviceID: selectedDeviceID,
            preservingCurrentFrame: true
        )
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard captureMode != mode else { return }
        captureMode = mode
        guard let selectedDeviceID else { return }
        startCapture(
            deviceID: selectedDeviceID,
            preservingCurrentFrame: true
        )
    }

    func snapshotFrame() -> CGImage? {
        framePresenter.latestFrame
    }

    /// Prefers GPU-backed surfaces for composite recording.
    /// Safe off MainActor — reads the presenter's thread-safe slot.
    nonisolated func liveRecordingFrame() -> LiveCaptureFrame? {
        recordingFrameSlot.load()
    }

    func refreshWindows() {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        if phase != .live {
            phase = pendingLaunchName == nil ? .searching : .connecting
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await frameClient.listRunningDevices()
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }

                let previousSelection = selectedDeviceID
                availableDevices = devices
                let occupied = deviceIDsOccupiedBySiblingPanes()
                let selected = preferredDevice(
                    in: devices,
                    previousSelection: previousSelection,
                    occupied: occupied
                )
                guard let selected else {
                    selectedDeviceID = nil
                    stopCapture()
                    phase = pendingLaunchName == nil ? .noWindow : .connecting
                    return
                }

                pendingLaunchName = nil
                // Always re-run the capture strategy chain (Direct → … → ADB)
                // so refresh recovers from sticky fallbacks like screencap
                // polling after scrcpy/gRPC failed mid-session.
                selectedDeviceID = selected.id
                refreshInputAccess()
                startCapture(
                    deviceID: selected.id,
                    preservingCurrentFrame: previousSelection == selected.id
                        && phase == .live
                )
            } catch {
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }
                availableDevices = []
                selectedDeviceID = nil
                stopCapture()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears any current stream and shows a loading empty state until a free
    /// device appears for this pane (used when Play starts an emulator here).
    func prepareForPendingLaunch(named name: String) {
        pendingLaunchName = name
        selectedDeviceID = nil
        stopCapture()
        phase = .connecting
    }

    func clearPendingLaunch() {
        pendingLaunchName = nil
    }

    func clearSelection() {
        pendingLaunchName = nil
        selectedDeviceID = nil
        stopCapture()
        phase = .idle
    }

    /// True when reconnect-after-launch should refresh this session.
    var needsLaunchReconnect: Bool {
        if pendingLaunchName != nil {
            return true
        }
        switch phase {
        case .searching, .connecting, .noWindow, .idle:
            return true
        case .live, .failed:
            return false
        }
    }

    private func preferredDevice(
        in devices: [StreamedDevice],
        previousSelection: String?,
        occupied: Set<String>
    ) -> StreamedDevice? {
        if let previousSelection,
           let match = devices.first(where: { $0.id == previousSelection }) {
            return match
        }

        // Never auto-clone a sibling pane's device — that caused the brief
        // duplicate when a second pane was waiting for a new emulator.
        if let free = devices.first(where: { !occupied.contains($0.id) }) {
            return free
        }

        return nil
    }

    func selectDevice(_ id: String) {
        guard availableDevices.contains(where: { $0.id == id }) else {
            return
        }
        selectedDeviceID = id
        refreshInputAccess()
        startCapture(deviceID: id)
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        fpsPublishTask?.cancel()
        fpsPublishTask = nil
        frameRateMeter.reset()
        framesPerSecond = 0
        activePointer = nil
        usesHostWindowStream = false
        transport = .direct
        stopDeviceStreams()
        iOSInput?.reset()
        capturedFrameSize = nil
        framePresenter.clear()
    }

    func beginPointer(at point: CGPoint) {
        guard let device = selectedDevice, device.supportsInput else { return }
        if !isMirroringInput {
            pointerEventSink?(.began, point, nil)
        }

        if source == .iOS, let iOSInput {
            activePointer = ActivePointer(
                deviceID: device.id,
                start: point,
                last: point,
                usesLiveAndroidMotion: false
            )
            iOSInput.touchDown(at: point, udid: device.id)
            forwardMirrorBegin(at: point)
            return
        }

        if source == .android,
           let deviceSize = device.pixelSize ?? capturedFrameSize {
            let useGrpc = captureMode == .direct
                && device.kind == .androidEmulator
                && {
                    if case .emulatorGrpc = transport { return true }
                    return false
                }()
            let useScrcpyControl = !useGrpc
                && scrcpyDeviceStream?.hasTouchControl == true
                && {
                    if case .scrcpy = transport { return true }
                    return false
                }()
            activePointer = ActivePointer(
                deviceID: device.id,
                start: point,
                last: point,
                usesLiveAndroidMotion: true,
                usesEmulatorGrpc: useGrpc,
                usesScrcpyControl: useScrcpyControl,
                deviceSize: deviceSize
            )
            if useGrpc {
                emulatorGrpcStream?.sendTouch(
                    serial: device.id,
                    deviceSize: deviceSize,
                    action: .down,
                    at: point
                )
            } else if useScrcpyControl {
                scrcpyDeviceStream?.sendTouch(action: .down, at: point)
            } else {
                androidInput?.motionEvent(
                    serial: device.id,
                    deviceSize: deviceSize,
                    action: .down,
                    at: point
                )
            }
            forwardMirrorBegin(at: point)
        }
    }

    func movePointer(to point: CGPoint) {
        guard var activePointer,
              let device = selectedDevice,
              device.id == activePointer.deviceID else { return }
        activePointer.last = point
        self.activePointer = activePointer
        if !isMirroringInput {
            pointerEventSink?(.moved, point, nil)
        }

        if source == .iOS, let iOSInput {
            iOSInput.touchMove(to: point, udid: device.id)
            forwardMirrorMove(to: point)
            return
        }

        if source == .android,
           activePointer.usesLiveAndroidMotion,
           let deviceSize = activePointer.deviceSize {
            if activePointer.usesEmulatorGrpc {
                emulatorGrpcStream?.sendTouch(
                    serial: device.id,
                    deviceSize: deviceSize,
                    action: .move,
                    at: point
                )
            } else if activePointer.usesScrcpyControl {
                scrcpyDeviceStream?.sendTouch(action: .move, at: point)
            } else if let androidInput {
                androidInput.motionEvent(
                    serial: device.id,
                    deviceSize: deviceSize,
                    action: .move,
                    at: point
                )
            }
            forwardMirrorMove(to: point)
        }
    }

    func endPointer(at point: CGPoint, duration: TimeInterval) {
        guard let activePointer,
              let device = selectedDevice,
              device.id == activePointer.deviceID else {
            self.activePointer = nil
            return
        }
        self.activePointer = nil
        let start = activePointer.start
        let distance = hypot(point.x - start.x, point.y - start.y)
        if !isMirroringInput {
            pointerEventSink?(.ended, point, duration)
        }

        if source == .iOS, let iOSInput {
            iOSInput.touchUp(at: point, udid: device.id)
            // Only kick the simctl poll loop. Live streams (Surface, window,
            // USB) must keep running across touches.
            if transport == .direct {
                startPollingCapture(
                    deviceID: device.id,
                    preservingCurrentFrame: true
                )
            }
            forwardMirrorEnd(at: point, duration: duration)
            return
        }

        if source == .android,
           let deviceSize = activePointer.deviceSize
            ?? device.pixelSize
            ?? capturedFrameSize {
            if activePointer.usesLiveAndroidMotion {
                if activePointer.usesEmulatorGrpc {
                    emulatorGrpcStream?.sendTouch(
                        serial: device.id,
                        deviceSize: deviceSize,
                        action: .up,
                        at: point
                    )
                } else if activePointer.usesScrcpyControl {
                    scrcpyDeviceStream?.sendTouch(action: .up, at: point)
                } else {
                    androidInput?.motionEvent(
                        serial: device.id,
                        deviceSize: deviceSize,
                        action: .up,
                        at: point
                    )
                }
                forwardMirrorEnd(at: point, duration: duration)
                return
            }
            if let androidInput {
                if distance < 0.015 {
                    Task {
                        await androidInput.tap(
                            serial: device.id,
                            deviceSize: deviceSize,
                            at: point
                        )
                    }
                } else {
                    Task {
                        await androidInput.swipe(
                            serial: device.id,
                            deviceSize: deviceSize,
                            from: start,
                            to: point,
                            duration: duration
                        )
                    }
                }
            }
            forwardMirrorEnd(at: point, duration: duration)
        }
    }

    func setMirrorTargets(_ sessions: [WindowCaptureSession]) {
        let ownDeviceID = selectedDeviceID
        mirrorTargetBoxes = sessions
            .filter { target in
                guard target !== self else { return false }
                // Never double-dispatch to the same physical device.
                if let ownDeviceID,
                   let otherID = target.selectedDeviceID,
                   ownDeviceID == otherID {
                    return false
                }
                return true
            }
            .map(WeakCaptureSessionBox.init)
    }

    private var liveMirrorTargets: [WindowCaptureSession] {
        mirrorTargetBoxes.compactMap(\.session)
    }

    private func forwardMirrorBegin(at point: CGPoint) {
        guard !isMirroringInput else { return }
        for target in liveMirrorTargets {
            target.isMirroringInput = true
            target.beginPointer(at: point)
            target.isMirroringInput = false
        }
    }

    private func forwardMirrorMove(to point: CGPoint) {
        guard !isMirroringInput else { return }
        for target in liveMirrorTargets {
            target.isMirroringInput = true
            target.movePointer(to: point)
            target.isMirroringInput = false
        }
    }

    private func forwardMirrorEnd(at point: CGPoint, duration: TimeInterval) {
        guard !isMirroringInput else { return }
        for target in liveMirrorTargets {
            target.isMirroringInput = true
            target.endPointer(at: point, duration: duration)
            target.isMirroringInput = false
        }
    }

    func performGesture(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval
    ) {
        guard let device = selectedDevice else { return }
        guard device.supportsInput else { return }
        let distance = hypot(end.x - start.x, end.y - start.y)

        if source == .android,
           let androidInput,
           let deviceSize = device.pixelSize ?? capturedFrameSize {
            if distance < 0.015 {
                Task {
                    await androidInput.tap(
                        serial: device.id,
                        deviceSize: deviceSize,
                        at: end
                    )
                }
            } else {
                Task {
                    await androidInput.swipe(
                        serial: device.id,
                        deviceSize: deviceSize,
                        from: start,
                        to: end,
                        duration: duration
                    )
                }
            }
            return
        }

        guard source == .iOS, let iOSInput else { return }
        Task { @MainActor in
            iOSInput.touchDown(at: start, udid: device.id)
            let steps = distance < 0.015
                ? 1
                : max(2, min(Int(duration * 60), 12))
            if steps > 1 {
                let delay = min(max(duration / Double(steps), 0.004), 0.012)
                for step in 1...steps {
                    let progress = CGFloat(step) / CGFloat(steps)
                    iOSInput.touchMove(
                        to: CGPoint(
                            x: start.x + (end.x - start.x) * progress,
                            y: start.y + (end.y - start.y) * progress
                        ),
                        udid: device.id
                    )
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            iOSInput.touchUp(at: end, udid: device.id)
            if transport == .direct {
                startPollingCapture(
                    deviceID: device.id,
                    preservingCurrentFrame: true
                )
            }
        }
    }

    @discardableResult
    func postKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let device = selectedDevice else { return false }
        guard device.supportsInput else { return false }
        if source == .android {
            if case .scrcpy = transport,
               let stream = scrcpyDeviceStream,
               stream.hasControlConnection {
                if let keycode = AndroidDeviceInput.androidKeycodeValue(for: event) {
                    if event.type == .keyDown {
                        _ = stream.sendKeycode(keycode)
                    }
                    return true
                }
                if event.type == .keyDown,
                   let text = event.characters,
                   !text.isEmpty,
                   stream.sendText(text) {
                    return true
                }
            }
            if let androidInput {
                Task {
                    await androidInput.key(serial: device.id, event: event)
                }
                return true
            }
            return false
        }
        if source == .iOS, let iOSInput {
            return iOSInput.sendKey(event, udid: device.id)
                || event.type != .keyDown
        }
        return false
    }

    private func startCapture(
        deviceID: String,
        preservingCurrentFrame: Bool = false
    ) {
        captureTask?.cancel()
        usesHostWindowStream = false
        iOSInput?.reset()
        stopDeviceStreams()
        if !preservingCurrentFrame {
            framePresenter.clear()
            capturedFrameSize = nil
            phase = .connecting
        }

        captureTask = Task { [weak self] in
            guard let self else { return }
            guard let device = availableDevices.first(where: {
                $0.id == deviceID
            }) else {
                return
            }
            await runCaptureStrategies(
                CaptureTransportPolicy.strategies(
                    mode: captureMode,
                    deviceKind: device.kind
                ),
                device: device,
                preservingCurrentFrame: preservingCurrentFrame
            )
        }
    }

    private func runCaptureStrategies(
        _ strategies: [CaptureStrategy],
        device: StreamedDevice,
        preservingCurrentFrame: Bool
    ) async {
        let deviceID = device.id
        for strategy in strategies where !Task.isCancelled {
            let started: Bool
            switch strategy {
            case .simulatorSurface:
                started = await startSimulatorSurfaceCapture(deviceID: deviceID)
            case .emulatorGrpc:
                started = await startEmulatorGrpcCapture(deviceID: deviceID)
            case .hostWindow:
                started = await startHostWindowCapture(deviceID: deviceID)
            case .scrcpy:
                started = await startScrcpyDeviceCapture(deviceID: deviceID)
            case .usbDevice:
                await startIOSDeviceCapture(deviceID: deviceID)
                started = true
            case .polling:
                await pollFrames(
                    deviceID: deviceID,
                    preservingCurrentFrame: preservingCurrentFrame
                )
                started = true
            }
            if started {
                return
            }
        }
    }

    private func startClassicCapture(
        device: StreamedDevice,
        preservingCurrentFrame: Bool
    ) async {
        await runCaptureStrategies(
            CaptureTransportPolicy.strategies(
                mode: .classic,
                deviceKind: device.kind
            ),
            device: device,
            preservingCurrentFrame: preservingCurrentFrame
        )
    }

    private func startSimulatorSurfaceCapture(deviceID: String) async -> Bool {
        guard let simulatorSurfaceStream,
              simulatorSurfaceStream.isAvailable else { return false }
        do {
            try simulatorSurfaceStream.start(
                deviceID: deviceID,
                frameRate: 60
            ) {
                [weak self] surface in
                guard let self, selectedDeviceID == deviceID else { return }
                display(surface: surface)
            } onFailure: { [weak self] _ in
                guard let self, selectedDeviceID == deviceID else { return }
                startPollingCapture(
                    deviceID: deviceID,
                    preservingCurrentFrame: true
                )
            }
            transport = .simulatorSurface
            return true
        } catch {
            simulatorSurfaceStream.stop()
            return false
        }
    }

    private func startEmulatorGrpcCapture(deviceID: String) async -> Bool {
        guard let emulatorGrpcStream else { return false }
        do {
            let started = try await emulatorGrpcStream.start(
                serial: deviceID,
                profile: performanceProfile
            ) { [weak self] image in
                guard let self, selectedDeviceID == deviceID else { return }
                display(image)
            } onFailure: { [weak self] _ in
                guard let self, selectedDeviceID == deviceID else { return }
                // Keep the pane usable if the gRPC stream dies mid-session.
                Task { [weak self] in
                    guard let self,
                          let device = availableDevices.first(where: { $0.id == deviceID }),
                          selectedDeviceID == deviceID else { return }
                    await startClassicCapture(
                        device: device,
                        preservingCurrentFrame: true
                    )
                }
            }
            if started {
                transport = .emulatorGrpc(
                    frameRate: performanceProfile.targetFrameRate
                )
            }
            return started
        } catch {
            emulatorGrpcStream.stop()
            return false
        }
    }

    private func startScrcpyDeviceCapture(deviceID: String) async -> Bool {
        guard let scrcpyDeviceStream,
              scrcpyDeviceStream.isAvailable else { return false }

        do {
            let started = try await scrcpyDeviceStream.start(
                serial: deviceID,
                profile: performanceProfile
            ) { [weak self] pixelBuffer in
                guard let self, selectedDeviceID == deviceID else { return }
                display(pixelBuffer: pixelBuffer)
            } onFailure: { [weak self] _ in
                guard let self, selectedDeviceID == deviceID else { return }
                startPollingCapture(
                    deviceID: deviceID,
                    preservingCurrentFrame: true
                )
            }
            if started {
                transport = .scrcpy(
                    frameRate: performanceProfile.targetFrameRate
                )
            }
            return started
        } catch {
            scrcpyDeviceStream.stop()
            return false
        }
    }

    private func startIOSDeviceCapture(deviceID: String) async {
        guard let iOSDeviceStream else { return }

        do {
            try await iOSDeviceStream.start(
                deviceID: deviceID,
                profile: performanceProfile
            ) {
                [weak self] pixelBuffer in
                guard let self, selectedDeviceID == deviceID else { return }
                display(pixelBuffer: pixelBuffer)
            } onFailure: { [weak self] error in
                guard let self, selectedDeviceID == deviceID else { return }
                phase = .failed(error.localizedDescription)
            }
            transport = .usbDevice
        } catch {
            guard selectedDeviceID == deviceID else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func startHostWindowCapture(deviceID: String) async -> Bool {
        guard var device = availableDevices.first(where: {
            $0.id == deviceID
        }) else {
            return false
        }

        // Need framebuffer aspect so chrome cropping can keep only the device
        // pixels. Measure once if the device list did not already provide it.
        if device.pixelSize == nil,
           let measured = await frameClient.measureScreenSize(deviceID: deviceID) {
            device = StreamedDevice(
                id: device.id,
                name: device.name,
                source: device.source,
                pixelSize: measured,
                kind: device.kind
            )
            if let index = availableDevices.firstIndex(where: {
                $0.id == deviceID
            }) {
                availableDevices[index] = device
            }
        }

        do {
            let started = try await hostWindowStream.start(
                source: source,
                deviceName: device.name,
                profile: performanceProfile,
                contentAspect: device.pixelSize
            ) { [weak self] pixelBuffer in
                guard let self, selectedDeviceID == deviceID else { return }
                usesHostWindowStream = true
                display(pixelBuffer: pixelBuffer)
            } onFailure: { [weak self] _ in
                guard let self,
                      selectedDeviceID == deviceID,
                      usesHostWindowStream else { return }
                startPollingCapture(
                    deviceID: deviceID,
                    preservingCurrentFrame: true
                )
            }
            usesHostWindowStream = started
            if started {
                transport = .windowStream(
                    frameRate: performanceProfile.hostWindowFrameRate
                )
            }
            return started
        } catch {
            usesHostWindowStream = false
            transport = .direct
            return false
        }
    }

    private func startPollingCapture(
        deviceID: String,
        preservingCurrentFrame: Bool
    ) {
        captureTask?.cancel()
        usesHostWindowStream = false
        transport = .direct
        stopDeviceStreams()
        captureTask = Task { [weak self] in
            guard let self else { return }
            await pollFrames(
                deviceID: deviceID,
                preservingCurrentFrame: preservingCurrentFrame
            )
        }
    }

    private func pollFrames(
        deviceID: String,
        preservingCurrentFrame: Bool
    ) async {
        transport = .direct
        var hasDisplayedFrame = preservingCurrentFrame
            && capturedFrameSize != nil
        var consecutiveFailures = 0

        while !Task.isCancelled, selectedDeviceID == deviceID {
            let captureStarted = ContinuousClock.now
            do {
                let data = try await frameClient.captureFrame(
                    deviceID: deviceID
                )
                try Task.checkCancellation()
                let maximumDimension = performanceProfile
                    .maximumDisplayDimension
                let imageBox = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try DecodedFrame(
                        data: data,
                        maximumDimension: maximumDimension
                    )
                }.value
                guard selectedDeviceID == deviceID,
                      !Task.isCancelled else { return }

                display(imageBox.image, sourceSize: imageBox.sourceSize)
                consecutiveFailures = 0
                if !hasDisplayedFrame {
                    hasDisplayedFrame = true
                }
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                if !hasDisplayedFrame || consecutiveFailures >= 4 {
                    phase = .failed(error.localizedDescription)
                }
            }

            let elapsed = captureStarted.duration(to: .now)
            let remaining = performanceProfile.directCaptureInterval - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }

    private func display(_ image: CGImage, sourceSize: CGSize? = nil) {
        if let changedSize = framePresenter.display(
            image,
            sourceSize: sourceSize
        ) {
            capturedFrameSize = changedSize
        }
        noteFrameDelivered()
        if phase != .live {
            phase = .live
        }
    }

    private func display(surface: IOSurfaceRef) {
        if let changedSize = framePresenter.display(surface: surface) {
            capturedFrameSize = changedSize
        }
        noteFrameDelivered()
        if phase != .live {
            phase = .live
        }
    }

    private func display(pixelBuffer: CVPixelBuffer) {
        if let changedSize = framePresenter.display(pixelBuffer: pixelBuffer) {
            capturedFrameSize = changedSize
        }
        noteFrameDelivered()
        if phase != .live {
            phase = .live
        }
    }

    private func noteFrameDelivered() {
        frameRateMeter.record()
        ensureFPSPublishLoop()
    }

    /// Periodically republishes FPS so idle / stalled streams decay to 0.
    private func ensureFPSPublishLoop() {
        guard fpsPublishTask == nil else { return }
        fpsPublishTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let fps = self.frameRateMeter.age()
                if abs(self.framesPerSecond - fps) > 0.4 {
                    self.framesPerSecond = fps
                }
                if fps <= 0, self.framesPerSecond <= 0 {
                    self.fpsPublishTask = nil
                    return
                }
            }
        }
    }

    private func stopDeviceStreams() {
        var streams: [any DeviceStream] = [hostWindowStream]
        if let scrcpyDeviceStream { streams.append(scrcpyDeviceStream) }
        if let iOSDeviceStream { streams.append(iOSDeviceStream) }
        if let simulatorSurfaceStream { streams.append(simulatorSurfaceStream) }
        if let emulatorGrpcStream { streams.append(emulatorGrpcStream) }
        streams.forEach { $0.stop() }
    }
}

private struct ActivePointer {
    let deviceID: String
    let start: CGPoint
    var last: CGPoint
    let usesLiveAndroidMotion: Bool
    var usesEmulatorGrpc: Bool = false
    var usesScrcpyControl: Bool = false
    var deviceSize: CGSize? = nil
}

private enum DeviceFrameError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The device returned an unreadable frame."
    }
}

private final class DecodedFrame: @unchecked Sendable {
    let image: CGImage
    let sourceSize: CGSize

    init(data: Data, maximumDimension: Int?) throws {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            throw DeviceFrameError.invalidImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat

        let image: CGImage?
        if let maximumDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                options as CFDictionary
            )
        }

        guard let image else {
            throw DeviceFrameError.invalidImage
        }
        self.image = image
        sourceSize = CGSize(
            width: sourceWidth ?? CGFloat(image.width),
            height: sourceHeight ?? CGFloat(image.height)
        )
    }
}

private final class WeakCaptureSessionBox {
    weak var session: WindowCaptureSession?

    init(_ session: WindowCaptureSession) {
        self.session = session
    }
}
