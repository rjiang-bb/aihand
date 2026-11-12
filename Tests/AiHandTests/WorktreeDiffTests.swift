import XCTest
@testable import AiHand

/// Fixture repo shared by the git + web tests.
enum WorktreeDiffFixture {
    @discardableResult
    static func git(_ args: [String], in dir: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@example.com",
                       "-c", "commit.gpgsign=false"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Two commits, then: a.txt unstaged edit, b.txt staged edit, c.txt untracked.
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihand-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: dir)
        write("one\ntwo\n", "a.txt", in: dir)
        write("b1\n", "b.txt", in: dir)
        git(["add", "."], in: dir)
        git(["commit", "-q", "-m", "first"], in: dir)
        write("d\n", "d.txt", in: dir)
        git(["add", "."], in: dir)
        git(["commit", "-q", "-m", "second"], in: dir)
        write("one\nTWO\n", "a.txt", in: dir)
        write("b1\nb2\n", "b.txt", in: dir)
        git(["add", "b.txt"], in: dir)
        write("c\n", "c.txt", in: dir)
        return dir
    }
}

final class WorktreeDiffTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = try WorktreeDiffFixture.make()
    }

    override func tearDown() {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    private func names(_ files: [WorktreeChangedFile]) -> [String] { files.map(\.path) }

    func testUncommittedListsStagedUnstagedAndUntracked() {
        let files = WorktreeDiff.files(filter: .uncommitted, in: repo.path)
        XCTAssertEqual(names(files), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(files[0].status, "M")
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[1].added, 1)
        XCTAssertEqual(files[2].status, "U")
        XCTAssertEqual(files[2].added, 1)
    }

    func testStagedOnlyShowsIndexChanges() {
        XCTAssertEqual(names(WorktreeDiff.files(filter: .staged, in: repo.path)), ["b.txt"])
    }

    func testUnstagedShowsWorkingEditsAndUntracked() {
        XCTAssertEqual(names(WorktreeDiff.files(filter: .unstaged, in: repo.path)), ["a.txt", "c.txt"])
    }

    func testCommitFilterShowsThatCommitsFiles() {
        let commits = WorktreeDiff.commits(in: repo.path)
        XCTAssertEqual(commits.map(\.subject), ["second", "first"])
        let second = WorktreeDiff.files(filter: .commit(commits[0].sha), in: repo.path)
        XCTAssertEqual(names(second), ["d.txt"])
        XCTAssertEqual(second[0].status, "A")
        // Root commit diffs against the empty tree.
        let first = WorktreeDiff.files(filter: .commit(commits[1].sha), in: repo.path)
        XCTAssertEqual(names(first), ["a.txt", "b.txt"])
    }

    func testCommitsPaging() {
        XCTAssertEqual(WorktreeDiff.commits(in: repo.path, skip: 1, limit: 1).map(\.subject), ["first"])
        XCTAssertTrue(WorktreeDiff.commits(in: repo.path, skip: 5, limit: 10).isEmpty)
    }

    func testCountsForTheThreeWorkingFilters() {
        let counts = WorktreeDiff.counts(in: repo.path)
        XCTAssertEqual(counts["uncommitted"]?.insertions, 3)
        XCTAssertEqual(counts["uncommitted"]?.deletions, 1)
        XCTAssertEqual(counts["staged"]?.insertions, 1)
        XCTAssertEqual(counts["unstaged"]?.insertions, 2)
    }

    func testContentBeforeAndAfterPerFilter() throws {
        let uncommitted = WorktreeDiff.files(filter: .uncommitted, in: repo.path)
        let a = WorktreeDiff.content(filter: .uncommitted, file: uncommitted[0], in: repo.path)
        XCTAssertEqual(a.original, "one\ntwo\n")
        XCTAssertEqual(a.modified, "one\nTWO\n")

        let staged = WorktreeDiff.files(filter: .staged, in: repo.path)
        let b = WorktreeDiff.content(filter: .staged, file: staged[0], in: repo.path)
        XCTAssertEqual(b.original, "b1\n")
        XCTAssertEqual(b.modified, "b1\nb2\n")

        let unstaged = WorktreeDiff.files(filter: .unstaged, in: repo.path)
        let c = WorktreeDiff.content(filter: .unstaged, file: unstaged[1], in: repo.path)
        XCTAssertEqual(c.original, "")
        XCTAssertEqual(c.modified, "c\n")

        let sha = WorktreeDiff.commits(in: repo.path)[0].sha
        let d = WorktreeDiff.content(filter: .commit(sha), file: WorktreeDiff.files(filter: .commit(sha), in: repo.path)[0], in: repo.path)
        XCTAssertEqual(d.original, "")
        XCTAssertEqual(d.modified, "d\n")
    }

    func testDeletedFileHasEmptyModified() {
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("d.txt"))
        let files = WorktreeDiff.files(filter: .uncommitted, in: repo.path)
        let d = files.first { $0.path == "d.txt" }
        XCTAssertEqual(d?.status, "D")
        let content = WorktreeDiff.content(filter: .uncommitted, file: d!, in: repo.path)
        XCTAssertEqual(content.original, "d\n")
        XCTAssertEqual(content.modified, "")
    }

    func testBinaryAndTooLargeAreFlagged() throws {
        try Data([0x00, 0x01, 0x02]).write(to: repo.appendingPathComponent("blob.bin"))
        let blob = WorktreeChangedFile(path: "blob.bin", oldPath: nil, status: "U", added: 0, removed: 0, binary: true)
        XCTAssertTrue(WorktreeDiff.content(filter: .unstaged, file: blob, in: repo.path).binary)

        let big = String(repeating: "x", count: WorktreeDiff.maxBytes + 1)
        WorktreeDiffFixture.write(big, "big.txt", in: repo)
        let file = WorktreeChangedFile(path: "big.txt", oldPath: nil, status: "U", added: 1, removed: 0, binary: false)
        XCTAssertTrue(WorktreeDiff.content(filter: .unstaged, file: file, in: repo.path).tooLarge)
    }

    func testRenameIsReportedWithOldPath() {
        WorktreeDiffFixture.git(["mv", "d.txt", "e.txt"], in: repo)
        let files = WorktreeDiff.files(filter: .staged, in: repo.path)
        let renamed = files.first { $0.path == "e.txt" }
        XCTAssertEqual(renamed?.status, "R")
        XCTAssertEqual(renamed?.oldPath, "d.txt")
        let content = WorktreeDiff.content(filter: .staged, file: renamed!, in: repo.path)
        XCTAssertEqual(content.original, "d\n")
        XCTAssertEqual(content.modified, "d\n")
    }

    func testParseFilesHandlesRenameAndBinary() {
        let numstat = "3\t1\tsrc/a.swift\0-\t-\timg.png\00\t0\t\0old.txt\0new.txt\0"
        let status = "M\0src/a.swift\0A\0img.png\0R100\0old.txt\0new.txt\0"
        let files = WorktreeDiff.parseFiles(numstat: numstat, nameStatus: status)
        XCTAssertEqual(files.map(\.path), ["src/a.swift", "img.png", "new.txt"])
        XCTAssertEqual(files[0].added, 3)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertTrue(files[1].binary)
        XCTAssertEqual(files[2].status, "R")
        XCTAssertEqual(files[2].oldPath, "old.txt")
    }

    func testParseCommits() {
        let raw = "abc123\u{1f}abc\u{1f}Fix thing\u{1f}2 hours ago\u{1e}\ndef456\u{1f}def\u{1f}Other\u{1f}3 days ago\u{1e}"
        let commits = WorktreeDiff.parseCommits(raw)
        XCTAssertEqual(commits.map(\.short), ["abc", "def"])
        XCTAssertEqual(commits[0].subject, "Fix thing")
    }

    func testFilterJSONRejectsUnsafeShas() {
        XCTAssertEqual(WorktreeDiffFilter(json: ["kind": "staged"]), .staged)
        XCTAssertEqual(WorktreeDiffFilter(json: ["kind": "commit", "sha": "abc123"]), .commit("abc123"))
        XCTAssertNil(WorktreeDiffFilter(json: ["kind": "commit", "sha": "HEAD; rm -rf"]))
        XCTAssertNil(WorktreeDiffFilter(json: ["kind": "nope"]))
    }

    func testChangesRowAddsToPickerMetrics() {
        let closed = SessionsListMetrics.gitPickerHeight(worktreeCount: 1, expanded: false)
        XCTAssertEqual(closed, SessionsListMetrics.gitPicker + 1 + SessionsListMetrics.gitChangesRowHeight)
        XCTAssertGreaterThan(SessionsListMetrics.gitPickerHeight(worktreeCount: 1, expanded: true), closed)
    }

    func testSidebarWidthPersists() {
        let saved = WorktreeChangesWindow.sidebarWidth
        defer { WorktreeChangesWindow.sidebarWidth = saved }
        WorktreeChangesWindow.sidebarWidth = 333
        XCTAssertEqual(WorktreeChangesWindow.sidebarWidth, 333)
        WorktreeChangesWindow.sidebarWidth = nil
        XCTAssertNil(WorktreeChangesWindow.sidebarWidth)
    }
}
