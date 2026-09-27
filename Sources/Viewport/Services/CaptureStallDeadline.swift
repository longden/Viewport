import Foundation

/// Measures capture inactivity in awake time. On macOS DispatchTime uses the
/// uptime clock, so sleep and wall-clock adjustments cannot expire the deadline.
final class CaptureStallDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var lastActivity: TimeInterval

    init(
        timeout: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        }
    ) {
        self.timeout = timeout
        self.now = now
        lastActivity = now()
    }

    func recordActivity() {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = now()
    }

    var remaining: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(0, timeout - max(0, now() - lastActivity))
    }

    /// GCD can deliver the watchdog slightly early. A sub-millisecond remainder
    /// is expiry, not a reason to arm another timer.
    var shouldRenew: Bool {
        remaining > 0.001
    }
}
