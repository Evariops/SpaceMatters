import SwiftUI

/// Kubernetes storage mode: namespaces → pods → PVCs on the left (with live
/// used-vs-max, access mode, storage class, status) and a PVC treemap on the
/// right. Fills in progressively as data arrives.
struct KubernetesResultView: View {
    @Bindable var controller: KubernetesController
    let app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.separator)

            if controller.pvcs.isEmpty {
                VStack(spacing: 10) {
                    if controller.state == .loading {
                        ProgressView()
                        Text("Querying \(controller.contextName)…")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    } else {
                        // .ready with no PVCs: an empty/inaccessible context, not a
                        // hang. (A dead context now times out via ProcessRunner.)
                        Image(systemName: "tray")
                            .font(.system(size: 28)).foregroundStyle(theme.textSecondary)
                        Text("No PVCs in “\(controller.contextName)”")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textPrimary)
                        Text("The context has no PersistentVolumeClaims, or access to them was denied.")
                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.windowBackground)
            } else {
                summaryStrip
                Divider().overlay(theme.separator)
                HSplitView {
                    K8sOutlineView(controller: controller)
                        .frame(minWidth: 340, idealWidth: 440, maxWidth: 680)
                    K8sTreemap(controller: controller)
                        .frame(minWidth: 360)
                }
            }
        }
        .background(theme.windowBackground)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: app.showSplash) { Label("Home", systemImage: "chevron.backward") }
                .buttonStyle(.plain).foregroundStyle(theme.textPrimary)
            Button(action: controller.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(theme.textPrimary)
            Divider().frame(height: 22).overlay(theme.separator)
            Text(controller.contextName)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)

            if controller.state == .loading {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                if controller.nodesTotal > 0 {
                    Text("usage \(controller.nodesScanned)/\(controller.nodesTotal) nodes")
                        .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
            }

            Spacer()

            Picker("", selection: Binding(get: { controller.metric }, set: { controller.metric = $0 })) {
                ForEach(KubernetesController.Metric.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .disabled(!controller.usageAvailable)
            .help(controller.usageAvailable ? "Size by provisioned capacity or live usage" : "Live usage unavailable")

            Button { isDark.toggle() } label: { Image(systemName: isDark ? "sun.max.fill" : "moon.fill") }
                .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(theme.panelBackground)
    }

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            statCard("Provisioned", value: Format.bytes(controller.totalCapacity), sub: "\(controller.pvcs.count) PVCs")
            statCard("Used", value: controller.usageAvailable ? Format.bytes(controller.totalUsed) : "—",
                     sub: controller.usageAvailable && controller.totalCapacity > 0
                        ? "\(Int(Double(controller.totalUsed) / Double(controller.totalCapacity) * 100))% of provisioned"
                        : "live stats off")
            statCard("Namespaces", value: "\(controller.namespaceCount)",
                     sub: "\(controller.boundCount) bound · \(controller.pendingCount) pending")
            if !controller.reclaimablePVs.isEmpty {
                statCard("Reclaimable PVs", value: Format.bytes(controller.reclaimableBytes),
                         sub: "\(controller.reclaimablePVs.count) released/available", warn: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.panelBackground)
    }

    private func statCard(_ title: String, value: String, sub: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color(hex: 0xE0915A) : theme.textPrimary)
            Text(sub).font(.system(size: 10)).foregroundStyle(theme.textSecondary.opacity(0.8))
        }
        .frame(width: 160, alignment: .leading).padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator))
    }
}

// MARK: Left outline (namespace → pod → PVC)

