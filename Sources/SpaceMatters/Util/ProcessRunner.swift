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

/// Runs external commands (`podman`, `kubectl`, `colima`…) with a **hard
/// timeout** and cooperative cancellation. Every one-shot shell-out goes through
/// here so an unreachable API server or a wedged VM can never freeze the UI: the
/// process is terminated (SIGTERM, then SIGKILL) instead of blocking forever.
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
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Core

    private static func execute(_ process: Process, _ outPipe: Pipe, _ errPipe: Pipe, timeout: TimeInterval) -> ProcessResult {
        do {
            try process.run()
        } catch {
            return ProcessResult(stdout: Data(), stderr: Data("\(error)".utf8), exitCode: -1, timedOut: false)
        }

        // Drain both pipes concurrently so the child never blocks on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }

        // Watchdog: SIGTERM at the deadline, SIGKILL shortly after if still alive.
        let timedOut = Atomic<Bool>(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.store(true, ordering: .relaxed)
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait() // ensure both readers finished before returning their buffers

        return ProcessResult(
            stdout: outData,
            stderr: errData,
            exitCode: process.terminationStatus,
            timedOut: timedOut.load(ordering: .relaxed)
        )
    }
}
