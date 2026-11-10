import AppKit
import SwiftUI
import XCTest
@testable import AiHand

final class ChipTokenTests: XCTestCase {
    func testFileAndDirTokensRoundTrip() {
        let f = ComposerFileChipToken.serialize(path: "src/a.swift", isDirectory: false)
        XCTAssertEqual(f, "⟦file:src/a.swift⟧")
        XCTAssertEqual(ComposerFileChipToken.parse(f)?.path, "src/a.swift")
        XCTAssertEqual(ComposerFileChipToken.parse(f)?.isDirectory, false)
        let d = ComposerFileChipToken.serialize(path: "src", isDirectory: true)
        XCTAssertEqual(ComposerFileChipToken.parse(d)?.isDirectory, true)
    }

    func testClosingBracketInPathIsStripped() {
        let t = ComposerFileChipToken.serialize(path: "a⟧b", isDirectory: false)
        XCTAssertEqual(t, "⟦file:ab⟧", "a stray ⟧ would end the token early")
    }

    func testParseRejectsMalformedTokens() {
        for bad in ["", "⟦⟧", "⟦x⟧", "file:a", "⟦file:a", "a⟧", "⟦other:a⟧"] {
            XCTAssertNil(ComposerFileChipToken.parse(bad), bad)
        }
    }

    func testSkillTokens() {
        let t = ComposerFileChipToken.serializeSkill("commit")
        XCTAssertEqual(t, "⟦skill:commit⟧")
        XCTAssertEqual(ComposerFileChipToken.parseSkill(t), "commit")
        XCTAssertNil(ComposerFileChipToken.parseSkill("⟦file:x⟧"))
        XCTAssertNil(ComposerFileChipToken.parse(t), "skill token isn't a file token")
    }

    func testExpandForSendInlinesNamesAndCollectsPaths() {
        let draft = "fix ⟦file:/w/src/a.swift⟧ and ⟦dir:/w/lib⟧ then ⟦skill:commit⟧ and ⟦file:/w/src/a.swift⟧"
        let out = ComposerFileChipToken.expandForSend(draft, workspace: "/w")
        XCTAssertEqual(out.prompt, "fix a.swift and lib/ then /commit and a.swift")
        XCTAssertEqual(out.filePaths, ["/w/src/a.swift", "/w/lib"], "deduped, in order")
    }

    func testExpandLeavesPlainTextAndUnknownBracketsAlone() {
        let out = ComposerFileChipToken.expandForSend("plain ⟦weird⟧ text", workspace: "/w")
        XCTAssertEqual(out.prompt, "plain ⟦weird⟧ text")
        XCTAssertTrue(out.filePaths.isEmpty)
    }

    func testDisplayAndRelativePaths() {
        XCTAssertEqual(ComposerFileChipToken.displayName(for: "/a/b/c.txt", isDirectory: false), "c.txt")
        XCTAssertEqual(ComposerFileChipToken.displayName(for: "/a/b", isDirectory: true), "b/")
        XCTAssertEqual(ComposerFileChipToken.relativePath("/w/src/a.swift", workspace: "/w"), "src/a.swift")
        XCTAssertEqual(ComposerFileChipToken.relativePath("/other/a", workspace: "/w"), "/other/a")
        XCTAssertEqual(ComposerFileChipToken.relativePath("/wx/a", workspace: "/w"), "/wx/a", "prefix must be a path boundary")
    }
}

