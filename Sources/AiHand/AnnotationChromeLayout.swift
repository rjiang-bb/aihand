import CoreGraphics
import Foundation

/// Vertical placement for the annotation hint strip + tools relative to the hand picker.
/// Raised while the hand toolbar is visible; docks to the bottom once it fades.
enum AnnotationChromeLayout {
    /// Matches `Toolbar.place` — bottom inset of the hand picker.
    static let dockedHintBottomInset: CGFloat = 14
    /// Approximate hand-picker height (40pt buttons + 8pt insets).
    static let handToolbarHeight: CGFloat = 56
    /// Gap between the hand picker top and the hint strip while both are visible.
    static let raisedGapAboveHand: CGFloat = 12
    /// Hint strip sits just above the hand picker on enter (before the picker fades).
    static let raisedHintBottomInset: CGFloat =
        dockedHintBottomInset + handToolbarHeight + raisedGapAboveHand
    static let toolsGapAboveHint: CGFloat = 10
    /// Fallback tools height when the hint strip isn't shown (armed/recording chrome).
    static let toolsFallbackAboveHint: CGFloat = 50

    static let slideDuration: TimeInterval = 0.35

    static func hintOriginY(visibleMinY: CGFloat, docked: Bool) -> CGFloat {
        visibleMinY + (docked ? dockedHintBottomInset : raisedHintBottomInset)
    }

    /// Destination Y for tools/video chrome. Uses `docked` + hint height so a slide targets
    /// the final slot even while the hint strip is still mid-animation at the old origin.
    static func toolsOriginY(hintHeight: CGFloat, visibleMinY: CGFloat, docked: Bool) -> CGFloat {
        let hintY = hintOriginY(visibleMinY: visibleMinY, docked: docked)
        if hintHeight > 0 {
            return hintY + hintHeight + toolsGapAboveHint
        }
        return hintY + toolsFallbackAboveHint
    }

    static func toolsOriginY(hintFrame: CGRect, visibleMinY: CGFloat, docked: Bool) -> CGFloat {
        toolsOriginY(hintHeight: hintFrame.height, visibleMinY: visibleMinY, docked: docked)
    }
}
