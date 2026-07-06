import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var app: AppModel
    @AppStorage("isDark") private var isDark = true
    @AppStorage("fdaBannerDismissed") private var fdaDismissed = false

    private var theme: Theme { Theme(isDark: isDark) }

    var body: some View {
        VStack(spacing: 0) {
            if !app.filesystem.hasFullDiskAccess && !fdaDismissed {
                FDABanner(onDismiss: { fdaDismissed = true })
                Divider().overlay(theme.separator)
            }

            switch app.route {
            case .splash:
                EmptyState(app: app, isDark: $isDark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.windowBackground)
            case .filesystem:
                FilesystemResultView(controller: app.filesystem, app: app, isDark: $isDark)
            case .containers:
                ContainerResultView(controller: app.containers, app: app, isDark: $isDark)
            case .kubernetes:
                KubernetesResultView(controller: app.kubernetes, app: app, isDark: $isDark)
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(isDark ? .dark : .light)
        .background(theme.windowBackground)
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(windowTitle)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.filesystem.refreshFullDiskAccess()
        }
        .task { app.handleLaunchArgumentsOnce() }
    }

    private var windowTitle: String {
        switch app.route {
        case .splash: return "SpaceMatters"
        case .filesystem: return app.filesystem.rootName.isEmpty ? "SpaceMatters" : app.filesystem.rootName
        case .containers: return app.containers.engineName.isEmpty ? "Containers" : app.containers.engineName
        case .kubernetes: return app.kubernetes.contextName.isEmpty ? "Kubernetes" : app.kubernetes.contextName
        }
    }
}

private struct FilesystemResultView: View {
    @Bindable var controller: ScanController
    let app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(controller: controller, app: app, isDark: $isDark)
            Divider().overlay(theme.separator)

            if controller.phase == .failed, let msg = controller.failureMessage {
                ErrorBanner(message: msg)
                Divider().overlay(theme.separator)
            }

            if controller.diskChanged {
                DiskChangedBanner(controller: controller)
                Divider().overlay(theme.separator)
            }

            HSplitView {
                VSplitView {
                    DirectoryListView(controller: controller)
                        .frame(minHeight: 160)
                    TypeBreakdownView(controller: controller)
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 560)

                TreemapPane(controller: controller)
                    .frame(minWidth: 360)
            }
        }
    }
}

/// Discreet failure banner shown when a scan couldn't complete (VM command
/// missing, remote find failed, …) — so a broken scan never looks like an empty
/// one.
private struct ErrorBanner: View {
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xD29922))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: 0xD29922).opacity(0.12))
    }
}

/// Live-dashboard banner (SPEC-04): FSEvents saw the disk change under the
/// current result. Refresh re-scans only the touched subtrees (`invalidate`).
private struct DiskChangedBanner: View {
    let controller: ScanController
    @Environment(\.theme) private var theme
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(theme.accent)
            Text("The disk changed since this scan.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            Button {
                refreshing = true
                Task { await controller.refreshDirty(); refreshing = false }
            } label: {
                HStack(spacing: 5) {
                    if refreshing { ProgressView().controlSize(.mini) }
                    Text(refreshing ? "Refreshing…" : "Refresh")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(refreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.accent.opacity(0.10))
    }
}

private struct FDABanner: View {
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Grant Full Disk Access once")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Scan Photos, Mail, Music and other protected folders without repeated permission prompts. After enabling it in Settings, choose Relaunch.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 12)
            Button("Open Settings", action: FullDiskAccess.openSettings)
                .buttonStyle(PrimaryButtonStyle())
            Button("Relaunch", action: FullDiskAccess.relaunch)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.accent.opacity(0.10))
    }
}

private struct TreemapPane: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb(controller: controller)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.panelBackground)

            Divider().overlay(theme.separator)
            TreemapView(controller: controller)
        }
        .background(theme.treemapBackground)
    }
}

