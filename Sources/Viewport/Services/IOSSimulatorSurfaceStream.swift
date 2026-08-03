import AppKit
import CoreGraphics
import Foundation
import IOSurface
import IndigoTouch

/// Zero-copy iOS Simulator framebuffer via SimulatorKit IOSurface.
@MainActor
final class IOSSimulatorSurfaceStream {
    private let sampleQueue = DispatchQueue(
        label: "com.longden.viewport.simulator-surface",
        qos: .userInteractive
    )
    nonisolated private let frameDelivery = LatestSurfaceFrameDelivery()

    private var subscription: UnsafeMutableRawPointer?
    private var onFrame: ((IOSurfaceRef) -> Void)?
    private var onFailure: ((Error) -> Void)?

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
                    self.frameDelivery.submit(surface) { delivered in
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
    }

    func stop() {
        let handle = subscription
        subscription = nil
        onFrame = nil
        onFailure = nil
        frameDelivery.clear()
        if let handle {
            ViewportSurfaceUnsubscribe(handle)
        }
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

private final class LatestSurfaceFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: IOSurfaceRef?
    private var deliveryIsScheduled = false

    func submit(
        _ surface: IOSurfaceRef,
        deliver: @escaping @Sendable (IOSurfaceRef) -> Void
    ) {
        // Retain across the async hop; `deliver` takes ownership and must release.
        let retained = Unmanaged.passUnretained(surface).retain().takeUnretainedValue()
        lock.lock()
        let previous = latest
        latest = retained
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()
        if let previous {
            Unmanaged.passUnretained(previous).release()
        }
        guard shouldSchedule else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.deliverLatest(deliver)
        }
    }

    func clear() {
        lock.lock()
        let previous = latest
        latest = nil
        lock.unlock()
        if let previous {
            Unmanaged.passUnretained(previous).release()
        }
    }

    private func deliverLatest(
        _ deliver: @escaping @Sendable (IOSurfaceRef) -> Void
    ) {
        lock.lock()
        let surface = latest
        latest = nil
        lock.unlock()

        if let surface {
            // Ownership transfers to `deliver`.
            deliver(surface)
        }

        lock.lock()
        let hasAnother = latest != nil
        if !hasAnother {
            deliveryIsScheduled = false
        }
        lock.unlock()

        if hasAnother {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.deliverLatest(deliver)
            }
        }
    }
}
