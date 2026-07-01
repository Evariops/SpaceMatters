import Foundation
import Observation

/// Top-level router for the app's analysis **modes**. Each mode owns its own
/// engine + controller + result view; the splash discovers targets across all
/// modes. Filesystem (local disks, folders, VM filesystems) uses `ScanController`
/// + the treemap; Containers uses `ContainerController` + its own view.
@MainActor
@Observable
final class AppModel {
    enum Route: Equatable { case splash, filesystem, containers, kubernetes }
    private(set) var route: Route = .splash

    let filesystem = ScanController()
    let containers = ContainerController()
    let kubernetes = KubernetesController()

    func showSplash() {
        filesystem.goHome()
        containers.stop()
        kubernetes.stop()
        route = .splash
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

    func openFolder() {
        filesystem.chooseFolderAndScan()
        if filesystem.root != nil { route = .filesystem }
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
}
