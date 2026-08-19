import SwiftUI

struct PaneFPSHud: View {
    let meter: FrameRateMeter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let fps = meter.age()
            if fps > 0 {
                Text(String(format: "%.0f FPS", fps))
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
                    .help("Live pane frame rate")
            }
        }
    }
}
