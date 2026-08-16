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
    private(set) var machineDisk: CMachineDisk?
    /// Host bytes the last trim actually returned, measured by re-`stat`ing the
    /// image. Never taken from `fstrim`'s own output — see `trimMachineDisk`.
    private(set) var lastTrimFreed: Int64?

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
        machineDisk = nil; lastTrimFreed = nil
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
        machineDisk = snapshot.machineDisk
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

    /// Return the guest's free blocks to the host, shrinking the machine's
    /// sparse disk image.
    ///
    /// This is the step that makes every prune above visible on the Mac. Podman
    /// frees space *inside* the VM; the host file keeps the blocks until the
    /// guest filesystem discards them, and Fedora CoreOS only does that on a
    /// weekly timer. Running `fstrim` on demand collapses that week to now.
    ///
    /// Reads as a nothing-happened when run on its own after a fresh trim, and
    /// that is correct: there is nothing to give back until something inside has
    /// been deleted. Prune first, then trim.
    ///
    /// The freed figure is measured, never reported. `fstrim` prints the size of
    /// the free extents it walked, which on a mostly-empty filesystem is close
    /// to the whole disk — it read "39.5 GiB trimmed" for 2.06 GB actually
    /// returned in testing. Only the before/after `st_blocks` of the image is
    /// the truth.
    func trimMachineDisk() {
        guard let engine, engine.kind == .podman, let disk = machineDisk,
              runningAction == nil else { return }
        runningAction = "Reclaim host disk"
        actionError = nil
        lastTrimFreed = nil
        let id = loadID
        Task {
            let before = disk.onDisk
            // `/` and `/var` are the same XFS filesystem on a CoreOS machine;
            // trimming one covers both.
            let result = await ProcessRunner.run(
                engine.executable, ["machine", "ssh", disk.machine, "sudo", "fstrim", "/var"],
                timeout: 600)
            guard id == loadID else { return }
            runningAction = nil
            if result.ok {
                let after = ContainerQueries.machineDisk(engine)
                lastTrimFreed = max(0, before - (after?.onDisk ?? before))
            } else {
                actionError = "Reclaim host disk failed: \(result.diagnostic)"
            }
            await reload(id)
        }
    }

    func clearActionError() { actionError = nil }

    private func run(_ label: String, _ args: [String]) {
        guard let engine, runningAction == nil else { return }
        runningAction = label
        actionError = nil
        // A prune frees guest space and leaves the host image untouched, so the
        // previous trim's figure would now be describing a stale state.
        lastTrimFreed = nil
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
