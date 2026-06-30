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

    var expandedImages: Set<String> = []
    private(set) var layerCache: [String: [CLayer]] = [:]

    private var engine: ContainerEngine?

    var imagesRow: CDFRow? { df.first { $0.type.lowercased().contains("image") } }
    var containersRow: CDFRow? { df.first { $0.type.lowercased().contains("container") } }
    var volumesRow: CDFRow? { df.first { $0.type.lowercased().contains("volume") } }

    func load(engine: ContainerEngine) {
        self.engine = engine
        engineName = engine.displayName
        state = .loading
        df = []; images = []; containers = []; volumes = []
        expandedImages = []; layerCache = [:]
        Task { await reload() }
    }

    func refresh() {
        guard let engine else { return }
        load(engine: engine)
    }

    func stop() { /* no long-running work to cancel */ }

    private func reload() async {
        guard let engine else { return }
        let snapshot = await Task.detached(priority: .userInitiated) { ContainerQueries.fetchAll(engine) }.value
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
        Task {
            let layers = await Task.detached(priority: .userInitiated) {
                ContainerQueries.history(engine, imageID: image.id)
            }.value
            layerCache[image.id] = layers
        }
    }

    // MARK: Cleanup actions

    func removeImage(_ image: CImage) { run(["rmi", "-f", image.id]) }
    func pruneImages() { run(["image", "prune", "-a", "-f"]) }
    func pruneContainers() { run(["container", "prune", "-f"]) }
    func pruneVolumes() { run(["volume", "prune", "-f"]) }
    func removeContainer(_ container: CContainer) { run(["rm", "-f", container.id]) }

    private func run(_ args: [String]) {
        guard let engine else { return }
        Task {
            _ = await Task.detached(priority: .userInitiated) { VMProbe.capture(engine.executable, args) }.value
            await reload()
        }
    }
}
