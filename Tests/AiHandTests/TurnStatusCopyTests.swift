import XCTest
@testable import AiHand

final class TurnStatusCopyTests: XCTestCase {
    func testWorkedAndThoughtFormatting() {
        XCTAssertEqual(TurnStatusCopy.worked(seconds: 0), "Worked for 0s")
        XCTAssertEqual(TurnStatusCopy.worked(seconds: 23.4), "Worked for 23s")
        XCTAssertEqual(TurnStatusCopy.worked(seconds: 60), "Worked for 1m")
        XCTAssertEqual(TurnStatusCopy.worked(seconds: 75), "Worked for 1m 15s")
        XCTAssertEqual(TurnStatusCopy.thought(seconds: 2), "Thought 2s")
        XCTAssertTrue(TurnStatusCopy.isWorkedChip("Worked for 10s"))
        XCTAssertFalse(TurnStatusCopy.isWorkedChip("Thought 2s"))
        XCTAssertTrue(TurnStatusCopy.isThoughtChip("Thought 2s"))
        XCTAssertFalse(TurnStatusCopy.isThoughtChip("Worked for 10s"))
        XCTAssertEqual(TurnStatusCopy.planning, "Planning next moves")
    }

    func testExploringAggregatesFilesSearchesAndCommands() {
        let texts = [
            "Reading a.swift",
            "Editing b.swift",
            "Searched TODO",
            "Glob **/*.swift",
            "Ran swift build",
        ]
        XCTAssertEqual(
            TurnStatusCopy.exploring(toolTexts: texts),
            "Exploring 2 files, 2 searches, 1 command"
        )
    }

    func testExploringNilWhenEmptyOrUncategorized() {
        XCTAssertNil(TurnStatusCopy.exploring(toolTexts: []))
        XCTAssertNil(TurnStatusCopy.exploring(toolTexts: ["MCP lookup"]))
    }

    func testToolCategories() {
        XCTAssertEqual(TurnStatusCopy.category(for: "Reading x"), .file)
        XCTAssertEqual(TurnStatusCopy.category(for: "Searched foo"), .search)
        XCTAssertEqual(TurnStatusCopy.category(for: "Ran ls"), .command)
        XCTAssertEqual(TurnStatusCopy.category(for: "MCP tool"), .other)
    }
}
