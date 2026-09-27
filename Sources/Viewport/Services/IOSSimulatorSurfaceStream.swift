import AppKit
import CoreGraphics
import Foundation
import IOSurface
import IndigoTouch

/// Zero-copy iOS Simulator framebuffer via SimulatorKit IOSurface
/// (device IO ports + damage callbacks; not Simulator.app window capture).
@MainActor
final class IOSSimulatorSurfaceStream {
    private let sampleQueue = DispatchQueue(
        label: "com.longden.viewport.simulator-surface",
        qos: .userInteractive
    )
    nonisolated private let frameDelivery = LatestValueDelivery<IOSurfaceRef>(
        discard: { Unmanaged.passUnretained($0).release() }
    )

    // Cleared from `stop()`, which must be callable from nonisolated `deinit`.
    private nonisolated(unsafe) var subscription: UnsafeMutableRawPointer?
    private nonisolated(unsafe) var onFrame: ((IOSurfaceRef) -> Void)?
    private nonisolated(unsafe) var onFailure: ((Error) -> Void)?
    private nonisolated(unsafe) var stallWatchdog: DispatchWorkItem?
    /// Sleeping must not count as a capture stall and force a slower transport.
    nonisolated private let stallDeadline = CaptureStallDeadline(timeout: 5)

    deinit {
        stop()
    }

    var isAvailable: Bool {
        ViewportHIDLoadFrameworks()
    }

    func start(
        deviceID: String,
        frameRate: Int,
        onFrame: @escaping (IOSurfaceRef) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        stop()
        guard isAvailable else {
            throw IOSSimulatorSurfaceError.frameworksUnavailable
        }

        self.onFrame = onFrame
        self.onFailure = onFailure

        var error = [CChar](repeating: 0, count: 512)
        let handle = sampleQueue.sync { () -> UnsafeMutableRawPointer? in
            ViewportSurfaceSubscribe(
                deviceID,
                sampleQueue,
                UInt32(max(1, frameRate)),
                { [weak self] surface in
                    guard let self, let surface else { return }
                    self.noteFrame()
                    let retained = Unmanaged.passUnretained(surface)
                        .retain()
                        .takeUnretainedValue()
                    self.frameDelivery.submit(retained) { [weak self] delivered in
                        defer {
                            Unmanaged.passUnretained(delivered).release()
                        }
                        guard let self, self.subscription != nil else { return }
                        self.onFrame?(delivered)
                    }
                },
                &error,
                error.count
            )
        }

        guard let handle else {
            self.onFrame = nil
            self.onFailure = nil
            let message = error.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.map(String.init(cString:)) ?? "Unknown surface error"
            }
            throw IOSSimulatorSurfaceError.subscribeFailed(message)
        }
        subscription = handle
        stallDeadline.recordActivity()
        scheduleStallWatchdog()
    }

    nonisolated func stop() {
        let handle = subscription
        subscription = nil
        onFrame = nil
        onFailure = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        frameDelivery.clear()
        if let handle {
            ViewportSurfaceUnsubscribe(handle)
        }
    }

    /// Records a frame without reallocating the stall timer on every callback.
    nonisolated private func noteFrame() {
        stallDeadline.recordActivity()
        guard stallWatchdog == nil else { return }
        scheduleStallWatchdog()
    }

    /// Fires onFailure after five awake seconds without a frame.
    nonisolated private func scheduleStallWatchdog(delay: TimeInterval? = nil) {
        let wait = delay ?? stallDeadline.remaining
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.subscription != nil else { return }
            let remaining = self.stallDeadline.remaining
            if self.stallDeadline.shouldRenew {
                self.stallWatchdog = nil
                self.scheduleStallWatchdog(delay: remaining)
                return
            }
            let onFailure = self.onFailure
            self.stop()
            DispatchQueue.main.async {
                onFailure?(IOSSimulatorSurfaceError.subscribeFailed(
                    "Surface stream stalled — no frames received."
                ))
            }
        }
        stallWatchdog = item
        sampleQueue.asyncAfter(
            deadline: .now() + wait,
            execute: item
        )
    }
}

enum IOSSimulatorSurfaceError: LocalizedError {
    case frameworksUnavailable
    case subscribeFailed(String)

    var errorDescription: String? {
        switch self {
        case .frameworksUnavailable:
            "SimulatorKit is unavailable for direct framebuffer capture."
        case let .subscribeFailed(message):
            message
        }
    }
}
