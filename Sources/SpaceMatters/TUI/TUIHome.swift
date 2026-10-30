import Foundation

/// The home menu: everything worth analysing on this machine, which is what
/// the window's splash screen offers — disks, a folder of your choosing, the
/// safe cleanup pass, Podman/Colima machines, Kubernetes contexts and the
/// container engine.
///
/// Built from a [TUISources](x-source-tag://TUISources) value handed in each
/// frame, so the probes (which all shell out) stay off the drawing path.
struct TUIHome {

    struct Item {
        let id: String
        let label: String
        let detail: String
        /// Drives the usage bar — volumes only.
        var fraction: Double?
        let request: TUIRequest
    }

    struct Section {
        let title: String
        let items: [Item]
    }

    var sources = TUISources()
    /// Selection by id, not by index: the probes land one after another and
    /// rows appear underneath the cursor as they do.
    private var selectedID: String?
    private var scrollTop = 0
    private var listHeight = 10

    var title: String { "SpaceMatters" }

    func subtitle(width: Int) -> String {
        sources.loaded
            ? "pick something to analyse"
            : "looking for disks, machines and clusters…"
    }

    var hints: [String] { ["↑↓ move", "⏎ open", "/ scan a path", "r refresh", "? help", "q quit"] }

    // MARK: Content

    func sections() -> [Section] {
        var out: [Section] = []

        if !sources.volumes.isEmpty {
            out.append(Section(title: "Disks", items: sources.volumes.map { volume in
                Item(id: "vol:" + volume.url.path,
                     label: volume.name,
                     detail: "\(Format.bytes(volume.used)) used of \(Format.bytes(volume.total)) · \(volume.kindLabel)",
                     fraction: volume.usedFraction,
                     request: .start(.volume(volume)))
            }))
        }

        out.append(Section(title: "Start from", items: [
            Item(id: "home", label: "Home folder",
                 detail: NSHomeDirectory(), request: .start(.path(NSHomeDirectory()))),
            Item(id: "path", label: "Scan a path…",
                 detail: "type any folder", request: .promptPath),
            Item(id: "cleanup", label: "Low-Hanging Fruits",
                 detail: "caches and build output that are safe to empty", request: .start(.cleanup)),
        ]))

        if !sources.machines.isEmpty {
            var items: [Item] = []
            for machine in sources.machines {
                let state = machine.running ? "running" : "stopped — start it to scan"
                items.append(Item(id: "vm:" + machine.id, label: "\(machine.runtime.rawValue) \(machine.name)",
                                  detail: "\(state) · disk \(Format.bytes(machine.diskBytes))",
                                  request: .start(.vm(machine, .full))))
                if machine.running {
                    items.append(Item(id: "vmc:" + machine.id, label: "  ↳ container storage",
                                      detail: "images and layers only",
                                      request: .start(.vm(machine, .containers))))
                }
            }
            out.append(Section(title: "Virtual machines", items: items))
        }

        if !sources.engines.isEmpty {
            out.append(Section(title: "Containers", items: sources.engines.map { engine in
                Item(id: "engine:" + engine.id, label: engine.displayName,
                     detail: "images, volumes and containers by size",
                     request: .start(.containers(engineID: engine.id)))
            }))
        }

        if !sources.contexts.isEmpty {
            out.append(Section(title: "Kubernetes", items: sources.contexts.map { context in
                Item(id: "ctx:" + context.name, label: context.name,
                     detail: context.isCurrent ? "current context · PVCs by namespace" : "PVCs by namespace",
                     request: .start(.kubernetes(context.name)))
            }))
        }
        return out
    }

    private func items() -> [Item] { sections().flatMap(\.items) }

    private func selectedIndex(in items: [Item]) -> Int {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return 0 }
        return index
    }

    // MARK: Keys

    mutating func apply(_ key: TerminalKey) -> TUIRequest {
        let items = self.items()
        switch key {
        case .up, .char("k"): move(by: -1, in: items)
        case .down, .char("j"): move(by: 1, in: items)
        case .pageUp: move(by: -max(1, listHeight - 1), in: items)
        case .pageDown: move(by: max(1, listHeight - 1), in: items)
        case .home, .char("g"): move(by: -items.count, in: items)
        case .end, .char("G"): move(by: items.count, in: items)
        case .enter, .right, .char("l"):
            guard !items.isEmpty else { return .none }
            return items[selectedIndex(in: items)].request
        case .char("/"): return .promptPath
        case .char("r"): return .reloadSources
        case .char("m"): return .menu
        case .char("?"): return .help
        case .char("q"), .escape: return .quit
        default: break
        }
        return .none
    }

    private mutating func move(by delta: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        let index = min(max(selectedIndex(in: items) + delta, 0), items.count - 1)
        selectedID = items[index].id
    }

    // MARK: Rendering

    mutating func body(width: Int, height: Int) -> [String] {
        listHeight = max(0, height)
        let sections = self.sections()
        let items = sections.flatMap(\.items)
        let selected = items.isEmpty ? -1 : selectedIndex(in: items)

        // Flatten into drawable lines first, remembering which one is the
        // selection, so scrolling works over headings and rows alike.
        var lines: [(text: String, kind: Kind)] = []
        var flatIndex = 0
        for section in sections {
            if !lines.isEmpty { lines.append(("", .blank)) }
            lines.append((section.title.uppercased(), .heading))
            for item in section.items {
                lines.append((row(item, width: width), flatIndex == selected ? .selected : .item))
                flatIndex += 1
            }
        }
        if !sources.loaded {
            lines.append(("", .blank))
            lines.append(("Probing podman, kubectl and the mounted volumes…", .heading))
        }

        if let cursor = lines.firstIndex(where: { $0.kind == .selected }) {
            if cursor < scrollTop { scrollTop = cursor }
            if cursor >= scrollTop + listHeight { scrollTop = cursor - listHeight + 1 }
        }
        scrollTop = max(0, min(scrollTop, max(0, lines.count - listHeight)))

        var out: [String] = []
        for line in lines.dropFirst(scrollTop).prefix(listHeight) {
            switch line.kind {
            case .blank: out.append("")
            case .heading: out.append(Style.dim(TextCell.fit(line.text, width)))
            case .item: out.append(TextCell.fit(line.text, width))
            case .selected: out.append(Style.reverse(TextCell.padRight(TextCell.fit(line.text, width), width)))
            }
        }
        return out + Array(repeating: "", count: max(0, listHeight - out.count))
    }

    private enum Kind { case heading, item, selected, blank }

    private func row(_ item: Item, width: Int) -> String {
        let labelWidth = width >= 64 ? 26 : 20
        var text = "  " + TextCell.padRight(TextCell.fit(TextCell.sanitize(item.label), labelWidth), labelWidth)
        if let fraction = item.fraction, width >= 56 {
            text += "  " + TextCell.bar(fraction, width: 10)
        }
        return text + "  " + TextCell.sanitize(item.detail)
    }
}