/// Clickable path from the scan root to the current zoom. The root stays pinned
/// on the left; deeper segments scroll. Clicking any segment zooms there and
/// updates the selection in both the tree and the treemap.
private struct Breadcrumb: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    var body: some View {
        let path = controller.zoomPath
        HStack(spacing: 4) {
            Button(action: controller.zoomOut) {
                Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.canZoomOut ? theme.accent : theme.textSecondary.opacity(0.4))
            .disabled(!controller.canZoomOut)
            .help("Zoom out (⌘↑)")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .accessibilityLabel("Zoom out")

            if let root = path.first {
                segment(root, isCurrent: path.count == 1)
            }
            if path.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(path.dropFirst().enumerated()), id: \.element.id) { idx, node in
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textSecondary.opacity(0.6))
                                segment(node, isCurrent: idx == path.count - 2)
                                    .id(node.id)
                            }
                        }
                    }
                    .onChange(of: controller.zoomRoot) { _, zoom in
                        if let zoom { withAnimation { proxy.scrollTo(zoom.id, anchor: .trailing) } }
                    }
                }
            }

            Spacer(minLength: 8)

            if let sel = controller.selection {
                Text(Format.bytes(sel.size(controller.metric)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func segment(_ node: FSNode, isCurrent: Bool) -> some View {
        Button { controller.navigate(to: node) } label: {
            Text(node.name)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? theme.textPrimary : theme.accent)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(node.name)
        .accessibilityLabel(node.name)
        .accessibilityValue(Format.bytes(node.size(controller.metric)))
        .accessibilityHint(isCurrent ? "Current folder" : "Zoom to this folder")
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }
}

private struct ToolbarBar: View {
    @Bindable var controller: ScanController
    let app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            // Back to the disk-selection splash.
            Button(action: app.showSplash) {
                Label("Home", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textPrimary)

            if controller.isScanning {
                Button(action: controller.cancel) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                ProgressView().controlSize(.small)
            } else if controller.root != nil {
                Button(action: controller.rescan) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .keyboardShortcut("r", modifiers: .command)
            }

            if controller.root != nil {
                Divider().frame(height: 22).overlay(theme.separator)
                StatsStrip(controller: controller)
            }

            Spacer()

            if controller.root != nil {
                searchField
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0).frame(width: 0)
            }

            if controller.root != nil {
                Picker("", selection: Binding(get: { controller.metric }, set: { controller.metric = $0 })) {
                    ForEach(SizeMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Size metric")
                .help(
                    """
                    How sizes are measured:

                    • On disk — the space files actually take up on your disk (allocated blocks). This is what matters for freeing up space, and matches `du`.

                    • Logical — the size of the files' content.

                    They differ because the disk stores files in fixed-size blocks (~4 KB): a tiny file still uses a whole block, so "On disk" is usually larger. macOS-compressed files are the exception (smaller on disk than their content).
                    """
                )

                // Counting mode — host scans only (VM scans are always attribution).
                if controller.isHostScan {
                    Picker("", selection: Binding(get: { controller.countingMode }, set: { controller.countingMode = $0 })) {
                        ForEach(CountingMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(controller.isScanning)
                    .accessibilityLabel("Counting mode")
                    .help(
                        """
                        How shared storage is counted (re-scans when changed):

                        • Attribution — every hardlink is charged the full size (“who is responsible for this space”). Matches `du -l`.

                        • Exact — hardlinked files are counted once, so the total matches what the disk actually holds (`du` / `df`).

                        APFS clones (copy-on-write copies) are still counted in full in both modes — they can make the total larger than `df` reports.
                        """
                    )
                }
            }

            // Reconciliation ("why doesn't this match Finder?") — volume scans only.
            if controller.lastVolumes.count == 1 && !controller.isScanning {
                ReconciliationButton(controller: controller)
            }

            Button { isDark.toggle() } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Toggle theme")
            .accessibilityLabel(isDark ? "Switch to light theme" : "Switch to dark theme")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.panelBackground)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            TextField("Search folders…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit { controller.setSearch(searchText) }
                .onChange(of: searchText) { _, query in debounceSearch(query) }
            if !searchText.isEmpty {
                Button { searchText = ""; controller.setSearch("") } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? theme.accent : theme.separator))
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            controller.setSearch(query)
        }
    }
}

private struct StatsStrip: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Stat(value: Format.bytes(controller.totalSize), label: "total", theme: theme)
            Stat(value: Format.count(controller.fileCount), label: "files", theme: theme)
            Stat(value: Format.count(controller.dirCount), label: "folders", theme: theme)
            if controller.isScanning {
                Stat(value: Format.rate(controller.filesPerSecond), label: "scan", theme: theme, accent: true)
            } else if controller.phase == .finished {
                Stat(value: String(format: "%.1fs", controller.elapsed), label: "done in", theme: theme)
                if let date = controller.scanDate {
                    // J5.2: how stale the result is, refreshed every 30 s.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Stat(value: Self.ago(date), label: "scanned", theme: theme)
                    }
                }
            }
            if controller.errorCount > 0 {
                Stat(value: Format.count(controller.errorCount), label: "skipped", theme: theme)
            }
        }
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

private struct Stat: View {
    let value: String
    let label: String
    let theme: Theme
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent ? theme.accent : theme.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct EmptyState: View {
    @Bindable var app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    @State private var volumes: [Volume] = []
    @State private var vms: [VMMachine] = []
    @State private var engines: [ContainerEngine] = []
    @State private var kubeContexts: [K8sContext] = []
    @State private var showingRemote = false

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.accent.opacity(0.9))
                    Text("SpaceMatters")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Choose what to analyze")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.top, 40)

                if volumes.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(volumes) { volume in
                            VolumeCard(volume: volume, theme: theme) { app.scan(volumes: [volume]) }
                        }
                    }
                    .frame(maxWidth: 780)
                }

                if !vms.isEmpty {
                    section("Virtual machines") {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(vms) { vm in
                                VMCard(machine: vm, scope: .full, theme: theme) { app.scanVMFilesystem(vm) }
                                VMCard(machine: vm, scope: .containers, theme: theme) { app.scanVMContainers(vm) }
                            }
                        }
                    }
                }

                if !engines.isEmpty {
                    section("Containers") {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(engines) { engine in
                                ContainerEngineCard(engine: engine, theme: theme) { app.analyzeContainers(engine) }
                            }
                        }
                    }
                }

                if !kubeContexts.isEmpty {
                    section("Kubernetes") {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(kubeContexts) { ctx in
                                KubeContextCard(context: ctx, theme: theme) { app.analyzeKubernetes(context: ctx.name) }
                            }
                        }
                    }
                }

                section("Remote") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        RemoteCard(theme: theme) { showingRemote = true }
                    }
                }

                Color.clear.frame(height: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
        .sheet(isPresented: $showingRemote) {
            RemoteScanSheet { target in
                showingRemote = false
                app.scanRemote(target)
            } cancel: {
                showingRemote = false
            }
            .environment(\.theme, theme)
        }
        .overlay(alignment: .topTrailing) {
            Button { isDark.toggle() } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .padding(18)
            .help("Toggle theme")
        }
        .onAppear(perform: reload)
        .task {
            // Detection shells out to podman/colima — keep it off the main thread.
            vms = await Task.detached(priority: .userInitiated) { VMProbe.detect() }.value
            engines = await Task.detached(priority: .userInitiated) { ContainerProbe.detect() }.value
            kubeContexts = await Task.detached(priority: .userInitiated) { K8sProbe.contexts() }.value
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: 780)
    }

    private func reload() {
        volumes = Volume.mounted()
    }
}

