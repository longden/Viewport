import Foundation

/// Rolling FPS estimate from frame-delivery timestamps.
final class FrameRateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [CFAbsoluteTime] = []
    private let windowSeconds: CFTimeInterval

    init(windowSeconds: CFTimeInterval = 1.0) {
        self.windowSeconds = max(windowSeconds, 0.25)
    }

    func record(at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock()
        defer { lock.unlock() }
        timestamps.append(time)
        pruneLocked(now: time)
    }

    /// Age out stale samples without recording a new frame (idle decay).
    func age(at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: time)
        return framesPerSecondLocked()
    }

    var framesPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        return framesPerSecondLocked()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        timestamps.removeAll(keepingCapacity: true)
    }

    private func pruneLocked(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        // Drop from the front without O(n²) removeFirst loops.
        if let firstKeep = timestamps.firstIndex(where: { $0 >= cutoff }) {
            if firstKeep > 0 {
                timestamps.removeFirst(firstKeep)
            }
        } else {
            timestamps.removeAll(keepingCapacity: true)
        }
    }

    private func framesPerSecondLocked() -> Double {
        guard timestamps.count >= 2,
              let first = timestamps.first,
              let last = timestamps.last,
              last > first else {
            return 0
        }
        return Double(timestamps.count - 1) / (last - first)
    }
}
