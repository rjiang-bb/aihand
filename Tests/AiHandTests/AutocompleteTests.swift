import XCTest
@testable import AiHand

final class FileCatalogTests: SandboxedTestCase {
    func testAtQueryParsing() {
        func q(_ s: String) -> String? { WorkspaceFileCatalog.atQuery(in: s)?.query }
        XCTAssertEqual(q("@"), "")
        XCTAssertEqual(q("look at @Src/Fo"), "Src/Fo")
        XCTAssertEqual(q("a\n@x.swift"), "x.swift")
        XCTAssertNil(q("mail me@x.com"), "@ glued to a word is not a mention")
        XCTAssertNil(q("@done "), "space ends the token")
        XCTAssertNil(q("@bad!char"))
        XCTAssertNil(q("no mention"))
        XCTAssertNil(q("⟦file:@x⟧"), "@ inside a chip token is ignored")
        XCTAssertEqual(q("⟦file:a⟧@b"), "b", "@ right after a chip is allowed")
    }

    func testAtQueryRangeCoversTokenToEnd() throws {
        let text = "see @Pre"
        let r = try XCTUnwrap(WorkspaceFileCatalog.atQuery(in: text)).range
        XCTAssertEqual(String(text[r]), "@Pre")
    }

    private func entries(_ paths: [String]) -> [WorkspaceFileEntry] {
        paths.map { WorkspaceFileEntry(path: $0, isDirectory: false) }
    }

    func testMatchRankingExactThenPrefixThenContains() {
        let e = entries(["a/main.swift", "main", "z/domain.swift", "main.swift", "src/mainloop.c"])
        let out = WorkspaceFileCatalog.matches(query: "main", in: e).map(\.path)
        XCTAssertEqual(out.first, "main", "exact name first")
        XCTAssertLessThan(out.firstIndex(of: "main.swift")!, out.firstIndex(of: "z/domain.swift")!, "prefix before contains")
    }

    func testEmptyQueryPrefersShallowPaths() {
        let e = entries(["a/b/c/deep.txt", "top.txt", "a/mid.txt"])
        XCTAssertEqual(WorkspaceFileCatalog.matches(query: "", in: e).map(\.path), ["top.txt", "a/mid.txt", "a/b/c/deep.txt"])
    }

    func testMatchLimit() {
        let e = entries((0..<50).map { "f\($0).txt" })
        XCTAssertEqual(WorkspaceFileCatalog.matches(query: "f", in: e).count, 8)
        XCTAssertEqual(WorkspaceFileCatalog.matches(query: "f", in: e, limit: 3).count, 3)
    }

    func testEntryNameAndParent() {
        let e = WorkspaceFileEntry(path: "a/b/c.txt", isDirectory: false)
        XCTAssertEqual(e.name, "c.txt")
        XCTAssertEqual(e.parentPath, "a/b")
        XCTAssertEqual(WorkspaceFileEntry(path: "top.txt", isDirectory: false).parentPath, "")
    }

    func testLocalScanFindsFilesAndSkipsHeavyDirs() throws {
        let ws = tempDir.appendingPathComponent("proj", isDirectory: true)
        try write("Sources/App/main.swift", under: ws)
        try write("README.md", under: ws)
        try write("node_modules/pkg/index.js", under: ws)
        try write(".build/debug/x", under: ws)
        let list = WorkspaceFileCatalog.entries(workspace: ws.path, connectionID: nil, forceRefresh: true)
        let paths = Set(list.map(\.path))
        XCTAssertTrue(paths.contains("Sources/App/main.swift"), "\(paths)")
        XCTAssertTrue(paths.contains("README.md"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".build") }, "\(paths)")
    }

    func testEmptyWorkspaceYieldsNothing() {
        XCTAssertTrue(WorkspaceFileCatalog.entries(workspace: "  ", connectionID: nil).isEmpty)
        XCTAssertTrue(WorkspaceFileCatalog.entries(workspace: nil, connectionID: nil).isEmpty)
    }

    func testResultsAreCachedUntilInvalidated() throws {
        let ws = tempDir.appendingPathComponent("cache", isDirectory: true)
        try write("a.txt", under: ws)
        XCTAssertEqual(WorkspaceFileCatalog.entries(workspace: ws.path, connectionID: nil).count, 1)
        try write("b.txt", under: ws)
        XCTAssertEqual(WorkspaceFileCatalog.entries(workspace: ws.path, connectionID: nil).count, 1, "served from cache")
        WorkspaceFileCatalog.invalidate()
        XCTAssertEqual(WorkspaceFileCatalog.entries(workspace: ws.path, connectionID: nil).count, 2)
    }
}

