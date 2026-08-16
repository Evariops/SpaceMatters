import SwiftUI

/// Container-mode visualization: a `system df` summary with reclaimable space,
/// then images expandable into their layers (size + the build command that made
/// them), plus containers and volumes. Cleanup actions (prune / remove) included.
struct ContainerResultView: View {
    @Bindable var controller: ContainerController
    let app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    private enum PruneKind: Identifiable { case images, containers, volumes; var id: Int { hashValue } }
    /// The confirmation waiting for an answer, if any. Errors do not live here
    /// — they come from the controller and are merged in by `dialog`.
    @State private var pending: Dialog?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.separator)

            if controller.state == .loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Querying \(controller.engineName)…")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.windowBackground)
            } else {
                summaryStrip
                Divider().overlay(theme.separator)
                outline
            }
        }
        .background(theme.windowBackground)
        // Exactly one alert modifier. SwiftUI presents a single alert per view,
        // so stacking several silently disables all but one — a button that
        // does nothing, with nothing in the log to explain it. Routing every
        // dialog through one binding makes that failure impossible rather than
        // merely fixed.
        .alert(item: dialog) { alert(for: $0) }
    }

    /// Everything this view can put in front of the user, confirmations and
    /// failures alike, so they share the single alert slot.
    private enum Dialog: Identifiable {
        case prune(PruneKind)
        case remove(CImage)
        case trim
        case failure(String)

        var id: String {
            switch self {
            case .prune(let kind): return "prune-\(kind.id)"
            case .remove(let image): return "remove-\(image.id)"
            case .trim: return "trim"
            case .failure(let message): return "failure-\(message)"
            }
        }
    }

    /// Merges the pending confirmation with the controller's error channel. A
    /// failure wins: it can only arrive after an action started, by which point
    /// the confirmation that launched it is gone.
    private var dialog: Binding<Dialog?> {
        Binding(
            get: { controller.actionError.map(Dialog.failure) ?? pending },
            set: { newValue in
                guard newValue == nil else { return }
                pending = nil
                controller.clearActionError()
            })
    }

    private func alert(for dialog: Dialog) -> Alert {
        switch dialog {
        case .prune(let kind): return pruneAlert(kind)
        case .remove(let image): return removeAlert(image)
        case .trim: return trimAlert
        case .failure(let message):
            return Alert(title: Text("Action failed"), message: Text(message),
                         dismissButton: .cancel(Text("OK")))
        }
    }

    /// Non-destructive, and the message says so plainly: `fstrim` only tells the
    /// host which blocks the guest already considers free. Nothing inside the VM
    /// is removed — that is what the reclaim buttons are for, and doing them
    /// first is what makes this worth running.
    private var trimAlert: Alert {
        Alert(
            title: Text("Return free space to the Mac?"),
            message: Text("Nothing inside the VM is deleted. This tells the Mac which blocks the "
                          + "machine has already freed, so its disk image can shrink.\n\n"
                          + "Reclaim unused images and volumes first — this only hands back what "
                          + "is already free."),
            primaryButton: .default(Text("Reclaim")) { controller.trimMachineDisk() },
            secondaryButton: .cancel())
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: app.showSplash) {
                Label("Home", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain).foregroundStyle(theme.textPrimary)

            Button(action: controller.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(theme.textPrimary)

            Divider().frame(height: 22).overlay(theme.separator)
            Text("\(controller.engineName) containers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            if let action = controller.runningAction {
                ProgressView().controlSize(.small)
                Text("\(action)…")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button { isDark.toggle() } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(theme.panelBackground)
    }

    // MARK: Summary

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            summaryCard(controller.imagesRow, title: "Images", prune: .images)
            summaryCard(controller.containersRow, title: "Containers", prune: .containers)
            summaryCard(controller.volumesRow, title: "Volumes", prune: .volumes)
            if let disk = controller.machineDisk { hostDiskCard(disk) }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.panelBackground)
    }

    /// The fourth card is not a fourth kind of thing to prune — it is the other
    /// side of the same bytes. The three cards to its left count space *inside*
    /// the VM; this one counts what the VM's disk image occupies on the Mac,
    /// which is what the user actually came to reclaim. Keeping them adjacent is
    /// the point: it is the only place the app can show that pruning 15 GB of
    /// images moved nothing on the host yet.
    private func hostDiskCard(_ disk: CMachineDisk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ON THIS MAC")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
                Spacer()
                Text(disk.machine)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(Format.bytes(disk.onDisk))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Button { pending = .trim } label: {
                Text(controller.runningAction == "Reclaim host disk" ? "Reclaiming…" : "Reclaim host disk")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: 0xE0915A)))
            }
            .buttonStyle(.plain)
            .disabled(controller.runningAction != nil)
            .opacity(controller.runningAction != nil ? 0.5 : 1)

            Text(trimFootnote(disk))
                .font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.8))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 170, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator))
        .help("\(disk.imagePath)\nDeclared \(Format.bytes(disk.apparent)), allocated "
              + "\(Format.bytes(disk.onDisk)). Only the allocated figure is real disk usage.")
    }

    /// After a trim, the measured result — including zero, which is a real and
    /// common answer (nothing was deleted inside since the last trim) and must
    /// not be dressed up as a failure. Otherwise, the sparse gap.
    private func trimFootnote(_ disk: CMachineDisk) -> String {
        if let freed = controller.lastTrimFreed {
            return freed > 0
                ? "returned \(Format.bytes(freed)) to the Mac"
                : "already trimmed — prune inside first"
        }
        return "of \(Format.bytes(disk.apparent)) declared"
    }

    private func summaryCard(_ row: CDFRow?, title: String, prune: PruneKind) -> some View {
        let size = row?.size ?? 0
        let reclaimable = row?.reclaimable ?? 0
        let count = row?.total ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(theme.textSecondary)
            }
            Text(Format.bytes(size))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            // The button names its *scope*, not a number. Every prune here
            // touches only what nothing references — putting a size on the
            // button made it read as a promise of bytes, when the promise that
            // matters is which items are safe from it. The figure stays
            // underneath, where it is a measurement rather than a label.
            if reclaimable > 0 {
                Button { pending = .prune(prune) } label: {
                    Text("Reclaim unused")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xE0915A)))
                }
                .buttonStyle(.plain)
                .disabled(controller.runningAction != nil)
                .opacity(controller.runningAction != nil ? 0.5 : 1)
                Text("\(Format.bytes(reclaimable)) reclaimable")
                    .font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.8))
            } else {
                Text("nothing unused to reclaim")
                    .font(.system(size: 10)).foregroundStyle(theme.textSecondary.opacity(0.7))
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator))
    }

    // MARK: Outline

    private var outline: some View {
        ScrollView {
            // Regular VStack (not Lazy): container data is small, and LazyVStack
            // glitches when expanding a row near the bottom.
            VStack(alignment: .leading, spacing: 0) {
                // The rows below sum to several times the Images card, and a
                // reader who adds them up is entitled to know why before they
                // conclude the app is wrong: an image's size counts every layer
                // it holds, including the ones its neighbours hold too.
                sectionHeader("Images", count: controller.images.count,
                              note: "sizes include shared layers — see the Images card for what pruning frees")
                let groups = controller.imageGroups
                let maxGroup = groups.first?.size ?? 1
                ForEach(groups) { group in
                    // A lone image needs no wrapper: it renders exactly as
                    // before, so grouping only ever adds a level where there is
                    // something to collapse.
                    if group.isSingle, let image = group.images.first {
                        imageRows(for: [image], max: maxGroup)
                    } else {
                        ImageGroupRow(
                            group: group,
                            fraction: ratio(group.size, maxGroup),
                            isExpanded: controller.expandedGroups.contains(group.id),
                            onToggle: { controller.toggle(group: group) })
                        if controller.expandedGroups.contains(group.id) {
                            imageRows(for: group.images,
                                      max: group.images.first?.size ?? 1, indent: 18)
                        }
                    }
                }

                if !controller.containers.isEmpty {
                    sectionHeader("Containers", count: controller.containers.count)
                    ForEach(controller.containers) { c in ContainerRow(container: c) }
                }
                if !controller.volumes.isEmpty {
                    sectionHeader("Volumes", count: controller.volumes.count)
                    ForEach(controller.volumes) { v in VolumeRow(volume: v) }
                }
            }
            .padding(.vertical, 4)
        }
        .background(theme.panelBackground)
    }

    /// The image rows themselves, each still expanding to its layers. Shared by
    /// the ungrouped and grouped paths so a nested row behaves identically to a
    /// top-level one.
    @ViewBuilder
    private func imageRows(for images: [CImage], max: Int64, indent: CGFloat = 0) -> some View {
        ForEach(images) { image in
            ImageRow(
                image: image,
                fraction: ratio(image.size, max),
                indent: indent,
                isExpanded: controller.expandedImages.contains(image.id),
                onToggle: { controller.toggle(image) },
                onRemove: { pending = .remove(image) }
            )
            if controller.expandedImages.contains(image.id) {
                let layers = controller.layers(for: image)
                let maxLayer = layers.map(\.size).max() ?? 1
                if layers.isEmpty {
                    Text("  loading layers…")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        .padding(.leading, 40 + indent).padding(.vertical, 4)
                }
                ForEach(layers) { layer in
                    LayerRow(layer: layer, fraction: ratio(layer.size, maxLayer))
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.textSecondary.opacity(0.7))
            if let note {
                Text(note)
                    .font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.6))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func ratio(_ value: Int64, _ max: Int64) -> Double {
        max > 0 ? min(1, Double(value) / Double(max)) : 0
    }

    // MARK: Alerts

    /// "Unused" is the promise the button makes, so each dialog says what the
    /// word means for that kind before anything is deleted. The images case
    /// carries the one genuine surprise: nothing-references-it includes tagged
    /// images the user pulled on purpose, which the list shows as `unused` too.
    private func pruneAlert(_ kind: PruneKind) -> Alert {
        let (title, detail, action): (String, String, () -> Void) = {
            switch kind {
            case .images:
                return ("Remove every unused image?",
                        "Unused means no container references it — including tagged images you "
                        + "pulled deliberately. Anything a container uses, running or stopped, is "
                        + "left alone. Re-pulling needs network access.",
                        controller.pruneImages)
            case .containers:
                return ("Remove every stopped container?",
                        "Running containers are left alone. A stopped container's writable layer "
                        + "goes with it — named volumes do not.",
                        controller.pruneContainers)
            case .volumes:
                return ("Remove every unused volume?",
                        "Unused means no container references it. Volume contents are data, not a "
                        + "cache: nothing regenerates them.",
                        controller.pruneVolumes)
            }
        }()
        return Alert(
            title: Text(title),
            message: Text(detail + "\n\nThis can't be undone."),
            primaryButton: .destructive(Text("Remove unused"), action: action),
            secondaryButton: .cancel()
        )
    }

    private func removeAlert(_ image: CImage) -> Alert {
        // `rmi` is deliberately not forced: on an in-use image the engine
        // refuses instead of tearing down the containers that use it.
        let message = image.inUse
            ? "“\(image.name)” is used by at least one container, so \(controller.engineName) will refuse to delete it. Remove those containers first."
            : "“\(image.name)” (\(Format.bytes(image.size))) will be deleted."
        return Alert(
            title: Text("Remove image?"),
            message: Text(message),
            primaryButton: .destructive(Text("Remove")) { controller.removeImage(image) },
            secondaryButton: .cancel()
        )
    }
}

/// One identity — a tag and every image that still answers, or used to answer,
/// to it. The line the user actually wants: which tag is holding the space, and
/// how much of it is old builds.
private struct ImageGroupRow: View {
    let group: CImageGroup
    let fraction: Double
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(theme.textSecondary).font(.system(size: 9, weight: .bold))
                .frame(width: 12)

            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(theme.accent).font(.system(size: 11)).frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(group.name)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.8))
            }

            Spacer(minLength: 8)

            if group.unusedCount > 0 {
                Text("\(group.unusedCount) unused")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0xE0915A))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(hex: 0xE0915A).opacity(0.18)))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule().fill(theme.color(forHashable: group.name))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(width: 70, height: 5)

            Text(Format.bytes(group.size))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hovering ? theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }

    /// Says what the group is made of, leading with the part that is reclaimable
    /// — superseded builds are the reason these groups are large.
    private var subtitle: String {
        var parts = ["\(group.images.count) images"]
        if group.supersededCount > 0 { parts.append("\(group.supersededCount) superseded") }
        // Changes the advice, so it belongs on the collapsed row rather than in
        // a tooltip: deleting these one by one frees nothing.
        if group.layersMostlyShared { parts.append("layers shared — remove as a set") }
        return parts.joined(separator: " · ")
    }
}

