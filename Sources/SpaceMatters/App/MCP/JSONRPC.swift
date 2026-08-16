import Foundation

/// Newline-delimited JSON-RPC 2.0 over stdin/stdout — the MCP stdio transport.
///
/// Hand-rolled on `JSONSerialization` rather than pulled in as a dependency:
/// the protocol surface this server needs is three methods and one notification,
/// and the messages are dynamic by nature (a tool's arguments have no static
/// shape), so `Codable` would buy ceremony rather than safety.
enum JSONRPC {

    /// Errors as the spec numbers them, plus the one application code we raise.
    enum Code: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }

    struct Request {
        /// Absent for notifications — which must never be answered.
        let id: Any?
        let method: String
        let params: [String: Any]
        var isNotification: Bool { id == nil }
    }

    /// stdout is the protocol channel: **nothing** may print to it but responses.
    /// Diagnostics go to stderr, where the host shows them as server logs.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[spacematters-mcp] \(message)\n".utf8))
    }

    private static let outLock = NSLock()

    static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            log("failed to encode a response — dropping it")
            return
        }
        outLock.lock()
        defer { outLock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func respond(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func fail(id: Any, code: Code, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code.rawValue, "message": message]])
    }

    /// Parse one line. `nil` for a blank line or anything unparseable — a
    /// malformed line must not kill the loop, because the session behind it is
    /// still alive and its next message may be fine.
    static func parse(line: String) -> Request? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else { return nil }
        return Request(id: object["id"],
                       method: method,
                       params: object["params"] as? [String: Any] ?? [:])
    }

    /// Blocking read loop over stdin. Returns when the stream closes — which is
    /// how an MCP host says "session over".
    static func serve(_ handle: (Request) -> Void) {
        while let line = readLine(strippingNewline: true) {
            guard let request = parse(line: line) else {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log("ignoring unparseable line")
                }
                continue
            }
            handle(request)
        }
    }
}
