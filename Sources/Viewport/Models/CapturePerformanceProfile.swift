import Foundation
import CoreGraphics

enum CapturePerformanceProfile: String, CaseIterable, Identifiable {
    case smooth
    case balanced
    case sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth:
            "Smooth"
        case .balanced:
            "Balanced"
        case .sharp:
            "Sharp"
        }
    }

    var detail: String {
        switch self {
        case .smooth:
            "Fastest updates"
        case .balanced:
            "Clearer frames"
        case .sharp:
            "Full detail"
        }
    }

    var systemImage: String {
        switch self {
        case .smooth:
            "hare"
        case .balanced:
            "gauge.with.dots.needle.50percent"
        case .sharp:
            "sparkles.rectangle.stack"
        }
    }

    var maximumDisplayDimension: Int? {
        switch self {
        case .smooth:
            1_024
        case .balanced:
            1_400
        case .sharp:
            1_920
        }
    }

    /// Direct capture launches an `adb` or `simctl` process for every frame.
    /// Keep that fallback responsive without letting process creation run
    /// unbounded when a capture happens to finish very quickly.
    var directCaptureInterval: Duration {
        switch self {
        case .smooth:
            .milliseconds(63)
        case .balanced:
            .milliseconds(100)
        case .sharp:
            .milliseconds(167)
        }
    }

    var targetFrameRate: Int {
        switch self {
        case .smooth:
            60
        case .balanced:
            30
        case .sharp:
            20
        }
    }

    /// Host-window capture can sustain higher rates than process-per-frame
    /// fallbacks. Prefer this for Simulator / Emulator ScreenCaptureKit paths.
    var hostWindowFrameRate: Int {
        switch self {
        case .smooth:
            60
        case .balanced:
            30
        case .sharp:
            20
        }
    }

    /// Cap ScreenCaptureKit output scale. Retina 2× of a large Simulator
    /// window is expensive to convert every frame and feels choppy.
    var maximumHostWindowScale: CGFloat {
        switch self {
        case .smooth:
            1
        case .balanced:
            1.5
        case .sharp:
            2
        }
    }

    /// Workspace recording cadence. Balanced/Sharp stream device content at
    /// 30/20 fps, so encoding the workspace at 60 fps would waste cycles on
    /// duplicate frames.
    var recordingFrameRate: Int32 {
        switch self {
        case .smooth:
            60
        case .balanced, .sharp:
            30
        }
    }

    var scrcpyVideoBitRate: Int {
        switch self {
        case .smooth:
            4_000_000
        case .balanced:
            6_000_000
        case .sharp:
            8_000_000
        }
    }
}
