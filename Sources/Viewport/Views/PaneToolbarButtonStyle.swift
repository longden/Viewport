import SwiftUI

/// Subtle hover/press fill for compact pane chrome icon buttons.
struct PaneToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaneToolbarButton(configuration: configuration)
    }
}

private struct PaneToolbarButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fillColor)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var fillColor: Color {
        if configuration.isPressed {
            Color.primary.opacity(0.14)
        } else if isHovered {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
    }
}

/// Hover fill for `Menu` labels and other non-`Button` chrome controls.
struct PaneChromeHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 3
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func paneChromeHover(cornerRadius: CGFloat = 3) -> some View {
        modifier(PaneChromeHoverModifier(cornerRadius: cornerRadius))
    }
}
