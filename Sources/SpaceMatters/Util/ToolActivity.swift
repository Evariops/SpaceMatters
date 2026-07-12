import Foundation

/// Which running developer tools make cleaning a given target risky right now.
///
/// Cleaning a cache under a tool that is using it makes the tool's in-flight
/// operation fail (a build, an install, an upgrade). The dangerous case —
/// Homebrew mid-`upgrade --cask`, whose uninstall→reinstall window sources
/// from the cache — is closed structurally by running `brew cleanup` instead
/// of deleting files (NativeCleaner). Everything else gets a *named* warning
/// in the confirmation dialog, not a lock: best-effort, same-user processes
/// only, matched on the kernel's `p_comm` (argv is read only to tell a Gradle
/// daemon or Maven apart from any other JVM).
enum ToolActivity {

    /// target id → display names of the tools found running.
    static func activeTools(for targetIDs: Set<String>) -> [String: Set<String>] {
        var found: [String: Set<String>] = [:]
        for proc in processList() {
            for hit in classify(comm: proc.comm, argv: arguments(of: proc.pid))
            where targetIDs.contains(hit.target) {
                found[hit.target, default: []].insert(hit.tool)
            }
        }
        return found
    }

    /// Pure classification, injectable in tests: one process (its `p_comm`,
    /// argv fetched lazily — only JVMs need it) → the targets it puts at risk.
    static func classify(comm: String, argv: @autoclosure () -> [String])
        -> [(target: String, tool: String)] {
        if let targets = commTargets[comm] {
            return targets.map { ($0, comm) }
        }
        guard comm == "java" else { return [] }
        let joined = argv().joined(separator: " ")
        if joined.contains("org.gradle.launcher.daemon") { return [("gradle", "a Gradle daemon")] }
        if joined.contains("org.codehaus.plexus.classworlds") { return [("maven", "Maven")] }
        return []
    }

    /// `p_comm` (16 chars, enough for every name here) → catalog target ids.
    /// `brew` is the bash wrapper script, alive for the whole run — the ruby
    /// child doesn't need matching. Xcode builds also touch the SwiftPM cache
    /// (package resolution), hence the double mapping.
    private static let commTargets: [String: [String]] = [
        "Xcode": ["derived-data", "swiftpm"],
        "xcodebuild": ["derived-data", "swiftpm"],
        "swift-build": ["swiftpm"],
        "swift-package": ["swiftpm"],
        "pod": ["cocoapods"],
        "npm": ["npm"],
        "npx": ["npm"],
        "yarn": ["yarn"],
        "pnpm": ["pnpm"],
        "dotnet": ["nuget"],
        "msbuild": ["nuget"],
        "pip": ["pip"],
        "pip3": ["pip"],
        "uv": ["uv"],
        "gradle": ["gradle"],
        "mvn": ["maven"],
        "mvnd": ["maven"],
        "cargo": ["cargo"],
        "go": ["go-build"],
        "brew": ["homebrew"],
    ]

    // MARK: Process plumbing

    /// Same-uid processes with their kernel short name. One sysctl, no
    /// privileges needed; failures degrade to "no warning", never to a block.
    private static func processList() -> [(pid: pid_t, comm: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += MemoryLayout<kinfo_proc>.stride * 16 // headroom: procs spawn between the two calls
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<kinfo_proc>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, 4, buffer, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        let procs = buffer.bindMemory(to: kinfo_proc.self, capacity: count)
        return (0..<count).compactMap { i in
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { return nil }
            let comm = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return (pid, comm)
        }
    }

    /// argv of a same-uid process via `KERN_PROCARGS2`. Layout: argc (Int32),
    /// exec_path NUL-terminated, NUL padding, then argc NUL-terminated args
    /// (environment follows — never read). Any failure returns [].
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }

        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var idx = MemoryLayout<Int32>.size
        while idx < size && buf[idx] != 0 { idx += 1 } // skip exec_path
        while idx < size && buf[idx] == 0 { idx += 1 } // skip padding

        var args: [String] = []
        var start = idx
        while idx < size && args.count < argc {
            if buf[idx] == 0 {
                args.append(String(decoding: buf[start..<idx], as: UTF8.self))
                start = idx + 1
            }
            idx += 1
        }
        return args
    }
}
