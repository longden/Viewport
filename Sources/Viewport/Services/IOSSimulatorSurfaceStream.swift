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

    /// Stall timeout in seconds. If no frame arrives within this interval
    /// after subscription or after the last frame, `onFailure` fires.
    private let stallTimeout: TimeInterval = 5

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
                    self.resetStallWatchdog()
                    let retained = Unmanaged.passUnretained(surface)
                        .retain()
                        .takeUnretainedValue()
                    self.frameDelivery.submit(retained) { delivered in
                        Task { @MainActor [weak self] in
                            defer {
                                Unmanaged.passUnretained(delivered).release()
                            }
                            guard let self, self.subscription != nil else { return }
                            self.onFrame?(delivered)
                        }
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

    /// Reschedules the stall watchdog from the sample queue.
    nonisolated private func resetStallWatchdog() {
        stallWatchdog?.cancel()
        scheduleStallWatchdog()
    }

    /// Fires onFailure if no frame arrives within `stallTimeout`.
    nonisolated private func scheduleStallWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.subscription != nil else { return }
            let onFailure = self.onFailure
            self.stop()
            Task { @MainActor in
                onFailure?(IOSSimulatorSurfaceError.subscribeFailed(
                    "Surface stream stalled — no frames received."
                ))
            }
        }
        stallWatchdog = item
        sampleQueue.asyncAfter(
            deadline: .now() + stallTimeout,
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
