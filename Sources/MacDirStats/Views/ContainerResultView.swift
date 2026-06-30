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
    @State private var confirmPrune: PruneKind?
    @State private var confirmRemove: CImage?

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
        .alert(item: $confirmPrune) { kind in pruneAlert(kind) }
        .alert(item: $confirmRemove) { image in removeAlert(image) }
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
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.panelBackground)
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
            if reclaimable > 0 {
                Button { confirmPrune = prune } label: {
                    Text("Reclaim \(Format.bytes(reclaimable))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xE0915A)))
                }
                .buttonStyle(.plain)
            } else {
                Text("nothing to reclaim")
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
                sectionHeader("Images", count: controller.images.count)
                let maxImage = controller.images.first?.size ?? 1
                ForEach(controller.images) { image in
                    ImageRow(
                        image: image,
                        fraction: ratio(image.size, maxImage),
                        isExpanded: controller.expandedImages.contains(image.id),
                        onToggle: { controller.toggle(image) },
                        onRemove: { confirmRemove = image }
                    )
                    if controller.expandedImages.contains(image.id) {
                        let layers = controller.layers(for: image)
                        let maxLayer = layers.map(\.size).max() ?? 1
                        if layers.isEmpty {
                            Text("  loading layers…")
                                .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                                .padding(.leading, 40).padding(.vertical, 4)
                        }
                        ForEach(layers) { layer in
                            LayerRow(layer: layer, fraction: ratio(layer.size, maxLayer))
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

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.textSecondary.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func ratio(_ value: Int64, _ max: Int64) -> Double {
        max > 0 ? min(1, Double(value) / Double(max)) : 0
    }

    // MARK: Alerts

    private func pruneAlert(_ kind: PruneKind) -> Alert {
        let (title, action): (String, () -> Void) = {
            switch kind {
            case .images: return ("Remove all unused images?", controller.pruneImages)
            case .containers: return ("Remove all stopped containers?", controller.pruneContainers)
            case .volumes: return ("Remove all unused volumes?", controller.pruneVolumes)
            }
        }()
        return Alert(
            title: Text(title),
            message: Text("This frees the reclaimable space and can't be undone."),
            primaryButton: .destructive(Text("Prune"), action: action),
            secondaryButton: .cancel()
        )
    }

    private func removeAlert(_ image: CImage) -> Alert {
        Alert(
            title: Text("Remove image?"),
            message: Text("“\(image.name)” (\(Format.bytes(image.size))) will be deleted."),
            primaryButton: .destructive(Text("Remove")) { controller.removeImage(image) },
            secondaryButton: .cancel()
        )
    }
}

private struct ImageRow: View {
    let image: CImage
    let fraction: Double
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
                Text(image.name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(image.shortID).font(.system(size: 9).monospaced()).foregroundStyle(theme.textSecondary.opacity(0.7))
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

            Text(Format.bytes(image.size))
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(hovering ? theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(image.id, forType: .string) } label: {
                Label("Copy Image ID", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onRemove) { Label("Remove Image", systemImage: "trash") }
        }
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