final class SkillCatalogTests: SandboxedTestCase {
    func testSlashQueryParsing() {
        func q(_ s: String) -> String? { SkillCatalog.slashQuery(in: s)?.query }
        XCTAssertEqual(q("/"), "")
        XCTAssertEqual(q("/com"), "com")
        XCTAssertEqual(q("hello /com"), "com")
        XCTAssertNil(q("a/b"), "mid-word slash is a path, not a skill")
        XCTAssertNil(q("/done "))
        XCTAssertNil(q("⟦skill:/x⟧"))
    }

    private func skills(_ names: [(String, String)]) -> [AgentSkill] {
        names.map { AgentSkill(name: $0.0, description: $0.1, directoryName: $0.0) }
    }

    func testMatchRanking() {
        let s = skills([("review-pr", "x"), ("pr", "y"), ("deploy", "open a pr"), ("spr", "z")])
        let out = SkillCatalog.matches(query: "pr", in: s).map(\.name)
        XCTAssertEqual(out.first, "pr", "exact first")
        XCTAssertEqual(out.last, "deploy", "description match last")
        XCTAssertEqual(Set(out), ["pr", "review-pr", "spr", "deploy"])
    }

    func testEmptyQueryReturnsFirstEight() {
        let s = skills((0..<20).map { ("s\($0)", "") })
        XCTAssertEqual(SkillCatalog.matches(query: "", in: s).count, 8)
    }

    func testBuiltInPlanIsMergedAndListedForEveryCLI() {
        for cli in AgentCLIKind.allCases {
            let found = SkillCatalog.skills(connectionID: nil, cli: cli, forceRefresh: true)
            let plan = found.first { $0.name == "plan" }
            XCTAssertNotNil(plan, "missing built-in plan for \(cli)")
            XCTAssertEqual(plan?.isBuiltIn, true)
            XCTAssertEqual(plan?.description, BuiltInSkills.plan.description)
            XCTAssertEqual(found.first?.name, "plan", "built-ins lead the catalog for \(cli)")
        }
    }

