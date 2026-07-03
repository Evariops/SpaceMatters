import Testing
import Foundation
@testable import MacDirStats

@Suite struct ParsingTests {

    // A12: Kubernetes resource quantities.
    @Test func parseQuantityUnits() {
        #expect(K8sQueries.parseQuantity("8Gi") == 8 * 1_073_741_824)
        #expect(K8sQueries.parseQuantity("100Mi") == 100 * 1_048_576)
        #expect(K8sQueries.parseQuantity("1Ti") == 1_099_511_627_776)
        #expect(K8sQueries.parseQuantity("500M") == 500_000_000)
        #expect(K8sQueries.parseQuantity("8Ki") == 8_192)   // "Ki" must win over "K"
        #expect(K8sQueries.parseQuantity("1000") == 1_000)
        #expect(K8sQueries.parseQuantity("") == 0)
        #expect(K8sQueries.parseQuantity(nil) == 0)
        #expect(K8sQueries.parseQuantity("garbage") == 0)
    }

    // A10: human-readable byte formatting — base 1024 with honest IEC labels.
    @Test func formatBytes() {
        let sep = Locale.current.decimalSeparator ?? "."
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(1_023) == "1023 B")
        #expect(Format.bytes(1_024) == "1\(sep)00 KiB")
        #expect(Format.bytes(1_048_576) == "1\(sep)00 MiB")
        #expect(Format.bytes(1_073_741_824) == "1\(sep)00 GiB")
        // 1000-based values are *not* relabelled as KB (that was the A10 bug).
        #expect(Format.bytes(1_000).hasSuffix(" B"))
    }

    // J9: reconciliation arithmetic (the derived breakdown fields).
    @Test func reconciliationArithmetic() {
        // Scan explains part of "used"; the rest splits into trash/purgeable/unaccounted.
        let r = Reconciliation(volumeUsed: 1000, scanned: 600, trash: 100,
                               purgeable: 150, snapshotCount: 2, skippedPaths: 3)
        #expect(r.accountedFor == 850)          // 600 + 100 + 150
        #expect(r.unaccounted == 150)           // 1000 − 850
        #expect(!r.scanExceedsUsed)

        // Attribution over hardlinks/clones can push the scan above "used".
        let over = Reconciliation(volumeUsed: 500, scanned: 900, trash: 0,
                                  purgeable: 0, snapshotCount: 0, skippedPaths: 0)
        #expect(over.scanExceedsUsed)
        #expect(over.unaccounted == 0)          // clamped, never negative
    }

    // ExtKey: never crashes on hostile input, folds ASCII case.
    @Test func extKeyRobustAndCaseFolded() {
        #expect(ExtKey(fileName: "photo.PNG") == ExtKey(fileName: "photo.png"))
        #expect(ExtKey(fileName: "noext") == ExtKey(fileName: "other"))   // both → .none
        #expect(ExtKey(fileName: "").displayName == ExtKey.none.displayName)
        // Long / weird extensions must not trap.
        _ = ExtKey(fileName: "x." + String(repeating: "z", count: 500))
        _ = ExtKey(fileName: ".hidden")
        _ = ExtKey(fileName: "a.tar.GZ")
    }
}
