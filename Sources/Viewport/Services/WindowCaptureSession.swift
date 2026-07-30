import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum CapturePhase: Equatable {
    case idle
    case permissionNeeded
    case searching
    case connecting
    case live
    case noWindow
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            "Waiting"
        case .permissionNeeded:
            "Screen access"
        case .searching:
            "Looking"
        case .connecting:
            "Connecting"
        case .live:
            "Live"
        case .noWindow:
            "Not found"
        case .failed:
            "Capture error"
        }
    }
}

struct CapturableWindow: Identifiable {
    let window: SCWindow
    let descriptor: CaptureDescriptor

    var id: CGWindowID { window.windowID }

    var displayName: String {
        if !descriptor.windowTitle.isEmpty {
            return descriptor.windowTitle
        }
        return descriptor.applicationName
    }
}

@MainActor
final class WindowCaptureSession: NSObject, ObservableObject {
    let source: ViewerSource

    @Published private(set) var availableWindows: [CapturableWindow] = []
    @Published private(set) var selectedWindowID: CGWindowID?
    @Published private(set) var phase: CapturePhase = .idle

    private let sampleQueue: DispatchQueue
    nonisolated private let frameDelivery = LatestFrameDelivery()
    private var activeStream: SCStream?
    private var captureGeneration = UUID()
    private var refreshGeneration = UUID()
    private var lifecycleTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private weak var previewView: CapturePreviewNSView?

    init(source: ViewerSource) {
        self.source = source
        sampleQueue = DispatchQueue(
            label: "com.longden.viewport.capture.\(source.rawValue)",
            qos: .userInitiated
        )
        super.init()
    }

    deinit {
        lifecycleTask?.cancel()
        refreshTask?.cancel()
    }

    var selectedWindow: CapturableWindow? {
        availableWindows.first(where: { $0.id == selectedWindowID })
    }

    func attachPreview(_ view: CapturePreviewNSView) {
        previewView = view
    }

    func detachPreview(_ view: CapturePreviewNSView) {
        guard previewView === view else { return }
        previewView = nil
    }

    func refreshWindows() {
        guard CGPreflightScreenCaptureAccess() else {
            phase = .permissionNeeded
            availableWindows = []
            selectedWindowID = nil
            stopCapture()
            return
        }

        if phase != .live {
            phase = .searching
        }
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation

        refreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                let matches = content.windows
                    .compactMap { window -> CapturableWindow? in
                        let descriptor = CaptureDescriptor(
                            applicationName: window.owningApplication?.applicationName ?? "",
                            bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
                            windowTitle: window.title ?? ""
                        )

                        guard descriptor.matches(self.source),
                              window.frame.width > 120,
                              window.frame.height > 180 else {
                            return nil
                        }

                        return CapturableWindow(window: window, descriptor: descriptor)
                    }
                    .sorted { lhs, rhs in
                        lhs.displayName.localizedStandardCompare(rhs.displayName)
                            == .orderedAscending
                    }

                guard !Task.isCancelled,
                      self.refreshGeneration == generation else {
                    return
                }

                let previousSelection = self.selectedWindowID
                self.availableWindows = matches

                guard let selected = matches.first(where: { $0.id == previousSelection })
                    ?? matches.first else {
                    self.selectedWindowID = nil
                    self.stopCapture()
                    self.phase = .noWindow
                    return
                }

                if selected.id == previousSelection,
                   self.phase == .live,
                   self.activeStream != nil {
                    return
                }

                self.selectWindow(selected.id)
            } catch {
                guard !Task.isCancelled,
                      self.refreshGeneration == generation else {
                    return
                }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func selectWindow(_ id: CGWindowID) {
        guard let target = availableWindows.first(where: { $0.id == id }) else {
            return
        }

        selectedWindowID = id
        startCapture(of: target.window)
    }

    func activateSelectedApplication() {
        guard let processID = selectedWindow?
            .window
            .owningApplication?
            .processID,
            let application = NSRunningApplication(
                processIdentifier: processID
            ) else {
            return
        }

        application.activate(options: [.activateAllWindows])
    }

    func stopCapture() {
        captureGeneration = UUID()
        lifecycleTask?.cancel()
        let stream = activeStream
        activeStream = nil
        frameDelivery.clear()
        previewView?.clear()

        guard let stream else { return }
        lifecycleTask = Task {
            try? await stream.stopCapture()
        }
    }

    private func startCapture(of window: SCWindow) {
        let generation = UUID()
        captureGeneration = generation
        phase = .connecting

        lifecycleTask?.cancel()
        let previousStream = activeStream
        activeStream = nil

        lifecycleTask = Task { [weak self] in
            guard let self else { return }

            if let previousStream {
                try? await previousStream.stopCapture()
            }

            guard !Task.isCancelled,
                  self.captureGeneration == generation else {
                return
            }

            let configuration = SCStreamConfiguration()
            let scale = min(
                2,
                1_440 / max(window.frame.width, 1),
                1_800 / max(window.frame.height, 1)
            )
            configuration.width = max(Int(window.frame.width * scale), 1)
            configuration.height = max(Int(window.frame.height * scale), 1)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
            configuration.queueDepth = 2
            configuration.showsCursor = false
            configuration.capturesAudio = false
            // Keep the framework default. On macOS 26.5, assigning a bridged
            // NSColor.cgColor can trap inside SCStreamConfiguration.copy().

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )

            do {
                try stream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: self.sampleQueue
                )
                self.activeStream = stream
                try await stream.startCapture()

                guard !Task.isCancelled,
                      self.captureGeneration == generation,
                      self.activeStream === stream else {
                    try? await stream.stopCapture()
                    return
                }

                self.phase = .live
            } catch {
                guard !Task.isCancelled,
                      self.captureGeneration == generation,
                      self.activeStream === stream else {
                    return
                }
                self.activeStream = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}

extension WindowCaptureSession: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusRawValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRawValue),
        status == .complete else {
            return
        }

        frameDelivery.submit(
            stream: stream,
            frame: sampleBuffer
        ) { [weak self] payload in
            Task { @MainActor in
                guard let self,
                      self.activeStream === payload.stream else {
                    return
                }
                self.previewView?.display(payload.frame)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.activeStream === stream else { return }
            self.activeStream = nil
            self.phase = .failed(error.localizedDescription)
        }
    }
}

private final class LatestFrameDelivery: @unchecked Sendable {
    struct Payload {
        let stream: SCStream
        let frame: CMSampleBuffer
    }

    private let lock = NSLock()
    private var latestPayload: Payload?
    private var deliveryIsScheduled = false

    func submit(
        stream: SCStream,
        frame: CMSampleBuffer,
        deliver: @escaping (Payload) -> Void
    ) {
        lock.lock()
        latestPayload = Payload(stream: stream, frame: frame)
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        scheduleDelivery(deliver)
    }

    func clear() {
        lock.lock()
        latestPayload = nil
        lock.unlock()
    }

    private func scheduleDelivery(
        _ deliver: @escaping (Payload) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.deliverLatest(deliver)
        }
    }

    private func deliverLatest(
        _ deliver: @escaping (Payload) -> Void
    ) {
        lock.lock()
        let payload = latestPayload
        latestPayload = nil
        lock.unlock()

        if let payload {
            deliver(payload)
        }

        lock.lock()
        let hasAnotherFrame = latestPayload != nil
        if !hasAnotherFrame {
            deliveryIsScheduled = false
        }
        lock.unlock()

        if hasAnotherFrame {
            scheduleDelivery(deliver)
        }
    }
}
