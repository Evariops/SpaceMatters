import Foundation
import Synchronization

/// Outcome of an external command run through `ProcessRunner`.
struct ProcessResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    /// True when the watchdog had to kill the process for exceeding its deadline.
    let timedOut: Bool

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    /// A clean, non-timed-out, zero-exit run.
    var ok: Bool { exitCode == 0 && !timedOut }
    /// Short one-line diagnostic for the error channel (stderr, else a code).
    var diagnostic: String {
        if timedOut { return "timed out" }
        let err = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return String(err.prefix(400)) }
        return "exit code \(exitCode)"
    }
}

/// Best-effort signalling of a process **and its whole descendant tree**.
/// `Process.terminate` signals only the direct child: a wrapper (`podman`,
/// `colima`) that fork/execs `ssh` would leave the grandchild alive, still
/// holding the pipes' write ends open — so readers never see EOF and the
/// caller blocks forever. Descendants are enumerated via `proc_listpids`
/// (`PROC_PPID_ONLY`) before anyone is signalled.
enum ProcessTree {
    private static let PROC_PPID_ONLY: UInt32 = 6

    static func children(of pid: pid_t) -> [pid_t] {
        let bytes = proc_listpids(PROC_PPID_ONLY, UInt32(pid), nil, 0)
        guard bytes > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 16)
        let filled = proc_listpids(PROC_PPID_ONLY, UInt32(pid), &buf,
                                   Int32(buf.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        return buf.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// Signal `pid` and every live descendant. The tree is collected before the
    /// first kill (a dead parent re-parents its children away from us).
    static func signal(_ pid: pid_t, _ sig: Int32) {
        var all: [pid_t] = []
        var frontier = [pid]
        while let next = frontier.popLast() {
            let kids = children(of: next)
            all.append(contentsOf: kids)
            frontier.append(contentsOf: kids)
        }
        for p in all { kill(p, sig) }
        kill(pid, sig)
    }
}

/// Runs external commands (`podman`, `kubectl`, `colima`…) with a **hard
/// timeout** and cooperative cancellation. Every one-shot shell-out goes through
/// here so an unreachable API server or a wedged VM can never freeze the UI: the
/// whole process tree is terminated (SIGTERM, then SIGKILL) instead of blocking
/// forever.
///
/// Both pipes are drained on background threads to avoid the classic full-pipe
/// deadlock (a chatty child that fills the pipe while we wait on exit).
enum ProcessRunner {
    /// Synchronous run with a deadline. Safe to call from a detached task.
    static func runSync(_ executable: String, _ args: [String], timeout: TimeInterval = 20) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        return execute(process, outPipe, errPipe, timeout: timeout)
    }

    /// Async run with the same deadline, plus cooperative cancellation: cancelling
    /// the surrounding `Task` terminates the process instead of waiting it out.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 20) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: execute(process, outPipe, errPipe, timeout: timeout))
                }
            }
        } onCancel: {
            // Only a launched process can be terminated; the watchdog covers the
            // narrow window where launch hasn't happened yet.
            if process.isRunning { ProcessTree.signal(process.processIdentifier, SIGTERM) }
        }
    }

    // MARK: Core

    private static func execute(_ process: Process, _ outPipe: Pipe, _ errPipe: Pipe, timeout: TimeInterval) -> ProcessResult {
        do {
            try process.run()
        } catch {
            return ProcessResult(stdout: Data(), stderr: Data("\(error)".utf8), exitCode: -1, timedOut: false)
        }

        let pid = process.processIdentifier

        // Drain both pipes concurrently so the child never blocks on a full pipe.
        // Buffers live behind a lock: if an untracked descendant survives the
        // kill with our pipe open, we return the partial data instead of
        // blocking forever, and the straggler reader finishes in its own time.
        let buffers = PipeBuffers()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(outPipe.fileHandleForReading) { buffers.appendOut($0) }; group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(errPipe.fileHandleForReading) { buffers.appendErr($0) }; group.leave()
        }

        // Watchdog: SIGTERM the whole tree at the deadline (grandchildren like a
        // wrapper's `ssh` included), SIGKILL shortly after if still alive.
        let timedOut = Atomic<Bool>(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.store(true, ordering: .relaxed)
            ProcessTree.signal(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { ProcessTree.signal(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        // Both pipes EOF as soon as the tree is dead; the bounded wait only cuts
        // off a double-forked daemon that outlived the kill with our pipe open.
        _ = group.wait(timeout: .now() + 3)

        let (outData, errData) = buffers.snapshot()
        return ProcessResult(
            stdout: outData,
            stderr: errData,
            exitCode: process.terminationStatus,
            timedOut: timedOut.load(ordering: .relaxed)
        )
    }

    /// Incremental read so a timeout snapshot still holds everything received so
    /// far — `readDataToEndOfFile` would only publish at EOF, i.e. never when a
    /// straggler keeps the pipe open, losing the whole output.
    private static func drain(_ handle: FileHandle, _ sink: (Data) -> Void) {
        while true {
            let chunk = handle.availableData // blocks until data; empty == EOF
            if chunk.isEmpty { return }
            sink(chunk)
        }
    }

    /// stdout/stderr accumulators shared with the drain threads.
    private final class PipeBuffers: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
        func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}