final class ChipCodecTests: XCTestCase {
    private let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]

    func testSerializedDraftRoundTripsThroughAttachments() {
        let draft = "look at ⟦file:/w/a.swift⟧ with ⟦skill:review⟧ please"
        let attr = ComposerFileChipCodec.attributedString(from: draft, darkChrome: true, base: base)
        XCTAssertFalse(attr.string.contains("⟦"), "tokens became chips")
        XCTAssertEqual(attr.string.filter { $0 == "\u{FFFC}" }.count, 2)
        XCTAssertEqual(ComposerFileChipCodec.serialize(attr), draft)
    }

    func testPlainTextIsUntouched() {
        let attr = ComposerFileChipCodec.attributedString(from: "no chips here", darkChrome: false, base: base)
        XCTAssertEqual(attr.string, "no chips here")
        XCTAssertEqual(ComposerFileChipCodec.serialize(attr), "no chips here")
    }

    func testOrphanReplacementCharsAreSanitized() {
        let s = NSTextStorage(string: "a\u{FFFC}b")
        XCTAssertTrue(ComposerFileChipCodec.sanitizeOrphans(in: s))
        XCTAssertEqual(s.string, "ab")
        XCTAssertFalse(ComposerFileChipCodec.sanitizeOrphans(in: s))
    }

    func testRealChipsSurviveSanitize() {
        let attr = ComposerFileChipCodec.attributedString(from: "x ⟦file:/w/a⟧ y", darkChrome: true, base: base)
        let s = NSTextStorage(attributedString: attr)
        XCTAssertFalse(ComposerFileChipCodec.sanitizeOrphans(in: s))
        XCTAssertEqual(s.string.filter { $0 == "\u{FFFC}" }.count, 1)
    }

    func testDeletingPartOfAChipExpandsToTheWholeChip() {
        let attr = ComposerFileChipCodec.attributedString(from: "ab⟦file:/w/a⟧cd", darkChrome: true, base: base)
        let s = NSTextStorage(attributedString: attr)
        let chipLoc = (s.string as NSString).range(of: "\u{FFFC}").location
        let expanded = ComposerFileChipCodec.expansionForChipMutation(in: s, range: NSRange(location: chipLoc - 1, length: 2))
        XCTAssertEqual(expanded.location, chipLoc - 1)
        XCTAssertGreaterThanOrEqual(NSMaxRange(expanded), chipLoc + 1)
        let plain = ComposerFileChipCodec.expansionForChipMutation(in: s, range: NSRange(location: 0, length: 1))
        XCTAssertEqual(plain, NSRange(location: 0, length: 1), "ranges not touching a chip are unchanged")
    }

    @MainActor
    func testInsertChipAddsChipAndTrailingSpace() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        tv.isEditable = true
        tv.string = "see "
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        ComposerFileChipCodec.insertChip(path: "/w/a.swift", isDirectory: false, darkChrome: true, into: tv)
        XCTAssertEqual(ComposerFileChipCodec.serialize(tv.attributedString()), "see ⟦file:/w/a.swift⟧ ")
        XCTAssertEqual(tv.selectedRange().location, (tv.string as NSString).length, "caret lands after the chip + space")
    }
}

