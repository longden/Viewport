import CoreVideo
import Foundation
import ScreenCaptureKit

/// Workspace recording encode preset. Independent of streaming performance.
enum RecordingQuality: String, CaseIterable, Identifiable {
    /// Exact settings from the original Viewport recorder (pre-optimization).
    case high
    /// Lighter encode for smoother interaction while recording.
    case smooth
    /// Per-pane GPU composite: source-native device frames, clean side-by-side.
    case composite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:
            "High quality"
        case .smooth:
            "Smooth"
        case .composite:
            "Composite"
        }
    }

    var detail: String {
        switch self {
        case .high:
            "Window: 60 fps, BGRA, 1080p"
        case .smooth:
            "Window: 30 fps, NV12, 720p"
        case .composite:
            "Clean panes: GPU + SCK web, 60 fps"
        }
    }

    var systemImage: String {
        switch self {
        case .high:
            "film"
        case .smooth:
            "hare"
        case .composite:
            "rectangle.split.3x1"
        }
    }

    /// Window ScreenCaptureKit path (High / Smooth). Composite uses its own engine.
    var usesWindowCapture: Bool {
        switch self {
        case .high, .smooth:
            true
        case .composite:
            false
        }
    }

    var frameRate: Int32 {
        switch self {
        case .high, .composite:
            60
        case .smooth:
            30
        }
    }

    var pixelFormat: OSType {
        switch self {
        case .high, .composite:
            // Original recorder used full BGRA frames from ScreenCaptureKit.
            // Composite keeps BGRA for a simple Metal/CI → encoder path.
            kCVPixelFormatType_32BGRA
        case .smooth:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    var queueDepth: Int {
        switch self {
        case .high:
            8
        case .smooth:
            3
        case .composite:
            6
        }
    }

    var maximumOutputHeight: CGFloat {
        switch self {
        case .high, .composite:
            1_080
        case .smooth:
            720
        }
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .high, .composite:
            .best
        case .smooth:
            .nominal
        }
    }

    /// Matches the original `max(5_000_000, width * height * 6)` formula.
    func bitRate(width: Int, height: Int) -> Int {
        switch self {
        case .high, .composite:
            max(5_000_000, width * height * 6)
        case .smooth:
            max(1_500_000, width * height * 2)
        }
    }
}
