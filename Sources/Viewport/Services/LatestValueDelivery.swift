import Foundation

/// Coalesces producer bursts so at most one delivery is in flight and only the
/// newest pending value is retained.
///
/// `deliver` must run synchronously on `queue`. Spawning `Task { @MainActor }`
/// (or `DispatchQueue.main.async`) inside `deliver` returns immediately, which
/// defeats coalescing and can display frames out of order.
final class LatestValueDelivery<Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let deliver: @Sendable (Value) -> Void
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let discard: @Sendable (Value) -> Void
    private var latest: Entry?
    private var deliveryIsScheduled = false

    init(
        queue: DispatchQueue = .main,
        discard: @escaping @Sendable (Value) -> Void = { _ in }
    ) {
        self.queue = queue
        self.discard = discard
    }

    func submit(
        _ value: Value,
        deliver: @escaping @Sendable (Value) -> Void
    ) {
        lock.lock()
        let previous = latest
        latest = Entry(value: value, deliver: deliver)
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()

        if let previous {
            discard(previous.value)
        }
        if shouldSchedule {
            scheduleDelivery()
        }
    }

    func clear() {
        lock.lock()
        let previous = latest
        latest = nil
        lock.unlock()

        if let previous {
            discard(previous.value)
        }
    }

    private func scheduleDelivery() {
        queue.async { [weak self] in
            self?.deliverLatest()
        }
    }

    private func deliverLatest() {
        lock.lock()
        let entry = latest
        latest = nil
        lock.unlock()

        if let entry {
            entry.deliver(entry.value)
        }

        lock.lock()
        let hasAnotherValue = latest != nil
        if !hasAnotherValue {
            deliveryIsScheduled = false
        }
        lock.unlock()

        if hasAnotherValue {
            scheduleDelivery()
        }
    }
}
