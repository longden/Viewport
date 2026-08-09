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
        let cutoff = time - windowSeconds
        while let first = timestamps.first, first < cutoff {
            timestamps.removeFirst()
        }
    }

    var framesPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        guard timestamps.count >= 2,
              let first = timestamps.first,
              let last = timestamps.last,
              last > first else {
            return 0
        }
        return Double(timestamps.count - 1) / (last - first)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        timestamps.removeAll(keepingCapacity: true)
    }
}
