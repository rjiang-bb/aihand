import XCTest
@testable import AiHand

final class TurnEditCopyTests: XCTestCase {
    func testLineAndHeaderFormatting() {
        XCTAssertEqual(TurnEditCopy.line(path: "a.swift", added: 85, removed: 22), "Edited a.swift +85 -22")
        XCTAssertEqual(TurnEditCopy.line(path: "a.swift", added: 5, removed: 0), "Edited a.swift +5")
        XCTAssertEqual(TurnEditCopy.line(path: "a.swift", added: 0, removed: 2), "Edited a.swift -2")
        XCTAssertEqual(TurnEditCopy.header(fileCount: 1, added: 5, removed: 0), "Edited 1 file +5")
        XCTAssertEqual(TurnEditCopy.header(fileCount: 2, added: 99, removed: 22), "Edited 2 files +99 -22")
        XCTAssertEqual(
            TurnEditCopy.header(fileCount: 2, added: 79, removed: 0, inProgress: true),
            "Editing 2 files +79"
        )
    }

    func testActivityHeaderUsesEditingWhileInProgress() {
        XCTAssertEqual(
            TurnEditCopy.activityHeader(toolTexts: [
                "Edited a.swift +79",
                "Editing b.swift",
            ]),
            "Editing 2 files +79"
        )
        XCTAssertEqual(
            TurnEditCopy.activityHeader(toolTexts: [
                "Edited a.swift +79",
                "Edited b.swift +1",
            ]),
            "Edited 2 files +80"
        )
        XCTAssertTrue(TurnEditCopy.isInProgressEdit("Editing x.swift"))
        XCTAssertFalse(TurnEditCopy.isInProgressEdit("Edited x.swift +1"))
    }

    func testParseRoundTrip() {
        let stat = TurnEditCopy.parse("Edited VideoDestinationPicker.swift +85 -22")
        XCTAssertEqual(stat?.path, "VideoDestinationPicker.swift")
        XCTAssertEqual(stat?.added, 85)
        XCTAssertEqual(stat?.removed, 22)
        XCTAssertEqual(TurnEditCopy.parse("Editing SoftChrome.swift")?.path, "SoftChrome.swift")
        XCTAssertNil(TurnEditCopy.parse("Reading a.swift"))
    }

    func testSummarizeUniqueFilesAndSums() {
        let sum = TurnEditCopy.summarize(toolTexts: [
            "Edited VideoDestinationPicker.swift +85 -22",
            "Thought 10s",
            "Edited SoftChrome.swift +5",
            "Edited VideoDestinationPicker.swift +1 -2",
            "Edited VideoDestinationPicker.swift +10",
        ])
        XCTAssertEqual(sum?.fileCount, 2)
        XCTAssertEqual(sum?.added, 101)
        XCTAssertEqual(sum?.removed, 24)
        XCTAssertTrue(TurnEditCopy.isFileEditTool("Editing x.swift"))
        XCTAssertFalse(TurnEditCopy.isFileEditTool("Reading x.swift"))
    }
}
