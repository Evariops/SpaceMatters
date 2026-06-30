import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var controller: ScanController
    @AppStorage("isDark") private var isDark = true
    @AppStorage("fdaBannerDismissed") private var fdaDismissed = false

    private var theme: Theme { Theme(isDark: isDark) }

    var body: some View {
        VStack(spacing: 0) {
            if !controller.hasFullDiskAccess && !fdaDismissed {
                FDABanner(onDismiss: { fdaDismissed = true })
                Divider().overlay(theme.separator)
            }

            if controller.root == nil {
                // Splash: no toolbar; theme toggle floats in the top-right corner.
                EmptyState(controller: controller, isDark: $isDark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.windowBackground)
            } else {
                ToolbarBar(controller: controller, isDark: $isDark)
                Divider().overlay(theme.separator)

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
        .environment(\.theme, theme)
        .preferredColorScheme(isDark ? .dark : .light)
        .background(theme.windowBackground)
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check after the user returns from System Settings.
            controller.refreshFullDiskAccess()
        }
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
            // Breadcrumb / zoom controls.
            HStack(spacing: 8) {
                Button { controller.zoomOut() } label: {
                    Image(systemName: "arrow.up.left")
                }
                .buttonStyle(.plain)
                .disabled(controller.zoomRoot?.parent == nil)
                .foregroundStyle(controller.zoomRoot?.parent == nil ? theme.textSecondary.opacity(0.4) : theme.textPrimary)

                Text(controller.zoomRoot?.name ?? controller.rootName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let sel = controller.selection {
                    Text(Format.bytes(sel.size(controller.metric)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.panelBackground)

            Divider().overlay(theme.separator)
            TreemapView(controller: controller)
        }
        .background(theme.treemapBackground)
    }
}

private struct ToolbarBar: View {
    @Bindable var controller: ScanController
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            // Back to the disk-selection splash.
            Button(action: controller.goHome) {
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
            }

            if controller.root != nil {
                Divider().frame(height: 22).overlay(theme.separator)
                StatsStrip(controller: controller)
            }

            Spacer()

            if controller.root != nil {
                Picker("", selection: Binding(get: { controller.metric }, set: { controller.metric = $0 })) {
                    ForEach(SizeMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(
                    """
                    How sizes are measured:

                    • On disk — the space files actually take up on your disk (allocated blocks). This is what matters for freeing up space, and matches `du`.

                    • Logical — the size of the files' content.

                    They differ because the disk stores files in fixed-size blocks (~4 KB): a tiny file still uses a whole block, so "On disk" is usually larger. macOS-compressed files are the exception (smaller on disk than their content).
                    """
                )
            }

            Button { isDark.toggle() } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Toggle theme")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.panelBackground)
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
            }
            if controller.errorCount > 0 {
                Stat(value: Format.count(controller.errorCount), label: "skipped", theme: theme)
            }
        }
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
    }
}

private struct EmptyState: View {
    @Bindable var controller: ScanController
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    @State private var volumes: [Volume] = []
    @State private var selected: Set<URL> = []

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.accent.opacity(0.9))
                    Text("MacDirStats")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Choose one or more disks to analyze")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.top, 40)

                if volumes.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(volumes) { volume in
                            VolumeCard(volume: volume, isSelected: selected.contains(volume.id), theme: theme)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { toggle(volume) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    controller.scan(volumes: [volume])
                                })
                        }
                    }
                    .frame(maxWidth: 780)
                }

                VStack(spacing: 10) {
                    Button(action: scanSelected) {
                        Label(scanLabel, systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selected.isEmpty)
                    .opacity(selected.isEmpty ? 0.5 : 1)

                    Button(action: controller.chooseFolderAndScan) {
                        Label("Choose a folder instead…", systemImage: "folder")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                }
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
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
    }

    private var scanLabel: String {
        selected.count > 1 ? "Analyze \(selected.count) disks" : "Analyze"
    }

    private func toggle(_ volume: Volume) {
        if selected.contains(volume.id) { selected.remove(volume.id) }
        else { selected.insert(volume.id) }
    }

    private func scanSelected() {
        let chosen = volumes.filter { selected.contains($0.id) }
        if !chosen.isEmpty { controller.scan(volumes: chosen) }
    }

    private func reload() {
        volumes = Volume.mounted()
        if selected.isEmpty, let preferred = volumes.first(where: { $0.isRoot }) ?? volumes.first {
            selected = [preferred.id]
        }
    }
}

private struct VolumeCard: View {
    let volume: Volume
    let isSelected: Bool
    let theme: Theme
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? theme.accent : theme.separator)
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
                Text("\(Format.bytes(volume.used)) used")
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(Format.bytes(volume.available)) free")
                    .foregroundStyle(theme.textSecondary)
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? theme.accent : (hovering ? theme.textSecondary.opacity(0.4) : theme.separator),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .onHover { hovering = $0 }
    }

    private var usageColor: Color {
        switch volume.usedFraction {
        case ..<0.7: return Color(hex: 0x3FB950)
        case ..<0.9: return Color(hex: 0xD29922)
        default: return Color(hex: 0xF85149)
        }
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
