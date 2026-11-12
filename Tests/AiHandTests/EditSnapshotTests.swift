import XCTest
@testable import AiHand

final class EditSnapshotTests: SandboxedTestCase {
    private let after = "line1\nline2 NEW\nline3\nline4\n"

    private func payload(args: [String: Any], success: [String: Any]) -> [String: Any] {
        ["args": args, "result": ["success": success]]
    }

    func testStrReplaceReversesToFullFile() throws {
        let p = payload(
            args: ["path": "/w/a.swift", "strReplace": ["oldText": "line2", "newText": "line2 NEW"]],
            success: ["path": "/w/a.swift", "afterFullFileContent": after]
        )
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: false, preWriteContents: nil))
        XCTAssertEqual(s.path, "/w/a.swift")
        XCTAssertEqual(s.original, "line1\nline2\nline3\nline4\n")
        XCTAssertEqual(s.modified, after)
        XCTAssertEqual(s.lineOffset, 0)
    }

    func testMultiStrReplaceUndoesEveryEdit() {
        let reps = [
            EditSnapshotBuilder.Replacement(oldText: "a", newText: "A1"),
            EditSnapshotBuilder.Replacement(oldText: "c", newText: "C1"),
        ]
        XCTAssertEqual(EditSnapshotBuilder.reverseReplace(modified: "A1\nb\nC1", replacements: reps), "a\nb\nc")
        XCTAssertEqual(
            EditSnapshotBuilder.reverseReplace(
                modified: "x X x",
                replacements: [.init(oldText: "y", newText: "x", replaceAll: true)]
            ),
            "y X y"
        )
        XCTAssertNil(EditSnapshotBuilder.reverseReplace(modified: "zzz", replacements: reps))
    }

    func testCursorStyleDiffStringReversal() throws {
        // Cursor pads the sign: "- " / "+ ".
        let p = payload(
            args: ["path": "/w/out.txt"],
            success: ["path": "/w/out.txt", "diffString": "- \n+ Hello World", "afterFullFileContent": "Hello World"]
        )
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: false, preWriteContents: nil))
        XCTAssertEqual(s.original, "")
        XCTAssertEqual(s.modified, "Hello World")
    }

    func testUnifiedDiffReversalWithContext() {
        let diff = """
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2 NEW
         line3
        """
        XCTAssertEqual(
            EditSnapshotBuilder.reverseApply(diffString: diff, to: after),
            "line1\nline2\nline3\nline4\n"
        )
    }

    func testHunkFallbackKeepsRealLineNumbers() throws {
        // Second replacement can't be located (file changed since) → full reversal fails →
        // show the first hunk, numbered from where it sits in the file.
        let p = payload(
            args: ["path": "/w/a.swift", "multiStrReplace": ["edits": [
                ["oldText": "old3", "newText": "line3"],
                ["oldText": "x", "newText": "missing"],
            ]]],
            success: ["path": "/w/a.swift", "afterFullFileContent": "line1\nline2\nline3\nline4\n"]
        )
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: false, preWriteContents: nil))
        XCTAssertEqual(s.original, "old3")
        XCTAssertEqual(s.modified, "line3")
        XCTAssertEqual(s.lineOffset, 2)
    }

    func testReplacementWithoutAfterContentIsHunkOnly() throws {
        let p = payload(
            args: ["path": "/w/a.swift", "strReplace": ["oldText": "x", "newText": "y"]],
            success: ["path": "/w/a.swift"]
        )
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: false, preWriteContents: nil))
        XCTAssertEqual(s.original, "x")
        XCTAssertEqual(s.modified, "y")
        XCTAssertEqual(s.lineOffset, 0)
    }

    func testDiffOnlyPayloadUsesHunkSidesWithOffset() throws {
        let p = payload(
            args: ["path": "/w/a.swift"],
            success: ["path": "/w/a.swift", "diffString": "@@ -3 +3 @@\n-old3\n+new3"]
        )
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: false, preWriteContents: nil))
        XCTAssertEqual(s.original, "old3")
        XCTAssertEqual(s.modified, "new3")
        XCTAssertEqual(s.lineOffset, 0)
    }

    func testWriteUsesPreWriteContents() throws {
        let p = payload(args: ["path": "/w/n.md", "contents": "# New\n"], success: ["path": "/w/n.md"])
        let s = try XCTUnwrap(EditSnapshotBuilder.fromCursor(payload: p, isWrite: true, preWriteContents: "# Old\n"))
        XCTAssertEqual(s.original, "# Old\n")
        XCTAssertEqual(s.modified, "# New\n")
    }

    func testOversizeSidesAreDropped() {
        let big = String(repeating: "x", count: EditSnapshotBuilder.maxBytes + 1)
        let s = EditSnapshotBuilder.capped(EditSnapshot(path: "/w/big", original: "", modified: big))
        XCTAssertTrue(s.tooLarge)
        XCTAssertEqual(s.modified, "")
    }

    func testSidecarWriteReadDelete() throws {
        let sid = UUID(), mid = UUID()
        let snap = EditSnapshot(path: "/w/a", original: "a", modified: "b", lineOffset: 4)
        try EditSnapshotStore.write(snap, sessionID: sid, messageID: mid)
        XCTAssertEqual(EditSnapshotStore.read(sessionID: sid, messageID: mid), snap)
        EditSnapshotStore.removeAll(sessionID: sid)
        XCTAssertNil(EditSnapshotStore.read(sessionID: sid, messageID: mid))
    }

    func testMessageFlagRoundTripsAndIsOmittedWhenFalse() throws {
        var m = AgentMessage(kind: .tool, text: "Edited a.swift +1")
        let plain = String(data: try JSONEncoder().encode(m), encoding: .utf8) ?? ""
        XCTAssertFalse(plain.contains("editSnapshot"))
        m.editSnapshot = true
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(m))
        XCTAssertTrue(decoded.editSnapshot)
    }
}

final class AssetSchemeHandlerTests: XCTestCase {
    private let handler = AssetSchemeHandler()

    func testServesMonacoLoaderAndCodeView() throws {
        let loader = try XCTUnwrap(handler.fileURL(for: URL(string: "aihand-asset://app/monaco/vs/loader.js")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.path))
        XCTAssertEqual(AssetSchemeHandler.mimeType(for: loader), "text/javascript")
        XCTAssertNotNil(handler.fileURL(for: URL(string: "aihand-asset://app/codeview/codeview.js")!))
        XCTAssertNotNil(handler.fileURL(for: URL(string: "aihand-asset://app/monaco/vs/editor/editor.main.css")!))
    }

    func testRejectsTraversalUnknownRootsAndDirectories() {
        XCTAssertNil(handler.fileURL(for: URL(string: "aihand-asset://app/monaco/../../Package.swift")!))
        XCTAssertNil(handler.fileURL(for: URL(string: "aihand-asset://app/monaco/vs/%2E%2E/%2E%2E/LICENSE")!))
        XCTAssertNil(handler.fileURL(for: URL(string: "aihand-asset://app/secrets/x.js")!))
        XCTAssertNil(handler.fileURL(for: URL(string: "aihand-asset://app/monaco/vs")!))
        XCTAssertNil(handler.fileURL(for: URL(string: "https://app/monaco/vs/loader.js")!))
    }
}