private struct K8sOutlineView: View {
    @Bindable var controller: KubernetesController
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(controller.rows()) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(row.id)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(theme.panelBackground)
            .onChange(of: controller.selection) { _, sel in
                guard let sel else { return }
                // Async so any reveal-driven expansion is applied before we scroll.
                DispatchQueue.main.async {
                    guard let rid = controller.scrollTarget(for: sel) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(rid, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: KubernetesController.OutlineRow) -> some View {
        let barColor = row.colorKey.isEmpty ? theme.accent : theme.color(forHashable: row.colorKey)
        switch row.kind {
        case let .root(name):
            TreeHeaderRow(row: row, isSelected: controller.selection == nil, swatch: nil, icon: "sailboat.fill",
                          name: name, barColor: barColor, bold: true,
                          onToggle: { controller.toggleRoot() }, onSelect: { controller.selection = nil })
        case let .namespace(name):
            TreeHeaderRow(row: row, isSelected: controller.selection == .namespace(name),
                          swatch: theme.color(forHashable: name), icon: nil, name: name, barColor: barColor, bold: true,
                          onToggle: { controller.toggleNamespace(name) }, onSelect: { controller.selection = .namespace(name) })
        case let .pod(key, name):
            TreeHeaderRow(row: row, isSelected: controller.selection == .pod(key), swatch: nil,
                          icon: name == "(unattached)" ? "questionmark.circle" : "cube.fill", name: name, barColor: barColor, bold: false,
                          onToggle: { controller.togglePod(key) }, onSelect: { controller.selection = .pod(key) })
        case let .pvc(pvc):
            PVCRow(pvc: pvc, row: row, barColor: barColor, isSelected: controller.selection == .pvc(pvc.id)) {
                controller.selection = .pvc(pvc.id)
            }
        }
    }
}

/// Footprint bar (size relative to siblings) + consumption pie + used/capacity.
private struct RowMetrics: View {
    let sizeFraction: Double
    let barColor: Color
    let usageFraction: Double?
    let used: Int64
    let capacity: Int64
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(theme.barTrack)
                Capsule().fill(barColor).frame(width: max(2, 90 * min(1, sizeFraction)))
            }
            .frame(width: 90, height: 6)

            if let usageFraction {
                PieGauge(fraction: usageFraction).frame(width: 13, height: 13)
            } else {
                Color.clear.frame(width: 13, height: 13)
            }

            Text("\(Format.bytes(used)) / \(Format.bytes(capacity))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: 126, alignment: .trailing)
        }
    }
}

/// A little consumption gauge: filled proportion, green → flashy orange (70%) →
/// scarlet (85%).
private struct PieGauge: View {
    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(ellipseIn: rect), with: .color(theme.barTrack))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * min(1, max(0, fraction))), clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(color))
        }
    }

    private var color: Color {
        switch fraction {
        case ..<0.7: return Color(hex: 0x3FB950)   // green
        case ..<0.85: return Color(hex: 0xFF8A00)  // flashy orange
        default: return Color(hex: 0xFF2400)       // scarlet
        }
    }
}

