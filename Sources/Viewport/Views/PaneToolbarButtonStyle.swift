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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

    /// Fades whichever horizontal edges have buttons scrolled out of the pane toolbar.
    func paneToolbarScrollFade() -> some View {
        modifier(PaneToolbarScrollFadeModifier())
    }
}

struct PaneToolbarScrollOverflow: Equatable {
    var showsLeadingFade: Bool
    var showsTrailingFade: Bool

    init(visibleMinX: CGFloat, visibleMaxX: CGFloat, contentWidth: CGFloat) {
        let slop: CGFloat = 1
        showsLeadingFade = visibleMinX > slop
        showsTrailingFade = contentWidth - visibleMaxX > slop
    }
}

private struct PaneToolbarScrollFadeModifier: ViewModifier {
    @State private var overflow = PaneToolbarScrollOverflow(
        visibleMinX: 0,
        visibleMaxX: 0,
        contentWidth: 0
    )

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: PaneToolbarScrollOverflow.self) { geometry in
                PaneToolbarScrollOverflow(
                    visibleMinX: geometry.visibleRect.minX,
                    visibleMaxX: geometry.visibleRect.maxX,
                    contentWidth: geometry.contentSize.width
                )
            } action: { _, next in
                overflow = next
            }
            .mask {
                GeometryReader { proxy in
                    let fadeWidth = min(30, proxy.size.width / 5)
                    HStack(spacing: 0) {
                        edgeFade(isActive: overflow.showsLeadingFade, leading: true)
                            .frame(width: fadeWidth)
                        Color.black
                        edgeFade(isActive: overflow.showsTrailingFade, leading: false)
                            .frame(width: fadeWidth)
                    }
                    .animation(.easeOut(duration: 0.16), value: overflow)
                }
            }
    }

    private func edgeFade(isActive: Bool, leading: Bool) -> some View {
        let hidden = Color.black.opacity(isActive ? 0 : 1)
        let solid = Color.black
        return LinearGradient(
            colors: leading ? [hidden, solid] : [solid, hidden],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
