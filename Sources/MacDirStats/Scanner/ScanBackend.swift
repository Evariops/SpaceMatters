import Foundation

/// Where a scan's data comes from — lets the UI adapt (a remote/VM/archive scan
/// is read-only: no Trash, no Reveal-in-Finder) and label the result.
enum ScanSource: Equatable {
    case host                 // local getattrlistbulk
    case vm(String)           // Podman/Colima machine, streamed find over SSH
    case remote(String)       // an arbitrary SSH host
    case archive(String)      // a tar/zip listing (future)

    /// Host scans can mutate the disk (Trash/delete); everything else is read-only.
    var isReadOnly: Bool { self != .host }

    var label: String {
        switch self {
        case .host: return "This Mac"
        case .vm(let m): return m
        case .remote(let h): return h
        case .archive(let a): return a
        }
    }
}

/// A scan engine that fills an `FSNode` tree live. Implementations:
/// `DirectoryScanner` (local, getattrlistbulk) and `CommandScanner` (a streamed
/// `find` over SSH — inside a Podman/Colima VM, or to an arbitrary host). Both
/// update the same tree progressively so the UI reads sizes "au fil de l'eau".
///
/// This is the app's extension point (SPEC-06): a new source (SSH host, Time
/// Machine snapshot, archive) is a matter of producing the right `find` command
/// (or a new engine) plus a `ScanSource`.
protocol ScanBackend: AnyObject {
    func start()
    func cancel()
    var isFinished: Bool { get }
    var directoryCount: Int64 { get }
    var scanErrorCount: Int64 { get }
    /// A hard failure that made the whole scan meaningless (process couldn't run,
    /// remote `find` missing, exited non-zero with no output). `nil` on success —
    /// per-entry permission errors are counted in `scanErrorCount` instead.
    var failure: String? { get }
    func snapshotExtensions(metric: SizeMetric, limit: Int) -> [ExtRow]
    /// Subtract a deleted subtree's per-extension contribution from the live
    /// File-types table (A6). No-op for backends that don't support deletion.
    func subtractExtensions(_ delta: [ExtKey: ExtStat])
    /// What this scan is reading — drives read-only gating and labels.
    var source: ScanSource { get }
    /// One-line, human-readable description of what's being run (for the error
    /// channel / a "Copy diagnostics" affordance).
    func diagnostics() -> String
}

extension ScanBackend {
    var failure: String? { nil }
    func subtractExtensions(_ delta: [ExtKey: ExtStat]) {}
    var source: ScanSource { .host }
    func diagnostics() -> String { source.label }
}

/// Builds the streamed-`find` command every SSH-based backend shares. Records are
/// `<type>\t<blocks>\t<bytes>\t<path>\0` (NUL-terminated so newlines in names
/// can't split a record); `stdbuf -o0` keeps it unbuffered so results stream.
enum RemoteFind {
    static let printf = "%y\\t%b\\t%s\\t%p\\0"

    static func command(rootPath: String, sudo: Bool = false) -> String {
        "\(sudo ? "sudo " : "")stdbuf -o0 find \(shellQuote(rootPath)) -xdev -printf '\(printf)'"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A generic SSH scan target. Turns host/user/path into the `ssh … find …`
/// invocation `CommandScanner` streams — the whole SSH backend (SPEC-06).
struct SSHTarget: Equatable {
    var user: String
    var host: String
    var port: Int?
    var path: String
    var identityFile: String?
    var useSudo: Bool = false

    var label: String {
        let hostPart = user.isEmpty ? host : "\(user)@\(host)"
        return "\(hostPart):\(path)"
    }

    /// The `(executable, arguments, rootPath)` triple to hand to `CommandScanner`.
    /// `BatchMode=yes` fails fast instead of hanging on a password prompt (the app
    /// can't answer one); host keys are trusted on first use.
    func command() -> (executable: String, arguments: [String], rootPath: String) {
        var args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        if let port { args += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty { args += ["-i", identityFile] }
        args.append(user.isEmpty ? host : "\(user)@\(host)")
        args.append(RemoteFind.command(rootPath: path, sudo: useSudo))
        return ("/usr/bin/ssh", args, path)
    }
}
