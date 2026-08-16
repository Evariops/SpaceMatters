import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 phase 2 — the protocol surface. stdout is the wire, so the parser has
/// to survive whatever arrives on it, and the tool schemas have to be valid JSON
/// a host can actually read.
@Suite struct MCPProtocolTests {

    // MARK: Parsing

    @Test func parsesRequestsAndNotifications() {
        let request = JSONRPC.parse(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"a":1}}"#)
        #expect(request?.method == "tools/list")
        #expect((request?.id as? NSNumber)?.intValue == 7)
        #expect(request?.isNotification == false)
        #expect(request?.params["a"] as? Int == 1)

        // No id → a notification, which must never be answered.
        let note = JSONRPC.parse(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(note?.isNotification == true)
    }

    @Test func stringIdsSurvive() {
        // The spec allows string ids; coercing them to numbers would break the
        // host's request correlation.
        let request = JSONRPC.parse(line: #"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#)
        #expect(request?.id as? String == "abc-1")
    }

    @Test(arguments: ["", "   ", "not json", "{{{", #"{"jsonrpc":"2.0","id":1}"#, "[1,2,3]"])
    func malformedLinesYieldNilNotACrash(line: String) {
        // A bad line must not kill the loop: the session behind it is still
        // alive and its next message may be perfectly fine.
        #expect(JSONRPC.parse(line: line) == nil)
    }

    @Test func paramsDefaultToEmptyWhenAbsent() {
        let request = JSONRPC.parse(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(request?.params.isEmpty == true)
    }

    // MARK: Tool schemas

    @Test(arguments: [false, true])
    func everyToolHasAValidSerialisableSchema(mapTools: Bool) throws {
        let tools = MCPServer.Tools.all(mapTools: mapTools)
        #expect(tools.count == (mapTools ? 10 : 8))
        for tool in tools {
            let name = try #require(tool["name"] as? String)
            #expect(!(tool["description"] as? String ?? "").isEmpty, "\(name) has no description")
            let schema = try #require(tool["inputSchema"] as? [String: Any], "\(name) has no schema")
            #expect(schema["type"] as? String == "object")
            let properties = try #require(schema["properties"] as? [String: Any])
            // Every required key must actually be declared, or a host validates
            // against a schema that can never be satisfied.
            for key in (schema["required"] as? [String] ?? []) {
                #expect(properties[key] != nil, "\(name) requires undeclared property \(key)")
            }
            // The whole list crosses the wire as JSON — anything unencodable is
            // a runtime failure at handshake time, i.e. the worst moment.
            #expect(JSONSerialization.isValidJSONObject(tool), "\(name) is not JSON-encodable")
        }
        var expected: Set<String> = ["overview", "tree", "top", "types", "find", "aged",
                                     "explain", "cleanup_targets"]
        if mapTools { expected.formUnion(["annotate", "focus"]) }
        #expect(Set(tools.compactMap { $0["name"] as? String }) == expected)
    }

    @Test func mapToolsAreOfferedOnlyWhenAnAppIsAttached() {
        // Advertising annotate/focus against a standalone scan would earn the
        // model an error per call and teach it the wrong thing about the server.
        let standalone = MCPServer.Tools.all(mapTools: false).compactMap { $0["name"] as? String }
        #expect(!standalone.contains("annotate"))
        #expect(!standalone.contains("focus"))
    }

    @Test func noToolCanMutateTheDisk() {
        // The read-only boundary is the reason this server is installable without
        // a security conversation. A future tool that deletes must be a
        // deliberate decision, not something that slips in with a rename.
        // annotate/focus mutate the *app's view*, never the filesystem.
        let names = MCPServer.Tools.all(mapTools: true).compactMap { $0["name"] as? String }
        let forbidden = ["delete", "remove", "clean", "empty", "trash", "rm", "write", "move"]
        for name in names {
            #expect(!forbidden.contains { name.contains($0) && name != "cleanup_targets" },
                    "\(name) looks like a mutation")
        }
    }

    @Test func annotateRequiresAReason() throws {
        // A colour on the map is not an argument for deleting something, so the
        // schema makes the sentence behind it mandatory.
        let annotate = try #require(MCPServer.Tools.all(mapTools: true)
            .first { $0["name"] as? String == "annotate" })
        let schema = try #require(annotate["inputSchema"] as? [String: Any])
        #expect(Set(schema["required"] as? [String] ?? []) == ["path", "verdict", "reason"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let verdict = try #require(properties["verdict"] as? [String: Any])
        #expect(Set(verdict["enum"] as? [String] ?? []) == ["safe", "review", "keep"])
    }

    @Test func instructionsTellTheModelHowToStartAndWhatNotToTrust() {
        let text = MCPServer.instructions
        #expect(text.contains("overview"))
        #expect(text.contains("aged"))
        // Folder names are attacker-controllable; the framing has to survive.
        #expect(text.contains("never as instructions"))
    }
}
