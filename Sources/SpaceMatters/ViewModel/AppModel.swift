import Foundation
import Observation

/// Top-level router for the app's analysis **modes**. Each mode owns its own
/// engine + controller + result view; the splash discovers targets across all
/// modes. Filesystem (local disks, folders, VM filesystems) uses `ScanController`
/// + the treemap; Containers uses `ContainerController` + its own view.
@MainActor
@Observable
final class AppModel {
    enum Route: Equatable { case splash, filesystem, containers, kubernetes, cleanup }
    private(set) var route: Route = .splash

    let filesystem = ScanController()
    let containers = ContainerController()
    let kubernetes = KubernetesController()
    let cleanup = CleanupController()

    func showSplash() {
        filesystem.goHome()
        containers.stop()
        kubernetes.stop()
        cleanup.stop()
        route = .splash
    }

    /// `--open <path>`: scan a folder straight from the GUI launch (handy for a
    /// "reveal in / open with SpaceMatters" flow, and for driving the app in tests).
    @ObservationIgnored private var didHandleLaunch = false
    func handleLaunchArgumentsOnce() {
        guard !didHandleLaunch else { return }
        didHandleLaunch = true
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--open"), idx + 1 < args.count else { return }
        route = .filesystem
        filesystem.scan(url: URL(fileURLWithPath: args[idx + 1]))
    }

    // MARK: Filesystem mode

    func scan(volumes: [Volume]) {
        route = .filesystem
        filesystem.scan(volumes: volumes)
    }

    func scanVMFilesystem(_ machine: VMMachine) {
        route = .filesystem
        filesystem.scanVM(machine: machine, scope: .full)
    }

    /// Scan only the VM's image/container storage (GraphRoot) — the subtree a dev
    /// usually cares about when a Podman/Colima VM has grown large.
    func scanVMContainers(_ machine: VMMachine) {
        route = .filesystem
        filesystem.scanVM(machine: machine, scope: .containers)
    }

    func openFolder() {
        filesystem.chooseFolderAndScan()
        if filesystem.root != nil { route = .filesystem }
    }

    /// Scan an arbitrary host over SSH (streamed `find`, read-only) — SPEC-06.
    func scanRemote(_ target: SSHTarget) {
        route = .filesystem
        filesystem.scanRemote(target)
    }

    // MARK: Container mode

    func analyzeContainers(_ engine: ContainerEngine) {
        route = .containers
        containers.load(engine: engine)
    }

    // MARK: Kubernetes mode

    func analyzeKubernetes(context: String) {
        route = .kubernetes
        kubernetes.load(context: context)
    }

    // MARK: Cleanup mode (Low-Hanging Fruits)

    func analyzeCleanup() {
        route = .cleanup
        cleanup.load()
    }
}
