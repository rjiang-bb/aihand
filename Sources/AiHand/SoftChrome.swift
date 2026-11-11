import AppKit
import SwiftUI

/// Shared fills for floating panels — dark mode uses charcoal, not pure black.
enum SoftChrome {
    /// ~#242424 — charcoal card fill; darker than embedded session rows (~0.18).
    private static let darkWhite: CGFloat = 0.14

    static func cardFill(dark: Bool) -> Color {
        dark ? Color(white: darkWhite) : .white
    }

    static func cardNSColor(dark: Bool) -> NSColor {
        dark ? NSColor(white: darkWhite, alpha: 1) : .white
    }

    /// Inner hover stroke — white on dark chrome, dark gray on light.
    static func hoverInnerBorder(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.92) : Color(white: 0.28)
    }
}

extension View {
    /// Inset stroke that appears on hover (white in dark mode, dark gray in light).
    func softHoverInnerBorder<S: InsettableShape>(
        _ shape: S,
        inset: CGFloat = 2.5,
        lineWidth: CGFloat = 1.25,
        enabled: Bool = true
    ) -> some View {
        modifier(
            SoftHoverInnerBorderModifier(
                shape: shape,
                inset: inset,
                lineWidth: lineWidth,
                enabled: enabled
            )
        )
    }
}

private struct SoftHoverInnerBorderModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let inset: CGFloat
    let lineWidth: CGFloat
    var enabled: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled {
                    shape
                        .inset(by: inset)
                        .strokeBorder(
                            SoftChrome.hoverInnerBorder(dark: colorScheme == .dark)
                                .opacity(hovering ? 1 : 0),
                            lineWidth: lineWidth
                        )
                        .animation(.easeOut(duration: 0.12), value: hovering)
                        .allowsHitTesting(false)
                }
            }
            .onHover { value in
                guard enabled else {
                    hovering = false
                    return
                }
                hovering = value
            }
            // Hand cursor via AppKit cursor rects (onHover `set` alone loses to cursorUpdate).
            .pointerCursor(enabled: enabled)
    }
}