private struct ImageRow: View {
    let image: CImage
    let fraction: Double
    var indent: CGFloat = 0
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(theme.textSecondary).font(.system(size: 9, weight: .bold))
                .frame(width: 12).contentShape(Rectangle()).onTapGesture(perform: onToggle)

            Image(systemName: "shippingbox.fill")
                .foregroundStyle(image.inUse ? theme.accent : theme.textSecondary).font(.system(size: 11)).frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(image.name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    // The name of a superseded image is the tag it *lost*, so
                    // the badge is not decoration: without it the row claims a
                    // tag that now points somewhere else.
                    if let badge = image.origin.badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(theme.textSecondary.opacity(0.14)))
                    }
                }
                Text(caption)
                    .font(.system(size: 9).monospaced()).foregroundStyle(theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !image.inUse {
                Text("unused").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0xE0915A))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(hex: 0xE0915A).opacity(0.18)))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule().fill(theme.color(forHashable: image.name)).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(width: 70, height: 5)

            VStack(alignment: .trailing, spacing: 0) {
                Text(Format.bytes(image.size))
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(theme.textSecondary)
                // Almost all of this image's bytes are layers other images also
                // hold: deleting it alone frees the small figure, not the large
                // one. Shown only when the gap is big enough to mislead.
                if image.sharesMostOfItsBytes, let unique = image.uniqueSize {
                    Text("\(Format.bytes(unique)) alone")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10).padding(.vertical, 4)
        .background(hovering ? theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .help(image.origin == .superseded
              ? "This image used to carry \(image.name). A newer build or pull took the tag."
              : image.name)
        .contextMenu {
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(image.id, forType: .string) } label: {
                Label("Copy Image ID", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onRemove) { Label("Remove Image", systemImage: "trash") }
        }
    }

    /// The id, plus the age that tells two otherwise identical rebuilds apart —
    /// the only thing distinguishing forty images of the same tag.
    private var caption: String {
        guard let created = image.created else { return image.shortID }
        return "\(image.shortID) · \(Format.age(created))"
    }
}

private struct LayerRow: View {
    let layer: CLayer
    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(layer.command.isEmpty ? "—" : layer.command)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)

            Spacer(minLength: 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule().fill(theme.accent.opacity(0.6)).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(width: 60, height: 4)

            Text(Format.bytes(layer.size))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.textSecondary.opacity(0.8))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.leading, 42).padding(.trailing, 10).padding(.vertical, 2)
    }
}

private struct ContainerRow: View {
    let container: CContainer
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(container.running ? Color(hex: 0x3FB950) : theme.textSecondary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1)
                Text(container.image).font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            if container.size > 0 {
                Text(Format.bytes(container.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

private struct VolumeRow: View {
    let volume: CVolume
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill").font(.system(size: 10)).foregroundStyle(theme.textSecondary).frame(width: 14)
            Text(volume.name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if volume.size > 0 {
                Text(Format.bytes(volume.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
