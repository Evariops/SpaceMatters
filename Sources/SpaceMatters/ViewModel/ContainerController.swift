import Foundation
import Observation

/// Drives the container analysis mode: queries images/containers/volumes and (on
/// demand) per-image layers, and runs cleanup actions. Container queries are fast
/// CLI calls, so this loads quickly rather than streaming like a filesystem scan.
@MainActor
@Observable
final class ContainerController {
    enum State: Equatable { case idle, loading, ready }

    private(set) var state: State = .idle
    private(set) var engineName = ""
    private(set) var df: [CDFRow] = []
    private(set) var images: [CImage] = []
    private(set) var containers: [CContainer] = []
    private(set) var volumes: [CVolume] = []

    /// Failure of the last cleanup action (timeout, engine refusal…), surfaced
    /// as an alert — a prune that dies silently looks like a button that does
    /// nothing.
    private(set) var actionError: String?
    /// Label of the cleanup action currently running; disables the others.
    private(set) var runningAction: String?

    var expandedImages: Set<String> = []
    private(set) var layerCache: [String: [CLayer]] = [:]

    private var engine: ContainerEngine?
    /// Superseded-load guard (same pattern as the Kubernetes and Cleanup modes):
    /// a slow stale snapshot must never overwrite a newer engine's data.
    @ObservationIgnored private var loadID = 0

    var imagesRow: CDFRow? { df.first { $0.type.lowercased().contains("image") } }
    var containersRow: CDFRow? { df.first { $0.type.lowercased().contains("container") } }
    var volumesRow: CDFRow? { df.first { $0.type.lowercased().contains("volume") } }

    func load(engine: ContainerEngine) {
        self.engine = engine
        engineName = engine.displayName
        state = .loading
        df = []; images = []; containers = []; volumes = []
        expandedImages = []; layerCache = [:]
        actionError = nil
        runningAction = nil
        loadID += 1
        let id = loadID
        Task { await reload(id) }
    }

    func refresh() {
        guard let engine else { return }
        load(engine: engine)
    }

    /// Leaving the mode: orphan any in-flight reload or action result so a slow
    /// stale snapshot can't overwrite whatever the user looks at next.
    func stop() {
        loadID += 1
        runningAction = nil
    }

    private func reload(_ id: Int) async {
        guard let engine else { return }
        let snapshot = await Task.detached(priority: .userInitiated) { ContainerQueries.fetchAll(engine) }.value
        guard id == loadID else { return } // superseded (engine switched / mode left)
        df = snapshot.df
        images = snapshot.images.sorted { $0.size > $1.size }
        containers = snapshot.containers.sorted { $0.size > $1.size }
        volumes = snapshot.volumes.sorted { $0.size > $1.size }
        state = .ready
    }

    // MARK: Layers (lazy)

    func toggle(_ image: CImage) {
        if expandedImages.contains(image.id) {
            expandedImages.remove(image.id)
        } else {
            expandedImages.insert(image.id)
            loadLayersIfNeeded(image)
        }
    }

    func layers(for image: CImage) -> [CLayer] { layerCache[image.id] ?? [] }

    private func loadLayersIfNeeded(_ image: CImage) {
        guard layerCache[image.id] == nil, let engine else { return }
        let id = loadID
        Task {
            let layers = await Task.detached(priority: .userInitiated) {
                ContainerQueries.history(engine, imageID: image.id)
            }.value
            guard id == loadID else { return }
            layerCache[image.id] = layers
        }
    }

    // MARK: Cleanup actions
    //
    // All destructive, so none is fire-and-forget: they run with a long deadline
    // (a prune can walk tens of GB — the default 20 s would SIGKILL it mid-way)
    // and any failure or timeout surfaces in `actionError`.

    /// No `-f`: a forced `rmi` also stops and deletes the containers using the
    /// image. If it's in use the engine refuses and the refusal is shown as-is.
    func removeImage(_ image: CImage) { run("Remove image", ["rmi", image.id]) }
    func pruneImages() { run("Prune images", ["image", "prune", "-a", "-f"]) }
    func pruneContainers() { run("Prune containers", ["container", "prune", "-f"]) }
    func pruneVolumes() { run("Prune volumes", ["volume", "prune", "-f"]) }
    func removeContainer(_ container: CContainer) { run("Remove container", ["rm", "-f", container.id]) }

    func clearActionError() { actionError = nil }

    private func run(_ label: String, _ args: [String]) {
        guard let engine, runningAction == nil else { return }
        runningAction = label
        actionError = nil
        let id = loadID
        Task {
            let result = await ProcessRunner.run(engine.executable, args, timeout: 600)
            guard id == loadID else { return } // mode was left meanwhile
            runningAction = nil
            if !result.ok { actionError = "\(label) failed: \(result.diagnostic)" }
            await reload(id)
        }
    }
}