private struct TreeHeaderRow: View {
    let row: KubernetesController.OutlineRow
    let isSelected: Bool
    let swatch: Color?
    let icon: String?
    let name: String
    let barColor: Color
    let bold: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary).frame(width: 12)
                .contentShape(Rectangle()).onTapGesture(perform: onToggle)
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9) }
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(theme.textSecondary).frame(width: 14) }
            Text(name).font(.system(size: 12, weight: bold ? .semibold : .regular))
                .foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
            Text("\(row.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.textSecondary.opacity(0.7))
            Spacer(minLength: 8)
            RowMetrics(sizeFraction: row.sizeFraction, barColor: barColor, usageFraction: row.usageFraction,
                       used: row.used, capacity: row.capacity)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8).padding(.trailing, 10).padding(.vertical, 4)
        .background(isSelected ? theme.rowSelected : (hovering ? theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

private struct PVCRow: View {
    let pvc: PVCInfo
    let row: KubernetesController.OutlineRow
    let barColor: Color
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(pvc.name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(pvc.storageClass).font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 6)
                badge(pvc.accessShort, color: theme.accent)
                if pvc.phase != "Bound" { badge(pvc.phase, color: Color(hex: 0xE0915A)) }
            }
            HStack {
                Spacer(minLength: 0)
                RowMetrics(sizeFraction: row.sizeFraction, barColor: barColor, usageFraction: pvc.usageFraction,
                           used: pvc.used ?? 0, capacity: pvc.capacity)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8).padding(.trailing, 10).padding(.vertical, 5)
        .background(isSelected ? theme.rowSelected : (hovering ? theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { copy(pvc.id) } label: { Label("Copy namespace/name", systemImage: "doc.on.doc") }
            if let pv = pvc.volumeName { Button { copy(pv) } label: { Label("Copy PV name", systemImage: "doc.on.doc") } }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(color.opacity(0.16)))
    }
    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

// MARK: Treemap (namespace → PVC)

private struct K8sTreemap: View {
    @Bindable var controller: KubernetesController
    @Environment(\.theme) private var theme
    @State private var hovered: PVCInfo?

    private struct Tile { let rect: CGRect; let pvc: PVCInfo; let namespace: String }

    var body: some View {
        GeometryReader { geo in
            let tiles = computeTiles(size: geo.size)
            ZStack(alignment: .topLeading) {
                theme.treemapBackground
                Canvas { ctx, _ in
                    for tile in tiles {
                        let path = Path(tile.rect)
                        ctx.fill(path, with: .color(color(for: tile)))
                        if tile.rect.width > 3 && tile.rect.height > 3 {
                            ctx.stroke(path, with: .color(theme.treemapBorder), lineWidth: 0.6)
                        }
                    }
                }
                .drawingGroup()

                let highlighted = controller.highlightedPVCIDs()
                if !highlighted.isEmpty {
                    let hi = tiles.filter { highlighted.contains($0.pvc.id) }
                    // Dim everything except the selected region (a namespace, a pod's
                    // PVCs, or a single PVC).
                    Canvas { ctx, size in
                        var p = Path(CGRect(origin: .zero, size: size))
                        for tile in hi { p.addRect(tile.rect) }
                        ctx.fill(p, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                    }
                    if let box = boundingBox(hi) {
                        Rectangle().strokeBorder(Color.black.opacity(0.85), lineWidth: 4)
                            .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                        Rectangle().strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let pt) = phase { hovered = tiles.last(where: { $0.rect.contains(pt) })?.pvc } else { hovered = nil }
            }
            .onTapGesture { pt in
                if let tile = tiles.last(where: { $0.rect.contains(pt) }) { controller.revealPVC(tile.pvc.id) }
            }
            .overlay(alignment: .bottomLeading) {
                if let hovered { hoverLabel(hovered).padding(8).allowsHitTesting(false) }
            }
        }
    }

    private func computeTiles(size: CGSize) -> [Tile] {
        let groups = controller.treemapGroups()
        guard !groups.isEmpty, size.width > 1, size.height > 1 else { return [] }
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let nsRects = TreemapLayout.squarify(groups.map { Double($0.total) }, into: rect)
        var tiles: [Tile] = []
        for (i, group) in groups.enumerated() {
            let rects = TreemapLayout.squarify(group.pvcs.map { Double(controller.size($0)) }, into: nsRects[i])
            for (j, pvc) in group.pvcs.enumerated() where rects[j].width > 0 && rects[j].height > 0 {
                tiles.append(Tile(rect: rects[j], pvc: pvc, namespace: group.name))
            }
        }
        return tiles
    }

    private func boundingBox(_ tiles: [Tile]) -> CGRect? {
        guard let first = tiles.first else { return nil }
        var box = first.rect
        for tile in tiles.dropFirst() { box = box.union(tile.rect) }
        return box
    }

    private func color(for tile: Tile) -> Color {
        let base = theme.color(forHashable: tile.namespace)
        guard let frac = tile.pvc.usageFraction else { return base.opacity(0.55) }
        return base.opacity(0.45 + 0.5 * frac)
    }

    private func hoverLabel(_ pvc: PVCInfo) -> some View {
        let usage = pvc.used.map { "\(Format.bytes($0)) / \(Format.bytes(pvc.capacity))" } ?? Format.bytes(pvc.capacity)
        return HStack(spacing: 6) {
            Image(systemName: "externaldrive.fill").foregroundStyle(theme.accent)
            Text("\(pvc.namespace)/\(pvc.name)").foregroundStyle(theme.textPrimary).lineLimit(1)
            Text(usage).foregroundStyle(theme.textSecondary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.panelBackground.opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.separator)))
    }
}
