import SwiftUI

struct WebNetworkOverlayPanel: View {
    @ObservedObject var model: WebNetworkOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Network")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    model.refreshFromPerformance()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh from Resource Timing")

                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.entries.isEmpty {
                Text("Waiting for fetch / resource activity…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.entries.prefix(40)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.url)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 8) {
                                    Text(entry.method)
                                    if let status = entry.status {
                                        Text("\(status)")
                                    }
                                    if let duration = entry.durationMS {
                                        Text(String(format: "%.0f ms", duration))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: 320, maxHeight: 220)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct PaneFPSHud: View {
    let framesPerSecond: Double

    var body: some View {
        Text(String(format: "%.0f FPS", framesPerSecond))
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .help("Live pane frame rate")
    }
}