    func testBuiltInPlanWinsOverDiskSkill() throws {
        let home = try XCTUnwrap(SkillCatalog.homeDirectoryOverride)
        try write(".cursor/skills/plan/SKILL.md", """
        ---
        name: plan
        description: disk plan skill that must lose
        ---
        """, under: home)
        let found = SkillCatalog.skills(connectionID: nil, cli: .cursor, forceRefresh: true)
        let plans = found.filter { $0.name.lowercased() == "plan" }
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].isBuiltIn)
        XCTAssertEqual(plans[0].description, BuiltInSkills.plan.description)
        XCTAssertFalse(plans[0].description.contains("disk plan"))
    }

    func testMergeBuiltInsDropsCollidingScannedNames() {
        let scanned = [
            AgentSkill(name: "plan", description: "from disk", directoryName: "plan"),
            AgentSkill(name: "Plan", description: "cased disk", directoryName: "Plan"),
            AgentSkill(name: "other", description: "keep", directoryName: "other"),
        ]
        let merged = SkillCatalog.mergeBuiltIns(over: scanned)
        XCTAssertEqual(merged.filter { $0.name.lowercased() == "plan" }.count, 1)
        XCTAssertTrue(merged[0].isBuiltIn)
        XCTAssertNotNil(merged.first { $0.name == "other" })
    }

    @MainActor
    func testApplyBuiltInInsertsSkillChip() {
        var text = "/pl"
        let ac = SkillAutocompleteController()
        ac.apply(BuiltInSkills.plan, to: &text)
        XCTAssertEqual(text, "⟦skill:plan⟧ ")
    }

    func testBuiltInPlanChipUsesClipboardSymbol() {
        XCTAssertEqual(BuiltInSkills.symbolName(forSkillNamed: "plan"), "list.bullet.clipboard")
        let chip = ComposerSkillChipAttachment(name: "plan", darkChrome: true)
        XCTAssertEqual(chip.symbolName, "list.bullet.clipboard")
        let folder = ComposerSkillChipAttachment(name: "other", darkChrome: true)
        XCTAssertEqual(folder.symbolName, "sparkles")
    }

    @MainActor
    func testApplyFolderSkillStillInsertsChip() {
        var text = "/demo"
        let ac = SkillAutocompleteController()
        ac.apply(
            AgentSkill(name: "demo", description: "x", directoryName: "demo"),
            to: &text
        )
        XCTAssertTrue(text.contains("⟦skill:demo⟧"), text)
    }

    func testWorkspaceSkillsAreDiscoveredFromFrontmatter() throws {
        let ws = tempDir.appendingPathComponent("proj", isDirectory: true)
        try write(".cursor/skills/zz-demo-skill/SKILL.md", """
        ---
        name: zz-demo-skill
        description: Does a demo thing
          across lines
        ---
        # body
        """, under: ws)
        try write(".agents/skills/zz-noname/SKILL.md", "---\ndescription: fallback to dir name\n---\n", under: ws)
        try write(".cursor/skills/zz-broken/SKILL.md", "no frontmatter at all", under: ws)
        let found = SkillCatalog.skills(
            workspace: ws.path, connectionID: nil, cli: .cursor, forceRefresh: true
        )
        let demo = try XCTUnwrap(found.first { $0.name == "zz-demo-skill" })
        XCTAssertTrue(demo.description.contains("Does a demo thing"))
        XCTAssertNotNil(found.first { $0.name == "zz-noname" }, "falls back to directory name")
        XCTAssertNil(found.first { $0.name == "zz-broken" })
    }

    func testCLISpecificRootsAreGatedBySelectedCLI() throws {
        let home = try XCTUnwrap(SkillCatalog.homeDirectoryOverride)
        try write(".codex/skills/zz-codex-user/SKILL.md", """
        ---
        name: zz-codex-user
        description: from ~/.codex/skills
        ---
        """, under: home)
        try write(".codex/skills/.system/zz-codex-system/SKILL.md", """
        ---
        name: zz-codex-system
        description: bundled system skill
        ---
        """, under: home)
        try write(".claude/skills/zz-claude-user/SKILL.md", """
        ---
        name: zz-claude-user
        description: from ~/.claude/skills
        ---
        """, under: home)
        try write(".cursor/skills/zz-cursor-user/SKILL.md", """
        ---
        name: zz-cursor-user
        description: from ~/.cursor/skills
        ---
        """, under: home)
        try write(".agents/skills/zz-shared/SKILL.md", """
        ---
        name: zz-shared
        description: shared agents skill
        ---
        """, under: home)

        let codex = SkillCatalog.skills(connectionID: nil, cli: .codex, forceRefresh: true)
        XCTAssertNotNil(codex.first { $0.name == "zz-codex-user" })
        XCTAssertNotNil(codex.first { $0.name == "zz-codex-system" },
                        "~/.codex/skills/.system is a hidden folder — must still be scanned")
        XCTAssertNotNil(codex.first { $0.name == "zz-shared" }, "shared .agents/skills for every CLI")
        XCTAssertNil(codex.first { $0.name == "zz-claude-user" })
        XCTAssertNil(codex.first { $0.name == "zz-cursor-user" })

        let claude = SkillCatalog.skills(connectionID: nil, cli: .claude, forceRefresh: true)
        XCTAssertNotNil(claude.first { $0.name == "zz-claude-user" })
        XCTAssertNotNil(claude.first { $0.name == "zz-shared" })
        XCTAssertNil(claude.first { $0.name == "zz-codex-user" })
        XCTAssertNil(claude.first { $0.name == "zz-cursor-user" })

        let cursor = SkillCatalog.skills(connectionID: nil, cli: .cursor, forceRefresh: true)
        XCTAssertNotNil(cursor.first { $0.name == "zz-cursor-user" })
        XCTAssertNotNil(cursor.first { $0.name == "zz-shared" })
        XCTAssertNil(cursor.first { $0.name == "zz-codex-user" })
        XCTAssertNil(cursor.first { $0.name == "zz-claude-user" })
    }

    func testPluginSkillContainersAreGatedByCLI() throws {
        let home = try XCTUnwrap(SkillCatalog.homeDirectoryOverride)
        try write(
            ".codex/plugins/cache/mkt/demo/1.0.0/skills/zz-codex-plugin/SKILL.md",
            "---\nname: zz-codex-plugin\ndescription: codex plugin skill\n---\n",
            under: home
        )
        try write(
            ".claude/plugins/marketplaces/official/plugins/demo/skills/zz-claude-plugin/SKILL.md",
            "---\nname: zz-claude-plugin\ndescription: claude plugin skill\n---\n",
            under: home
        )
        try write(
            ".cursor/plugins/cache/pub/hash/skills-figquery/zz-cursor-plugin/SKILL.md",
            "---\nname: zz-cursor-plugin\ndescription: cursor plugin skill\n---\n",
            under: home
        )

        XCTAssertTrue(
            SkillCatalog.discoverPluginSkillContainers(
                under: home.appendingPathComponent(".codex/plugins")
            ).contains { $0.path.hasSuffix("/skills") }
        )

        let codex = SkillCatalog.skills(connectionID: nil, cli: .codex, forceRefresh: true)
        XCTAssertNotNil(codex.first { $0.name == "zz-codex-plugin" })
        XCTAssertNil(codex.first { $0.name == "zz-claude-plugin" })
        XCTAssertNil(codex.first { $0.name == "zz-cursor-plugin" })

        let claude = SkillCatalog.skills(connectionID: nil, cli: .claude, forceRefresh: true)
        XCTAssertNotNil(claude.first { $0.name == "zz-claude-plugin" })
        XCTAssertNil(claude.first { $0.name == "zz-codex-plugin" })

        let cursor = SkillCatalog.skills(connectionID: nil, cli: .cursor, forceRefresh: true)
        XCTAssertNotNil(cursor.first { $0.name == "zz-cursor-plugin" })
        XCTAssertNil(cursor.first { $0.name == "zz-codex-plugin" })
    }

    func testCursorPersonalSkillBeatsPluginWithSameName() throws {
        let home = try XCTUnwrap(SkillCatalog.homeDirectoryOverride)
        try write(".cursor/skills/zz-dup/SKILL.md", """
        ---
        name: zz-dup
        description: from cursor personal
        ---
        """, under: home)
        try write(
            ".cursor/plugins/cache/m/p/1/skills/zz-dup/SKILL.md",
            "---\nname: zz-dup\ndescription: from plugin\n---\n",
            under: home
        )
        let found = SkillCatalog.skills(connectionID: nil, cli: .cursor, forceRefresh: true)
        let skill = try XCTUnwrap(found.first { $0.name == "zz-dup" })
        XCTAssertEqual(skill.description, "from cursor personal",
                       "earlier roots win; plugins must not override personal Cursor skills")
    }
}

