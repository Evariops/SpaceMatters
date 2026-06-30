import Foundation

enum VMRuntime: String {
    case podman = "Podman"
    case colima = "Colima"
}

enum VMScope: String {
    case full        // entire VM filesystem
    case containers  // container/image storage only
}

/// A detected Podman machine / Colima profile.
struct VMMachine: Identifiable {
    let runtime: VMRuntime
    let name: String
    let running: Bool
    let diskBytes: Int64
    let executable: String
    var id: String { "\(runtime.rawValue):\(name)" }
}

enum VMProbe {
    /// Locate a CLI even under the trimmed PATH a GUI .app inherits.
    static func locate(_ name: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/podman/bin", "/opt/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        let fm = FileManager.default
        for dir in dirs where fm.isExecutableFile(atPath: dir + "/" + name) {
            return dir + "/" + name
        }
        return nil
    }

    static func capture(_ executable: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Detect installed Podman machines and Colima profiles with their state.
    static func detect() -> [VMMachine] {
        var result: [VMMachine] = []

        if let podman = locate("podman"),
           let json = capture(podman, ["machine", "list", "--format", "json"]),
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for m in arr {
                let name = m["Name"] as? String ?? "default"
                let running = (m["Running"] as? Bool) ?? false
                let disk = Int64((m["DiskSize"] as? String) ?? "") ?? ((m["DiskSize"] as? NSNumber)?.int64Value ?? 0)
                result.append(VMMachine(runtime: .podman, name: name, running: running, diskBytes: disk, executable: podman))
            }
        }

        if let colima = locate("colima"),
           let text = capture(colima, ["list", "--json"]) {
            // colima emits one JSON object per line (JSONL).
            for line in text.split(whereSeparator: \.isNewline) {
                guard let data = line.data(using: .utf8),
                      let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let name = m["name"] as? String ?? "default"
                let running = (m["status"] as? String ?? "").lowercased() == "running"
                let disk = (m["disk"] as? NSNumber)?.int64Value ?? 0
                result.append(VMMachine(runtime: .colima, name: name, running: running, diskBytes: disk, executable: colima))
            }
        }

        return result
    }

    /// Where container/image storage lives inside the VM (resolved dynamically;
    /// rootless Podman keeps it under the user's home).
    static func containerStoragePath(for machine: VMMachine) -> String {
        switch machine.runtime {
        case .podman:
            if let out = capture(machine.executable, ["info", "--format", "{{.Store.GraphRoot}}"]) {
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return "/var/lib/containers/storage"
        case .colima:
            return "/var/lib/docker"
        }
    }

    /// Build the streamed-`find` command for a VM scan. `stdbuf -oL` forces
    /// line-buffered output so results stream out continuously (reactive UI).
    static func scanCommand(machine: VMMachine, scope: VMScope) -> (executable: String, arguments: [String], rootPath: String) {
        let rootPath = scope == .full ? "/" : containerStoragePath(for: machine)
        let remote = "sudo stdbuf -oL find \(rootPath) -xdev -printf '%y\\t%b\\t%s\\t%p\\n'"
        switch machine.runtime {
        case .podman:
            return (machine.executable, ["machine", "ssh", machine.name, remote], rootPath)
        case .colima:
            return (machine.executable, ["ssh", "--profile", machine.name, "--", "sh", "-c", remote], rootPath)
        }
    }
}
