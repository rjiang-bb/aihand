#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Composer regression harness: hosts the real SwiftUI `ComposerPromptEditor` in a key
/// window and drives it with real `NSEvent`s (⇧ detection needs `NSApp.currentEvent`,
/// so events go through `NSApp.postEvent`). Checks markdown source, caret, and layout
/// geometry; renders `/tmp/probe-<name>.png` for eyeballing.
///
/// Run: `./scripts/composer-probe.sh [section…]` (sections: quotes lists ordered fences inline height).
enum ComposerProbe {
    final class Model: ObservableObject {
        @Published var text = ""
        @Published var focused = true
        @Published var height: CGFloat = 22
        var submits = 0
    }

    struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            ComposerPromptEditor(
                text: $model.text, focused: $model.focused, height: $model.height,
                placeholder: "Prompt…", darkChrome: true,
                onSubmit: { model.submits += 1 }, onHeightChange: nil
            )
            .frame(width: 340, height: max(22, model.height))
            .padding(10)
            .frame(width: 360, height: 420, alignment: .top)
            .background(Color(white: 0.16))
        }
    }

    static var model = Model()
    static var window: NSWindow!
    static var tv: ComposerPromptTextView!
    static var failures: [String] = []
    static var checks = 0
    static var usedAppSendEvent = true

    // MARK: event plumbing

    static func pump(_ seconds: TimeInterval = 0.03) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005),
                                       inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    static func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: UInt16(code)
        ) else { return }
        // Through the real queue so NSApp.currentEvent (⇧ detection) is set.
        if usedAppSendEvent { NSApp.postEvent(e, atStart: false) } else { window.sendEvent(e) }
        pump()
    }

    static func type(_ s: String) {
        for ch in s { key(0, String(ch)) }
    }
    static func tab() { key(kVK_Tab, "\t") }
    static func shiftTab() { key(kVK_Tab, "\u{19}", .shift) }
    static func shiftReturn() { key(kVK_Return, "\r", .shift) }
    static func enter() { key(kVK_Return, "\r") }
    static func backspace() { key(kVK_Delete, "\u{7f}") }
    static func down() { key(kVK_DownArrow, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.numericPad, .function]) }
    static func up() { key(kVK_UpArrow, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.numericPad, .function]) }

    static func reset(_ text: String = "", caret: Int? = nil) {
        model.text = text
        pump(0.05)
        let len = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(caret ?? len, len), length: 0))
        pump(0.05)
    }

    static var source: String { model.text }
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: " ", with: "·")
    }

    static func expect(_ label: String, _ want: String) {
        checks += 1
        if source != want { failures.append("\(label)\n     want: \(esc(want))\n      got: \(esc(source))") }
    }
    static func expectTrue(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures.append("\(label)  \(detail())") }
    }

    // MARK: geometry (view coords, flipped)

    static func glyphX(_ charIndex: Int) -> CGFloat {
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let g = lm.glyphIndexForCharacter(at: charIndex)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return tv.textContainerOrigin.x + frag.minX + lm.location(forGlyphAt: g).x
    }
    static func lineUsed(_ charIndex: Int) -> NSRect {
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let g = lm.glyphIndexForCharacter(at: charIndex)
        var r = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        r.origin.x += tv.textContainerOrigin.x
        r.origin.y += tv.textContainerOrigin.y
        return r
    }
    static func idx(_ needle: String) -> Int { (source as NSString).range(of: needle).location }

    // MARK: render

    static func render(_ name: String) {
        pump(0.1)
        guard let view = window.contentView else { return }
        let b = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: b) else { return }
        view.cacheDisplay(in: b, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/probe-\(name).png"))
        }
    }

    static func findTextView(_ v: NSView) -> ComposerPromptTextView? {
        if let t = v as? ComposerPromptTextView { return t }
        for s in v.subviews { if let t = findTextView(s) { return t } }
        return nil
    }

    // MARK: run

    static func run() -> Bool {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(0.4)
        tv = findTextView(window.contentView!)
        window.makeFirstResponder(tv)
        pump(0.1)

        // Path check: does a real event reach the text view through NSApp?
        reset("")
        type("x")
        if source != "x" {
            usedAppSendEvent = false
            reset("")
            type("x")
        }
        print("event path: \(usedAppSendEvent ? "NSApp.sendEvent" : "window.sendEvent") key=\(window.isKeyWindow) text=\(esc(source))")

        let sections: [(String, () -> Void)] = [
            ("quotes", quotes), ("lists", lists), ("ordered", ordered),
            ("fences", fences), ("inline", inline), ("height", height),
        ]
        let known = Set(sections.map(\.0))
        let requested = Set(CommandLine.arguments.filter { known.contains($0) })
        for (name, section) in sections where requested.isEmpty || requested.contains(name) {
            section()
        }

        print("checks: \(checks)  failures: \(failures.count)")
        for f in failures { print("FAIL \(f)") }
        print(failures.isEmpty ? "ALL PASS" : "HAS FAILURES")
        return failures.isEmpty
    }

    static func markerHidden() -> Bool {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let sites = ComposerMarkdownStyler.unorderedListBulletSites(in: ns, caret: sel.location, selection: nil)
        let lineStart = ns.lineRange(for: NSRange(location: min(sel.location, max(0, ns.length - 1)), length: 0)).location
        guard let site = sites.first(where: { $0.line.location == lineStart }) else { return false }
        let size = (tv.textStorage!.attribute(.font, at: site.markerLocation, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
        return !site.revealed && size < 1
    }

    static func quoteMarkerHidden(_ loc: Int) -> Bool {
        let s = tv.textStorage!
        let fg = s.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
        return (fg?.alphaComponent ?? 1) < 0.05
    }

    static func quotes() {
        // Typing "> " then text.
        reset("")
        type(">")
        render("q-gt")
        type(" ")
        let emptyRow = lineUsed(0).height
        let caretX0 = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil).minX
        let caretH0 = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil).height
        render("q-empty")
        type("hello")
        expect("q: typed", "> hello")
        expectTrue("q: '>' hidden away from caret", quoteMarkerHidden(0))
        let fullRow = lineUsed(0).height
        expectTrue("q: empty quote row full height", abs(emptyRow - fullRow) < 0.75, "empty=\(emptyRow) full=\(fullRow)")
        let bodyX = glyphX(2)
        let winBodyX = tv.convert(NSPoint(x: bodyX, y: 0), to: nil).x + window.frame.minX
        expectTrue("q: caret after '> ' sits where body starts", abs(caretX0 - winBodyX) < 1.5,
                   "caret=\(caretX0) body=\(winBodyX)")
        expectTrue("q: caret full height on empty quote", caretH0 >= 14, "h=\(caretH0)")
        let bars1 = tv.quoteBarRects()
        expectTrue("q: one bar", bars1.count == 1, "n=\(bars1.count)")
        if let b = bars1.first {
            expectTrue("q: bar left of body", b.maxX < bodyX - 2, "bar=\(b) bodyX=\(bodyX)")
        }

        // ⇧↩ continues; bar spans both lines without a gap.
        shiftReturn()
        expect("q: ⇧↩ continues", "> hello\n> ")
        type("world")
        let bars2 = tv.quoteBarRects()
        expectTrue("q: contiguous lines share one bar", bars2.count == 1, "bars=\(bars2)")
        if let b = bars2.first {
            let l2 = lineUsed(idx("world"))
            expectTrue("q: bar reaches 2nd line", b.maxY >= l2.maxY - 2, "bar=\(b) line2=\(l2)")
        }
        render("q-two")

        // Backspace at body start unquotes the line in one press.
        let worldStart = idx("world")
        tv.setSelectedRange(NSRange(location: worldStart, length: 0))
        pump()
        backspace()
        expect("q: Backspace at body start unquotes the line", "> hello\nworld")
        expectTrue("q: caret stays at line start after unquote", tv.selectedRange().location == idx("world"),
                   "caret=\(tv.selectedRange().location)")

        // Backspace on an empty quote line removes the marker.
        reset("> a\n> ")
        backspace()
        expect("q: Backspace on empty quote line unquotes", "> a\n")

        // ⇧↩ twice exits.
        reset("> a")
        shiftReturn()
        shiftReturn()
        expect("q: ⇧↩ on empty quote exits", "> a\n")
        type("b")
        expectTrue("q: text after exit is not quoted", tv.quoteBarRects().count == 1
                   && !quoteMarkerHidden(idx("b")), "bars=\(tv.quoteBarRects().count)")

        // Long wrapped line: bar covers all fragments.
        reset("> " + String(repeating: "wrap me please ", count: 8), caret: 0)
        pump(0.1)
        let lm = tv.layoutManager!
        let lastGlyph = lm.glyphIndexForCharacter(at: (tv.string as NSString).length - 1)
        let lastFrag = lm.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        if let b = tv.quoteBarRects().first {
            expectTrue("q: bar spans wrapped fragments", b.maxY >= lastFrag.maxY + tv.textContainerOrigin.y - 2,
                       "bar=\(b) last=\(lastFrag)")
        } else { expectTrue("q: wrapped bar exists", false) }
        let wrapStartX = glyphX(2)
        let wrapNextX: CGFloat = {
            var fr = NSRange()
            _ = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 2), effectiveRange: &fr)
            return glyphX(lm.characterIndexForGlyph(at: NSMaxRange(fr)))
        }()
        expectTrue("q: wrapped line aligns with first body line", abs(wrapStartX - wrapNextX) < 1.5,
                   "first=\(wrapStartX) next=\(wrapNextX)")
        render("q-wrap")

        // Caret between '>' and space reveals '>'; typing inside never breaks source.
        reset("> x", caret: 1)
        expectTrue("q: caret inside prefix reveals '>'", !quoteMarkerHidden(0))

        // A '>' in the middle of a line is not a quote.
        reset("a > b", caret: 5)
        expectTrue("q: mid-line '>' isn't a quote", tv.quoteBarRects().isEmpty)

        // Quote then Enter submits, text untouched.
        reset("> hi")
        enter()
        expect("q: Enter submits", "> hi")
    }

    static func lists() {
        reset("")
        type("- ")
        expectTrue("ul: bullet paints right after '- ' (no raw dash state)", markerHidden())
        render("ul-just-typed")
        let emptyRow = lineUsed(0).height
        let emptyCaret = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil).height
        type("d")
        expectTrue("ul: still a bullet after first body char", markerHidden())
        let fullRow = lineUsed(0).height
        let fullCaret = tv.firstRect(forCharacterRange: NSRange(location: 3, length: 0), actualRange: nil).height
        expectTrue("ul: empty item row is full height", abs(emptyRow - fullRow) < 0.75,
                   "empty=\(emptyRow) full=\(fullRow)")
        expectTrue("ul: caret is full height on an empty item", emptyCaret >= fullCaret - 1,
                   "empty=\(emptyCaret) full=\(fullCaret)")
        shiftReturn()
        expectTrue("ul: continued item shows a bullet immediately", markerHidden(), "src=\(esc(source))")
        backspace()
        expect("ul: Backspace on empty bullet unlists", "- d\n")
        reset("- ab", caret: 1)
        let ns = tv.string as NSString
        let revealed = ComposerMarkdownStyler.unorderedListBulletSites(in: ns, caret: 1, selection: nil).first?.revealed
        expectTrue("ul: caret between '-' and space still reveals the raw marker", revealed == true)
        reset("")
        type("- one")
        shiftReturn()
        expect("ul: ⇧↩ continues", "- one\n- ")
        type("two")
        tab()
        expect("ul: Tab nests 2nd item", "- one\n    - two")
        let step1 = glyphX(idx("two")) - glyphX(idx("one"))
        expectTrue("ul: level-1 body is visibly indented", abs(step1 - ComposerMarkdownStyler.listLevelIndent) < 1.5,
                   "dx=\(step1)")
        tab()
        expect("ul: Tab caps at parent+1", "- one\n    - two")
        shiftReturn()
        expect("ul: ⇧↩ keeps nest level", "- one\n    - two\n    - ")
        type("three")
        tab()
        expect("ul: Tab to level 2", "- one\n    - two\n        - three")
        let step2 = glyphX(idx("three")) - glyphX(idx("one"))
        expectTrue("ul: level-2 body indented 2 steps", abs(step2 - 2 * ComposerMarkdownStyler.listLevelIndent) < 1.5,
                   "dx=\(step2)")
        render("ul-nested")
        shiftTab()
        expect("ul: ⇧Tab outdents", "- one\n    - two\n    - three")
        shiftTab()
        expect("ul: ⇧Tab to root", "- one\n    - two\n- three")
        shiftTab()
        expect("ul: ⇧Tab at root unlists", "- one\n    - two\nthree")

        // Tab with the caret mid-body (not just at line start).
        reset("- a\n- bcd", caret: 8)
        tab()
        expect("ul: Tab mid-body indents", "- a\n    - bcd")
        expectTrue("ul: caret stays in body after Tab", tv.selectedRange().location == 12,
                   "caret=\(tv.selectedRange().location)")

        // Bullet dot sits left of its body at each level.
        reset("- a\n    - b\n        - c", caret: 0)
        let sites = ComposerMarkdownStyler.unorderedListBulletSites(in: tv.string as NSString)
        expectTrue("ul: 3 bullet sites", sites.count == 3, "n=\(sites.count)")
        expectTrue("ul: levels 0/1/2", sites.map(\.level) == [0, 1, 2], "\(sites.map(\.level))")

        // Empty item ⇧↩ exits; Backspace on empty nested item.
        reset("- a\n    - ", caret: nil)
        shiftReturn()
        expectTrue("ul: ⇧↩ on empty nested item exits list or outdents",
                   source == "- a\n- " || source == "- a\n", "got=\(esc(source))")

        // Multi-line selection Tab.
        reset("- a\n- b\n- c")
        tv.setSelectedRange(NSRange(location: 4, length: 7))
        pump()
        tab()
        expect("ul: Tab with multi-item selection nests all", "- a\n    - b\n    - c")
    }

    static func ordered() {
        reset("")
        type("1. one")
        shiftReturn()
        expect("ol: ⇧↩ increments", "1. one\n2. ")
        type("two")
        tab()
        expect("ol: Tab nests and restarts at 1", "1. one\n    1. two")
        let dx = glyphX(idx("two")) - glyphX(idx("one"))
        expectTrue("ol: nested body is visibly indented", abs(dx - ComposerMarkdownStyler.listLevelIndent) < 1.5,
                   "dx=\(dx)")
        shiftReturn()
        expect("ol: ⇧↩ continues nested numbering", "1. one\n    1. two\n    2. ")
        type("three")
        shiftTab()
        expect("ol: ⇧Tab outdents and renumbers", "1. one\n    1. two\n2. three")
        render("ol-nested")
        shiftReturn()
        shiftReturn()
        expect("ol: ⇧↩ on empty item exits", "1. one\n    1. two\n2. three\n")
    }

    static func fences() {
        reset("before")
        shiftReturn()
        type("```")
        pump(0.3)
        expect("fence: ``` scaffolds", "before\n```\n\n```")
        type("let x = 1")
        shiftReturn()
        type("print(x)")
        expect("fence: body lines", "before\n```\nlet x = 1\nprint(x)\n```")
        tab()
        expectTrue("fence: Tab indents 4 spaces, no \\t",
                   source.contains("\n    print(x)") && !source.contains("\t"), "got=\(esc(source))")
        shiftTab()
        expect("fence: ⇧Tab outdents", "before\n```\nlet x = 1\nprint(x)\n```")
        down()
        type("after")
        expectTrue("fence: ↓ exits to a prose line after the block",
                   source.hasSuffix("```\nafter"), "got=\(esc(source))")

        // Geometry: chip keeps a gap to the prose above and below.
        tv.setSelectedRange(NSRange(location: idx("after") + 2, length: 0))
        pump(0.1)
        let chips = tv.codeBlockChipRects()
        expectTrue("fence: one chip", chips.count == 1, "n=\(chips.count)")
        if let chip = chips.first {
            let above = lineUsed(idx("before"))
            let below = lineUsed(idx("after"))
            let first = lineUsed(idx("let x"))
            let last = lineUsed(idx("print"))
            let gapAbove = chip.minY - above.maxY
            let gapBelow = below.minY - chip.maxY
            print("  chip=\(chip) above=\(above.maxY) first=\(first) last=\(last) below=\(below.minY)")
            expectTrue("fence: gap above chip ≥ 4", gapAbove >= 4, "gap=\(gapAbove)")
            expectTrue("fence: gap below chip ≥ 4", gapBelow >= 4, "gap=\(gapBelow)")
            expectTrue("fence: inner pad top ≥ 6", first.minY - chip.minY >= 6, "pad=\(first.minY - chip.minY)")
            expectTrue("fence: inner pad bottom ≥ 6", chip.maxY - last.maxY >= 6, "pad=\(chip.maxY - last.maxY)")
        }
        render("fence")

        // Caret on the opener: ticks visible, aligned with the body, inside the chip.
        tv.setSelectedRange(NSRange(location: idx("```") + 3, length: 0))
        pump(0.1)
        let openerX = glyphX(idx("```"))
        let bodyX = glyphX(idx("let x"))
        expectTrue("fence: revealed opener aligns with code body", abs(openerX - bodyX) < 1.5,
                   "opener=\(openerX) body=\(bodyX)")
        if let chip = tv.codeBlockChipRects().first {
            let opener = lineUsed(idx("```"))
            expectTrue("fence: revealed opener sits inside the chip",
                       opener.minY >= chip.minY && opener.maxY <= chip.maxY,
                       "opener=\(opener) chip=\(chip)")
            let gapAbove = chip.minY - lineUsed(idx("before")).maxY
            expectTrue("fence: gap above chip ≥ 4 with opener revealed", gapAbove >= 4, "gap=\(gapAbove)")
        }
        render("fence-opener")

        // Backspace on closer tears down the block.
        let closer = (source as NSString).range(of: "```", options: .backwards).location
        tv.setSelectedRange(NSRange(location: closer + 3, length: 0))
        pump()
        backspace()
        expectTrue("fence: Backspace on closer removes the block", !source.contains("```"),
                   "got=\(esc(source))")

        // ↓ out of a block that ends the prompt: closer stays hidden, line is prose.
        reset("")
        type("```")
        pump(0.3)
        type("a")
        shiftReturn()
        type("b")
        down()
        pump(0.1)
        let ns2 = tv.string as NSString
        let closeLoc = ns2.range(of: "```", options: .backwards).location
        let caretLoc = tv.selectedRange().location
        print("  ↓ at end: src=\(esc(source)) caret=\(caretLoc)")
        expectTrue("fence: ↓ leaves the block", caretLoc > closeLoc + 3, "caret=\(caretLoc) close=\(closeLoc)")
        let tickSize = (tv.textStorage!.attribute(.font, at: closeLoc, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
        expectTrue("fence: closer ticks hidden after ↓ out", tickSize < 1, "size=\(tickSize)")
        let closerRow = lineUsed(closeLoc).height
        expectTrue("fence: closer row collapsed after ↓ out", closerRow < 2, "h=\(closerRow)")
        expectTrue("fence: caret line after block is not code", !ComposerMarkdownStyler.caretIsInFence(in: tv))
        let before = source
        tab()
        expect("fence: Tab on the prose line after a block inserts nothing", before)
        type("x")
        expectTrue("fence: typing after block lands as prose", source.hasSuffix("```\nx"), "got=\(esc(source))")
        let xFont = tv.textStorage!.attribute(.font, at: (tv.string as NSString).length - 1, effectiveRange: nil) as? NSFont
        expectTrue("fence: prose after block is not mono", !(xFont?.isFixedPitch ?? true))
        render("fence-down-at-end")

        // Caret at the start of the prose line right after a closer isn't "in the fence".
        reset("```\na\n```\nafter", caret: 10)
        expectTrue("fence: line-start after closer is prose", !ComposerMarkdownStyler.caretIsInFence(in: tv))
        let closer2 = (tv.textStorage!.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
        expectTrue("fence: closer hidden when caret starts the next line", closer2 < 1, "size=\(closer2)")

        // Language tag.
        reset("")
        type("```swift")
        pump(0.3)
        expectTrue("fence: lang tag kept on opener", source.hasPrefix("```swift\n"), "got=\(esc(source))")

        reset("hi")
        enter()
        expect("fence: Enter submits, text untouched", "hi")
        expectTrue("fence: Enter fired submit", model.submits > 0)
    }

    static func inline() {
        reset("")
        type("run `npm i` now")
        expect("inline: typed", "run `npm i` now")
        let s = tv.textStorage!
        let bg = s.attribute(.backgroundColor, at: 5, effectiveRange: nil) as? NSColor
        expectTrue("inline: chip bg on span", (bg?.alphaComponent ?? 0) > 0.03)
        let mono = (s.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? false
        expectTrue("inline: mono", mono)
        let tick = (s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        expectTrue("inline: tick hidden away from caret", tick < 1, "size=\(tick)")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        pump()
        let tick2 = (s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        // Caret inside the body (not touching a tick) keeps ticks hidden.
        expectTrue("inline: tick hidden when caret is mid-span", tick2 < 1, "size=\(tick2)")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        pump()
        let tick3 = (s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        expectTrue("inline: tick revealed when caret touches it", tick3 > 9, "size=\(tick3)")
        render("inline")
    }

    static func height() {
        reset("")
        type("- a")
        for i in 0..<7 { shiftReturn(); type("item\(i)") }
        pump(0.2)
        let sv = tv.enclosingScrollView!
        expectTrue("height: 8 list lines grow the composer without a scroller",
                   !(sv.verticalScroller?.isHidden == false && sv.documentView!.frame.height > sv.contentSize.height + 1),
                   "doc=\(sv.documentView!.frame.height) clip=\(sv.contentSize.height)")
        expectTrue("height: model height grew", model.height > 100, "h=\(model.height)")
        render("height")
    }
}
#endif
