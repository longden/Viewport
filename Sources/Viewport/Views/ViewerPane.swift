import SwiftUI

struct ViewerPane<Controls: View, Content: View>: View {
    let source: ViewerSource
    var titleSuffix: String? = nil
    /// Clip radius for the live surface (ADB / Simulator / Web).
    var contentCornerRadius: CGFloat = 14
    var onClose: (() -> Void)? = nil
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
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
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background {
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.045),
                        Color.primary.opacity(0.012),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: contentCornerRadius,
                        style: .continuous
                    )
                )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sourceMark: some View {
        Image(systemName: source.systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(source.accentColor)
            .frame(width: 28, height: 28)
            .background(
                source.accentColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
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
    /// Shared live-surface corner radius for ADB / Simulator / Web previews.
    static let surfaceCornerRadius: CGFloat = 14

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
