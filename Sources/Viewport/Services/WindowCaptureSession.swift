import AppKit
import Combine
import CoreGraphics
import Foundation

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

@MainActor
final class WindowCaptureSession: ObservableObject {
    let source: ViewerSource

    @Published private(set) var availableDevices: [StreamedDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var phase: CapturePhase = .idle
    @Published private(set) var inputAccess: InputAccessPhase
    @Published private(set) var capturedFrameSize: CGSize?

    private let frameClient: DeviceFrameClient
    private let androidInput: AndroidDeviceInput?
    private let iOSInput: IOSSimulatorHIDInput?
    private var captureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private weak var previewView: CapturePreviewNSView?

    init(source: ViewerSource) {
        self.source = source
        let frameClient = DeviceFrameClient(source: source)
        self.frameClient = frameClient
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
    }

    var selectedDevice: StreamedDevice? {
        availableDevices.first(where: { $0.id == selectedDeviceID })
    }

    var capturedWindowSize: CGSize? {
        capturedFrameSize
    }

    func attachPreview(_ view: CapturePreviewNSView) {
        previewView = view
    }

    func detachPreview(_ view: CapturePreviewNSView) {
        guard previewView === view else { return }
        previewView = nil
    }

    func refreshInputAccess() {
        inputAccess = frameClient.isAvailable
            && (source != .iOS || iOSInput?.isAvailable == true)
            ? .ready
            : .permissionNeeded
    }

    func requestInputAccess() {
        // Direct ADB and Simulator HID input do not use macOS Accessibility.
        refreshInputAccess()
    }

    func refreshWindows() {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        if phase != .live {
            phase = .searching
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
                guard let selected = devices.first(where: {
                    $0.id == previousSelection
                }) ?? devices.first else {
                    selectedDeviceID = nil
                    stopCapture()
                    phase = .noWindow
                    return
                }

                if selected.id != previousSelection || captureTask == nil {
                    selectDevice(selected.id)
                }
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

    func selectDevice(_ id: String) {
        guard availableDevices.contains(where: { $0.id == id }) else {
            return
        }
        selectedDeviceID = id
        startCapture(deviceID: id)
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        capturedFrameSize = nil
        previewView?.clear()
    }

    func performGesture(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval
    ) {
        guard let device = selectedDevice else { return }
        let distance = hypot(end.x - start.x, end.y - start.y)

        if source == .android,
           let androidInput,
           let deviceSize = capturedFrameSize ?? device.pixelSize {
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
                : max(2, min(Int(duration * 60), 30))
            if steps > 1 {
                let delay = max(duration / Double(steps), 0.008)
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
            } else {
                try? await Task.sleep(for: .milliseconds(45))
            }
            iOSInput.touchUp(at: end, udid: device.id)
            // CoreSimulator can leave an in-flight simctl screenshot command
            // stale after private HID delivery. Replace the polling task while
            // keeping the last frame visible so navigation updates immediately.
            startCapture(
                deviceID: device.id,
                preservingCurrentFrame: true
            )
        }
    }

    @discardableResult
    func postKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let device = selectedDevice else { return false }
        if source == .android, let androidInput {
            Task {
                await androidInput.key(serial: device.id, event: event)
            }
            return true
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
        if !preservingCurrentFrame {
            previewView?.clear()
            capturedFrameSize = nil
            phase = .connecting
        }

        captureTask = Task { [weak self] in
            guard let self else { return }
            var hasDisplayedFrame = preservingCurrentFrame
                && capturedFrameSize != nil
            var consecutiveFailures = 0

            while !Task.isCancelled, selectedDeviceID == deviceID {
                do {
                    let data = try await frameClient.captureFrame(
                        deviceID: deviceID
                    )
                    try Task.checkCancellation()
                    guard selectedDeviceID == deviceID,
                          let image = NSImage(data: data),
                          let cgImage = image.cgImage(
                            forProposedRect: nil,
                            context: nil,
                            hints: nil
                          ) else {
                        throw DeviceFrameError.invalidImage
                    }

                    capturedFrameSize = CGSize(
                        width: cgImage.width,
                        height: cgImage.height
                    )
                    previewView?.display(cgImage)
                    consecutiveFailures = 0
                    if !hasDisplayedFrame {
                        hasDisplayedFrame = true
                        phase = .live
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    if !hasDisplayedFrame || consecutiveFailures >= 4 {
                        phase = .failed(error.localizedDescription)
                    }
                }

                try? await Task.sleep(for: frameClient.frameInterval)
            }
        }
    }
}

private enum DeviceFrameError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The device returned an unreadable frame."
    }
}
