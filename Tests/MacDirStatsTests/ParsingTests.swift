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

    // A10: human-readable byte formatting (base 1024).
    @Test func formatBytes() {
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(1_023) == "1023 B")
        #expect(Format.bytes(1_024) == "1.00 KB")
        #expect(Format.bytes(1_048_576) == "1.00 MB")
        #expect(Format.bytes(1_073_741_824) == "1.00 GB")
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
