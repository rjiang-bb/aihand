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
}