final class MediaImportTests: SandboxedTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("aihand.tests.\(UUID().uuidString)"))
    }

    func testAttachmentClassification() {
        XCTAssertTrue(ComposerAttachment(path: "/a/b.PNG", ownsFile: false).isImage)
        XCTAssertTrue(ComposerAttachment(path: "/a/b.mov", ownsFile: false).isVideo)
        XCTAssertTrue(ComposerAttachment(path: "/a/b.heic", ownsFile: false).isMedia)
        XCTAssertFalse(ComposerAttachment(path: "/a/b.swift", ownsFile: false).isMedia)
        XCTAssertEqual(ComposerAttachment(path: "/a/b/c.txt", ownsFile: false).fileName, "c.txt")
    }

    func testSupportedMediaExtensions() {
        for ext in ["png", "JPG", "jpeg", "gif", "webp", "tiff", "heic", "mov", "mp4", "m4v", "webm"] {
            XCTAssertTrue(ComposerMediaImport.isSupportedMedia(path: "/x/y.\(ext)"), ext)
        }
        for ext in ["swift", "pdf", "txt", ""] {
            XCTAssertFalse(ComposerMediaImport.isSupportedMedia(path: "/x/y.\(ext)"), ext)
        }
    }

    func testNonMediaFileKeepsItsOriginalPath() throws {
        let f = try write("notes.txt")
        let out = ComposerMediaImport.attachments(fromFileURLs: [f])
        XCTAssertEqual(out.map(\.path), [f.path])
        XCTAssertEqual(out.first?.ownsFile, false, "never delete the user's own file")
    }

    func testMissingFilesAndFoldersAreSkipped() throws {
        let dir = tempDir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = ComposerMediaImport.attachments(fromFileURLs: [dir, tempDir.appendingPathComponent("nope.png")])
        XCTAssertTrue(out.isEmpty)
    }

    func testPastedFileURLs() throws {
        let f = try write("a.txt")
        let pb = pasteboard()
        pb.clearContents()
        pb.writeObjects([f as NSURL])
        XCTAssertEqual(ComposerMediaImport.attachmentsFromPasteboard(pb)?.map(\.path), [f.path])
    }

    func testPastedImageIsWrittenToDiskAndOwned() throws {
        Preferences.screenshotsFolder = tempDir.appendingPathComponent("shots").path
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let pb = pasteboard()
        pb.clearContents()
        pb.writeObjects([img])
        let out = try XCTUnwrap(ComposerMediaImport.attachmentsFromPasteboard(pb))
        let item = try XCTUnwrap(out.first)
        XCTAssertTrue(item.ownsFile)
        XCTAssertTrue(item.isImage)
        XCTAssertTrue(item.path.hasPrefix(tempDir.path), "written inside the configured screenshots folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        ComposerMediaImport.discard(out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), "discard deletes owned temps")
    }

    func testPlainTextPasteFallsThrough() {
        let pb = pasteboard()
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertNil(ComposerMediaImport.attachmentsFromPasteboard(pb), "nil → caller does a normal text paste")
    }

    func testStaleFileURLFallsThroughToBitmap() throws {
        Preferences.screenshotsFolder = tempDir.appendingPathComponent("shots").path
        let img = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { r in
            NSColor.blue.setFill(); r.fill(); return true
        }
        let pb = pasteboard()
        pb.clearContents()
        // Dead file URL first (screenshots / “Copy Image” often advertise both).
        pb.writeObjects([tempDir.appendingPathComponent("missing-shot.png") as NSURL])
        pb.writeObjects([img])
        let out = try XCTUnwrap(ComposerMediaImport.attachmentsFromPasteboard(pb))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].ownsFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out[0].path))
        ComposerMediaImport.discard(out)
    }

    func testRawPNGBytesAreWrittenWithoutReencode() throws {
        Preferences.screenshotsFolder = tempDir.appendingPathComponent("shots").path
        let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in
            NSColor.green.setFill(); r.fill(); return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let pb = pasteboard()
        pb.clearContents()
        pb.setData(png, forType: .png)
        // Also litter a string flavor — media must still win for the composer.
        pb.setString("ignored alt text", forType: .string)
        let out = try XCTUnwrap(ComposerMediaImport.attachmentsFromPasteboard(pb))
        XCTAssertEqual((out[0].path as NSString).pathExtension.lowercased(), "png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out[0].path)), png)
        ComposerMediaImport.discard(out)
    }

    func testRawJPEGBytesAreWritten() throws {
        Preferences.screenshotsFolder = tempDir.appendingPathComponent("shots").path
        let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in
            NSColor.orange.setFill(); r.fill(); return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let pb = pasteboard()
        pb.clearContents()
        pb.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        let out = try XCTUnwrap(ComposerMediaImport.attachmentsFromPasteboard(pb))
        XCTAssertEqual((out[0].path as NSString).pathExtension.lowercased(), "jpg")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out[0].path)), jpeg)
        ComposerMediaImport.discard(out)
    }

    func testLiveImageFileURLWinsOverBitmap() throws {
        Preferences.screenshotsFolder = tempDir.appendingPathComponent("shots").path
        let file = try write("shot.png", "png-bytes")
        let img = NSImage(size: NSSize(width: 3, height: 3), flipped: false) { r in
            NSColor.purple.setFill(); r.fill(); return true
        }
        let pb = pasteboard()
        pb.clearContents()
        pb.writeObjects([file as NSURL, img])
        let out = try XCTUnwrap(ComposerMediaImport.attachmentsFromPasteboard(pb))
        let item = try XCTUnwrap(out.first)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(item.ownsFile, "media file URLs are copied into the screenshots folder")
        XCTAssertNotEqual(item.path, file.path)
        XCTAssertEqual(try String(contentsOfFile: item.path, encoding: .utf8), "png-bytes",
                       "copied the file URL bytes — did not fall through to the NSImage")
        ComposerMediaImport.discard(out)
    }

    func testDiscardLeavesUnownedFilesAlone() throws {
        let f = try write("keep.txt")
        ComposerMediaImport.discard([ComposerAttachment(path: f.path, ownsFile: false)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
}

/// `ComposerPromptTextView.paste` must prefer `onPasteMedia` over inserting string
/// flavors — ⌘V arrives here via the Edit menu, not only the FocusState key monitor.
final class ComposerPasteRoutingTests: XCTestCase {
    private final class Box {
        var text = ""
        var focused = true
        var height: CGFloat = 22
    }

    /// Keep the coordinator alive — `ComposerPromptTextView.parent` is weak.
    private final class Harness {
        let box: Box
        let coordinator: ComposerPromptEditor.Coordinator
        let textView: ComposerPromptTextView

        init(onPasteMedia: (() -> Bool)?) {
            let box = Box()
            self.box = box
            let editor = ComposerPromptEditor(
                text: Binding(get: { box.text }, set: { box.text = $0 }),
                focused: Binding(get: { box.focused }, set: { box.focused = $0 }),
                height: Binding(get: { box.height }, set: { box.height = $0 }),
                placeholder: "Follow up…",
                onSubmit: {},
                onPasteMedia: onPasteMedia
            )
            let coordinator = ComposerPromptEditor.Coordinator(editor)
            let tv = ComposerPromptTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
            tv.isEditable = true
            tv.isRichText = false
            tv.string = ""
            tv.parent = coordinator
            coordinator.textView = tv
            self.coordinator = coordinator
            self.textView = tv
        }
    }

    @MainActor
    func testPasteMediaCallbackSwallowsStringFlavor() {
        let general = NSPasteboard.general
        general.clearContents()
        general.setString("should not appear", forType: .string)
        defer { general.clearContents() }

        var mediaCalls = 0
        let harness = Harness {
            mediaCalls += 1
            return true
        }
        harness.textView.paste(nil)
        XCTAssertEqual(mediaCalls, 1)
        XCTAssertEqual(harness.textView.string, "", "media paste must not also insert the string flavor")
    }

    @MainActor
    func testPasteFallsThroughToNormalizedTextWhenMediaDeclines() {
        let general = NSPasteboard.general
        general.clearContents()
        general.setString("• item", forType: .string)
        defer { general.clearContents() }

        var mediaCalls = 0
        let harness = Harness {
            mediaCalls += 1
            return false
        }
        harness.textView.paste(nil)
        XCTAssertEqual(mediaCalls, 1)
        XCTAssertEqual(harness.textView.string, "- item", "declined media → markdown list normalize still runs")
    }

    @MainActor
    func testPasteWithoutMediaCallbackStillInsertsText() {
        let general = NSPasteboard.general
        general.clearContents()
        general.setString("hello", forType: .string)
        defer { general.clearContents() }

        let harness = Harness(onPasteMedia: nil)
        harness.textView.paste(nil)
        XCTAssertEqual(harness.textView.string, "hello")
    }
}

final class AnnotatePromptModelTests: SandboxedTestCase {
    func testSubmitRules() {
        let m = AnnotatePromptModel()
        XCTAssertTrue(m.canSubmit, "empty prompt is fine for screenshot sends")
        m.requirePrompt = true
        XCTAssertFalse(m.canSubmit)
        m.text = "  \n "
        XCTAssertFalse(m.canSubmit, "whitespace doesn't count")
        m.text = "fix it"
        XCTAssertTrue(m.canSubmit)
        m.workspaceMissing = true
        XCTAssertFalse(m.canSubmit, "no working folder blocks sending")
    }

    func testFavoritesLoadAndCycleWraps() {
        let kind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
        Preferences.addAgentFavorite(AgentFavorite(title: "Fast", cliKind: kind, modelId: "m1", modelTitle: "m1", effort: nil, isBuiltIn: false))
        Preferences.addAgentFavorite(AgentFavorite(title: "Deep", cliKind: kind, modelId: "m2", modelTitle: "m2", effort: nil, isBuiltIn: false))
        let m = AnnotatePromptModel()
        m.reloadFavorites()
        XCTAssertGreaterThanOrEqual(m.favorites.count, 3)
        XCTAssertEqual(m.cliTitle, kind.title)
        XCTAssertNotNil(m.selectedFavoriteID)

        var seen: [UUID] = []
        for _ in 0..<m.favorites.count {
            m.cycleFavorite()
            seen.append(m.selectedFavoriteID!)
        }
        XCTAssertEqual(Set(seen), Set(m.favorites.map(\.id)))
        m.cycleFavorite()
        XCTAssertEqual(m.selectedFavoriteID, seen[0], "wraps")
        XCTAssertEqual(Preferences.currentAgentFavoriteID(for: kind, target: Preferences.runtimeAgentTarget), seen[0],
                       "cycling also makes it the Current favorite")
    }

    func testMenuTitleCombinesCLIAndFavorite() {
        let m = AnnotatePromptModel()
        m.reloadFavorites()
        XCTAssertTrue(m.favoriteMenuTitle.hasPrefix(m.cliTitle))
        XCTAssertTrue(m.favoriteMenuTitle.contains("·"))
    }

    func testCycleWithNoFavoritesIsANoOp() {
        let m = AnnotatePromptModel()
        m.favorites = []
        m.cycleFavorite()
        XCTAssertNil(m.selectedFavoriteID)
    }
}
