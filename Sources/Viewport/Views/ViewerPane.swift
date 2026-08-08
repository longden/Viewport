import SwiftUI

struct ViewerPane<Controls: View, Content: View>: View {
    let source: ViewerSource
    var contentCornerRadius: CGFloat = 16
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                sourceMark

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.headline)
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            controls
            content
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: contentCornerRadius,
                        style: .continuous
                    )
                )
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
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