private struct VolumeCard: View {
    let volume: Volume
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(nsImage: volume.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(volume.kindLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .textCase(.uppercase)
                }
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule()
                        .fill(usageColor)
                        .frame(width: max(2, geo.size.width * volume.usedFraction))
                }
            }
            .frame(height: 6)

            HStack {
                // Percentage is a redundant, colour-blind-safe channel for the bar (J10.2).
                Text("\(percent)% · \(Format.bytes(volume.used)) used · \(Format.bytes(volume.available)) free")
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Label("Analyze", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? theme.accent : theme.textSecondary)
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name), \(volume.kindLabel)")
        .accessibilityValue("\(percent)% full, \(Format.bytes(volume.used)) used of \(Format.bytes(volume.total))")
        .accessibilityHint("Analyze disk usage")
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hovering ? theme.accent : theme.separator, lineWidth: hovering ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }

    private var usageColor: Color { Theme.usageColor(volume.usedFraction) }
    private var percent: Int { Int((volume.usedFraction * 100).rounded()) }
}

/// Splash card that opens the SSH connection form (SPEC-06).
private struct RemoteCard: View {
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 22))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connect to a server…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("SSH · read-only")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .textCase(.uppercase)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? theme.accent : theme.textSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(hovering ? theme.accent : theme.separator, lineWidth: hovering ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// SSH connection form: gathers an `SSHTarget` and launches a read-only remote
/// scan. `BatchMode` means key-based auth only (documented in the note).
private struct RemoteScanSheet: View {
    let scan: (SSHTarget) -> Void
    let cancel: () -> Void
    @Environment(\.theme) private var theme

    @State private var host = ""
    @State private var user = NSUserName()
    @State private var path = "/"
    @State private var port = ""
    @State private var identity = ""
    @State private var useSudo = false

    private var canScan: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !path.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan a remote server")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                field("Host", "example.com or 10.0.0.4", text: $host)
                field("User", NSUserName(), text: $user)
                field("Path", "/", text: $path)
                field("Port", "22 (optional)", text: $port)
                field("Identity file", "~/.ssh/id_ed25519 (optional)", text: $identity)
                GridRow {
                    Text("").gridCellColumns(1)
                    Toggle("Use sudo (for system paths)", isOn: $useSudo)
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                }
            }

            Text("Uses key-based auth (BatchMode) and GNU `find`. The remote tree is read-only — no Trash or Reveal in Finder.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Scan") {
                    scan(SSHTarget(
                        user: user.trimmingCharacters(in: .whitespaces),
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: Int(port.trimmingCharacters(in: .whitespaces)),
                        path: path.isEmpty ? "/" : path,
                        identityFile: identity.isEmpty ? nil : (identity as NSString).expandingTildeInPath,
                        useSudo: useSudo))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canScan)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.windowBackground)
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .gridColumnAlignment(.trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}