@MainActor
final class AutocompleteControllerTests: SandboxedTestCase {
    func testFileControllerActivatesFiltersAndStripsQueryOnApply() throws {
        let ws = tempDir.appendingPathComponent("proj", isDirectory: true)
        try write("alpha.swift", under: ws)
        try write("beta.swift", under: ws)

        let c = FileAutocompleteController()
        var draft = ""
        c.readText = { draft }
        c.configure(workspace: ws.path, connectionID: nil)

        let loaded = expectation(description: "index loaded")
        Task { @MainActor in
            for _ in 0..<200 {
                draft = "open @alp"
                c.update(text: draft)
                if c.matches.map(\.path) == ["alpha.swift"] { loaded.fulfill(); return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        wait(for: [loaded], timeout: 8)
        XCTAssertTrue(c.isActive)

        let picked = c.applySelected(to: &draft)
        XCTAssertEqual(picked?.path, "alpha.swift")
        XCTAssertEqual(draft, "open ", "@query removed — chip carries the reference")
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(c.matches.isEmpty)
    }

    func testFileControllerDeactivatesWhenAtIsGone() {
        let c = FileAutocompleteController()
        c.update(text: "@x")
        XCTAssertTrue(c.isActive)
        c.update(text: "plain text")
        XCTAssertFalse(c.isActive)
    }

    func testSelectionClampsToMatches() throws {
        let c = FileAutocompleteController()
        c.update(text: "@")
        c.moveSelection(delta: 5)
        XCTAssertGreaterThanOrEqual(c.selectedIndex, 0)
        c.clear()
        XCTAssertEqual(c.selectedIndex, 0)
    }

    func testSkillControllerLifecycle() throws {
        // Home is sandboxed, so seed a skill for "/re" to match.
        let home = try XCTUnwrap(SkillCatalog.homeDirectoryOverride)
        try write(".cursor/skills/zz-review/SKILL.md", "---\nname: zz-review\ndescription: d\n---\n", under: home)
        SkillCatalog.invalidate()
        let c = SkillAutocompleteController()
        c.update(text: "hi /zz-re")
        XCTAssertTrue(c.isActive)
        c.update(text: "hi there")
        XCTAssertFalse(c.isActive)
        c.clear()
    }
}
