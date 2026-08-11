import SwiftUI

struct PaneFPSHud: View {
    let framesPerSecond: Double

    var body: some View {
        Text(String(format: "%.0f FPS", framesPerSecond))
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .help("Live pane frame rate")
    }
}
