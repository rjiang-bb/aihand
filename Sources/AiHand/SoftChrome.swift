import AppKit
import SwiftUI

/// Shared fills for floating panels — dark mode uses charcoal, not pure black.
enum SoftChrome {
    /// ~#242424 — charcoal card fill; darker than embedded session rows (~0.18).
    private static let darkWhite: CGFloat = 0.14
    /// Outer radius of workspace / worktree picker cards.
    static let pickerCornerRadius: CGFloat = 22

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

    /// AppKit counterpart of `hoverInnerBorder` (session / menu row hover stroke).
    static func hoverInnerBorderNSColor(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.28, alpha: 1)
    }
}

/// Rounded corners that match a picker card edge — square mid-list, card radius on the top/bottom row.
struct SoftChromeCardEdge: InsettableShape, Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var insetAmount: CGFloat = 0

    static var square: SoftChromeCardEdge { SoftChromeCardEdge() }
    static var topOfCard: SoftChromeCardEdge { SoftChromeCardEdge(top: SoftChrome.pickerCornerRadius) }
    static var bottomOfCard: SoftChromeCardEdge { SoftChromeCardEdge(bottom: SoftChrome.pickerCornerRadius) }
    static var fullCard: SoftChromeCardEdge {
        SoftChromeCardEdge(top: SoftChrome.pickerCornerRadius, bottom: SoftChrome.pickerCornerRadius)
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let tl = min(max(0, top - insetAmount), r.width / 2, r.height / 2)
        let tr = tl
        let bl = min(max(0, bottom - insetAmount), r.width / 2, r.height / 2)
        let br = bl
        var path = Path()
        path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: r.maxX - tr, y: r.minY + tr),
                radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: r.maxX - br, y: r.maxY - br),
                radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: r.minX + bl, y: r.maxY - bl),
                radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: r.minX + tl, y: r.minY + tl),
                radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> SoftChromeCardEdge {
        SoftChromeCardEdge(top: top, bottom: bottom, insetAmount: insetAmount + amount)
    }
}

extension View {
    /// Hover fill + stroke that hugs the picker card (flush left/right; square mid-list).
    func pickerRowHoverChrome(_ edge: SoftChromeCardEdge, hovering: Bool, selected: Bool = false) -> some View {
        modifier(PickerRowHoverChromeModifier(edge: edge, hovering: hovering, selected: selected))
    }
}

private struct PickerRowHoverChromeModifier: ViewModifier {
    let edge: SoftChromeCardEdge
    let hovering: Bool
    var selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                edge.fill(Color.primary.opacity(hovering || selected ? 0.08 : 0))
            )
            .overlay {
                if hovering {
                    edge
                        .inset(by: 1.5)
                        .strokeBorder(
                            SoftChrome.hoverInnerBorder(dark: colorScheme == .dark),
                            lineWidth: 1.25
                        )
                }
            }
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
