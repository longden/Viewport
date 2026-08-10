import SwiftUI

struct ViewerPane<Controls: View, Content: View>: View {
    let source: ViewerSource
    var titleSuffix: String? = nil
    var contentCornerRadius: CGFloat = 16
    var onClose: (() -> Void)? = nil
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                sourceMark

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title + (titleSuffix ?? ""))
                        .font(.headline)
                        .lineLimit(1)
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PaneToolbarButtonStyle())
                    .help(closeHelp)
                    .accessibilityLabel(closeAccessibilityLabel)
                }
            }

            controls
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: contentCornerRadius,
                        style: .continuous
                    )
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
        .clipped()
    }

    private var sourceMark: some View {
        Image(systemName: source.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(source.accentColor)
            .frame(width: 34, height: 34)
            .background(
                source.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var closeHelp: String {
        switch source {
        case .iOS:
            "Shut down Simulator and close this pane"
        case .android:
            "Shut down emulator and close this pane"
        case .web:
            "Hide Web pane"
        }
    }

    private var closeAccessibilityLabel: String {
        switch source {
        case .iOS:
            "Shut down Simulator"
        case .android:
            "Shut down emulator"
        case .web:
            "Hide Web pane"
        }
    }
}

extension ViewerSource {
    var accentColor: Color {
        switch self {
        case .web:
            Color(red: 0.18, green: 0.62, blue: 0.92)
        case .android:
            Color(red: 0.25, green: 0.72, blue: 0.45)
        case .iOS:
            Color(red: 0.62, green: 0.42, blue: 0.94)
        }
    }
}
