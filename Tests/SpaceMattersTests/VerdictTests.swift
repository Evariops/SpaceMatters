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
}
