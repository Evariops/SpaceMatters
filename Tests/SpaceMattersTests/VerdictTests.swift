import Testing
import Foundation
import simd
@testable import SpaceMatters

/// SPEC-14 §3.5 — verdicts painted onto the map by an assistant. Driven through a
/// real `ScanController` over a real scan, because the two properties that matter
/// are both about the tree: a verdict covers a *region*, and it must survive the
/// tree being rebuilt under it.
@MainActor
@Suite struct VerdictTests {

    private func fixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-verdict-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("caches/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keepme"), withIntermediateDirectories: true)
        try Data(count: 8192).write(to: root.appendingPathComponent("caches/deep/c.bin"))
        try Data(count: 4096).write(to: root.appendingPathComponent("keepme/k.bin"))
        return root
    }

    private func scanned(_ url: URL) async -> ScanController {
        let controller = ScanController()
        controller.scan(url: url)
        let deadline = Date().addingTimeInterval(5)
        while controller.phase == .scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        return controller
    }

    @Test func aVerdictCoversTheWholeRegionBeneathIt() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)

        let path = root.appendingPathComponent("caches").path
        #expect(c.annotate(path: path, verdict: .safe, reason: "regenerable build caches") != nil)

        let caches = try #require(c.root?.children.first { $0.name == "caches" })
        let deep = try #require(caches.children.first { $0.name == "deep" })
        // Marking a folder has to paint its region, not one tile inside it.
        #expect(c.verdict(for: caches)?.verdict == .safe)
        #expect(c.verdict(for: deep)?.verdict == .safe)
        #expect(c.verdict(for: deep)?.reason == "regenerable build caches")

        let keepme = try #require(c.root?.children.first { $0.name == "keepme" })
        #expect(c.verdict(for: keepme) == nil)
    }

    @Test func theNearestAncestorWins() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)

        #expect(c.annotate(path: root.path, verdict: .review, reason: "whole tree") != nil)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "caches") != nil)
        let caches = try #require(c.root?.children.first { $0.name == "caches" })
        let keepme = try #require(c.root?.children.first { $0.name == "keepme" })
        #expect(c.verdict(for: caches)?.verdict == .safe)   // the specific mark
        #expect(c.verdict(for: keepme)?.verdict == .review) // inherited from the root
    }

    @Test func verdictsSurviveTheTreeBeingRebuilt() async throws {
        // SPEC-02 `invalidate` replaces a subtree with *fresh objects*. Keying on
        // node identity alone would silently drop the verdict — or worse, leave
        // it pointing at a node that no longer exists.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)

        let path = root.appendingPathComponent("caches").path
        #expect(c.annotate(path: path, verdict: .safe, reason: "regenerable") != nil)
        let before = try #require(c.root?.children.first { $0.name == "caches" })
        let deepBefore = try #require(before.children.first { $0.name == "deep" })

        #expect(await c.invalidate(subtree: before))

        // `caches` itself is kept; its children are the fresh objects.
        let after = try #require(c.root?.children.first { $0.name == "caches" })
        let deepAfter = try #require(after.children.first { $0.name == "deep" })
        #expect(deepAfter !== deepBefore, "the fixture did not actually rebuild the subtree")
        #expect(c.verdict(for: deepAfter)?.verdict == .safe, "the verdict did not follow the rebuild")
        #expect(c.verdict(for: after)?.verdict == .safe, "the verdict did not follow the rebuild")
        #expect(c.verdictCount == 1)
    }

    @Test func pathsOutsideTheScanAreRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        // Reported, not silently ignored: the model has to learn its path was wrong.
        #expect(c.annotate(path: "/etc", verdict: .keep, reason: "system") == nil)
        #expect(c.annotate(path: root.appendingPathComponent("nope").path,
                           verdict: .safe, reason: "x") == nil)
        #expect(c.verdictCount == 0)
    }

    @Test func clearingRemovesEveryMark() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)

        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)
        let version = c.verdictVersion
        c.clearVerdicts()
        #expect(c.verdictCount == 0)
        #expect(c.verdictVersion > version) // the map must be told to repaint
        let caches = try #require(c.root?.children.first { $0.name == "caches" })
        #expect(c.verdict(for: caches) == nil)
    }

    @Test func lookupIsFreeWhenNothingIsAnnotated() async throws {
        // Every tile of every frame asks. The empty case must not walk the
        // ancestor chain for nothing.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        let node = try #require(c.root?.children.first)
        #expect(c.verdict(for: node) == nil)
        #expect(c.verdictCount == 0)
    }

    @Test func tintsAreDistinctPerVerdict() {
        // Both renderers read these; if two collided, a verdict would be
        // unreadable on the map with no test to say so.
        let tints = Verdict.allCases.map(\.tint)
        for (i, a) in tints.enumerated() {
            for b in tints[(i + 1)...] {
                #expect(simd_distance(a, b) > 0.2)
            }
        }
    }

    @Test func theOutlineCanShowOnlyWhatWasMarked() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        let deep = root.appendingPathComponent("caches/deep").path
        #expect(c.annotate(path: deep, verdict: .safe, reason: "regenerable") != nil)

        c.showVerdictsOnly = true
        let names = c.visibleRows().compactMap { row -> String? in
            if case .directory(let n) = row.kind { return n.name }
            return nil
        }
        // The mark, plus the ancestors needed to place it — and nothing else.
        #expect(names == [root.lastPathComponent, "caches", "deep"])
        #expect(!names.contains("keepme"))
    }

    @Test func theFilterTurnsItselfOffWhenNothingIsMarked() async throws {
        // A filter that can only produce an empty list is worse than no filter.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)
        c.showVerdictsOnly = true
        c.clearVerdicts()
        #expect(c.showVerdictsOnly == false)
        #expect(c.visibleRows().count > 1)
    }

    @Test func aVerdictLooksTheSameWhateverItSitsOn() {
        // Blending toward the tint made the same verdict render a different
        // colour per file type — `review` orange over a green subtree came out
        // olive. Hue must now be the verdict's alone; only brightness varies.
        let onGreen = Verdict.review.applied(to: SIMD4<Float>(0.2, 0.7, 0.3, 1))
        let onGold  = Verdict.review.applied(to: SIMD4<Float>(0.8, 0.62, 0.25, 1))
        func hueRatio(_ c: SIMD4<Float>) -> SIMD2<Float> {
            let sum = max(0.0001, c.x + c.y + c.z)
            return SIMD2(c.x / sum, c.y / sum)
        }
        #expect(simd_distance(hueRatio(onGreen), hueRatio(onGold)) < 0.001)
        // …and it is unmistakably orange: red leads, blue trails badly.
        #expect(onGreen.x > onGreen.y && onGreen.y > onGreen.z * 2)
        // Alpha carries the dim factor in the sunburst — it must survive.
        #expect(Verdict.safe.applied(to: SIMD4<Float>(0.5, 0.5, 0.5, 0.42)).w == 0.42)
    }

    @Test func theFirstMarkSwitchesTheOutlineToIt() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        #expect(c.showVerdictsOnly == false)

        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)
        // A session marks as it goes; the outline follows without being asked.
        #expect(c.showVerdictsOnly)
    }

    @Test func turningTheFilterOffIsNotUndoneByTheNextMark() async throws {
        // The app must not argue with the user mid-analysis.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)
        c.showVerdictsOnly = false

        #expect(c.annotate(path: root.appendingPathComponent("keepme").path,
                           verdict: .review, reason: "y") != nil)
        #expect(c.showVerdictsOnly == false)
    }

    @Test func clearingRearmsTheAutoFilterForTheNextRun() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        let caches = root.appendingPathComponent("caches").path
        #expect(c.annotate(path: caches, verdict: .safe, reason: "x") != nil)
        c.clearVerdicts()
        #expect(c.showVerdictsOnly == false)

        #expect(c.annotate(path: caches, verdict: .safe, reason: "again") != nil)
        #expect(c.showVerdictsOnly)
    }

    @Test func aRescanOfTheSameRootKeepsTheMarks() async throws {
        // The marks *are* the work — refreshing what you are looking at, often
        // right after deleting something, must not throw them away.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "regenerable") != nil)

        c.rescan()
        let deadline = Date().addingTimeInterval(5)
        while c.phase == .scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        #expect(c.verdictCount == 1)
        let caches = try #require(c.root?.children.first { $0.name == "caches" })
        #expect(c.verdict(for: caches)?.verdict == .safe)
    }

    @Test func goingHomeEndsTheAnalysis() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await scanned(root)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)
        #expect(c.showVerdictsOnly)

        c.goHome()
        #expect(c.verdictCount == 0)
        #expect(c.showVerdictsOnly == false)

        // Re-picking the same disk starts clean, not a resumption.
        let c2 = await scanned(root)
        _ = c2
        c.scan(url: root)
        let deadline = Date().addingTimeInterval(5)
        while c.phase == .scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        #expect(c.verdictCount == 0)
    }

    @Test func scanningSomewhereElseDropsTheMarks() async throws {
        let root = try fixture()
        let other = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let c = await scanned(root)
        #expect(c.annotate(path: root.appendingPathComponent("caches").path,
                           verdict: .safe, reason: "x") != nil)

        // Switching folders without going Home is still a different analysis.
        c.scan(url: other)
        let deadline = Date().addingTimeInterval(5)
        while c.phase == .scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        #expect(c.verdictCount == 0)
        #expect(c.showVerdictsOnly == false)
    }

    @Test func aScanInTheTestProcessNeverClaimsTheMCPSocket() async throws {
        // `swift test` used to unlink a running app's socket and re-bind it,
        // then exit — manufacturing exactly the stale-socket failure the relay
        // has to detect, and costing the incremental-refresh tests their timing.
        // The rendezvous is machine-wide; only the GUI may claim it.
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await scanned(root)
        #expect(MCPBridge.shared.isRunning == false)
    }
}