private struct VMCard: View {
    let machine: VMMachine
    let scope: VMScope
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    private var enabled: Bool { machine.running }
    private var title: String { "\(machine.runtime.rawValue) — \(scope == .full ? "Full VM" : "Containers")" }
    private var subtitle: String { scope == .full ? machine.name : "Image & container storage" }
    private var icon: String { scope == .full ? "cube.transparent.fill" : "square.stack.3d.up.fill" }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(enabled ? theme.accent : theme.textSecondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if !enabled {
                    Text("Stopped")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(theme.barTrack))
                }
            }

            HStack {
                Text("\(Format.bytes(machine.diskBytes)) VM disk")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if enabled {
                    Label("Analyze", systemImage: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? theme.accent : theme.textSecondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.panelBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(enabled && hovering ? theme.accent : theme.separator, lineWidth: enabled && hovering ? 2 : 1)
        )
        .opacity(enabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { if enabled { hovering = $0 } }
        .onTapGesture { if enabled { action() } }
        .help(enabled ? "Analyze this VM" : "\(machine.runtime.rawValue) is stopped — start it to analyze")
    }
}

private struct ContainerEngineCard: View {
    let engine: ContainerEngine
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Images, layers & volumes")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            HStack {
                Text("Container engine")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Label("Analyze", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? theme.accent : theme.textSecondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.panelBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hovering ? theme.accent : theme.separator, lineWidth: hovering ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Analyze \(engine.displayName) images & containers")
    }
}

private struct KubeContextCard: View {
    let context: K8sContext
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 20)).foregroundStyle(theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.name)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("PVCs · usage · storage")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if context.isCurrent {
                    Text("current").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent.opacity(0.16)))
                }
            }
            HStack {
                Text("Kube context").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                Spacer()
                Label("Analyze", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? theme.accent : theme.textSecondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(hovering ? theme.accent : theme.separator, lineWidth: hovering ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Analyze PVC storage on \(context.name)")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.accent.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}
