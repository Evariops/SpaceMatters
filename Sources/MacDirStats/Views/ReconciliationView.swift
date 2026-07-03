import SwiftUI

/// Toolbar affordance (whole-volume scans only): a small button that pops over a
/// breakdown reconciling the scan against the OS's "used" figure — the honest
/// answer to "why doesn't this match Finder?" (J9).
struct ReconciliationButton: View {
    let controller: ScanController
    @Environment(\.theme) private var theme
    @State private var showing = false
    @State private var recon: Reconciliation?
    @State private var loading = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary)
        .help("Why doesn't this match Finder?")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ReconciliationPanel(recon: recon, loading: loading)
                .environment(\.theme, theme)
                .task(id: showing) { if showing { await load() } }
        }
    }

    private func load() async {
        guard let vol = controller.lastVolumes.first else { return }
        loading = true
        defer { loading = false }
        let url = vol.url
        let scanned = controller.totalPhysical
        let skipped = controller.errorCount
        recon = await Task.detached(priority: .utility) {
            Reconciliation.compute(volumeURL: url, scannedPhysical: scanned, skippedPaths: skipped)
        }.value
    }
}

private struct ReconciliationPanel: View {
    let recon: Reconciliation?
    let loading: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage reconciliation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            if let r = recon {
                Text("The volume reports **\(Format.bytes(r.volumeUsed))** used. Here's where it goes:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    row("Scanned", r.scanned, of: r.volumeUsed, color: theme.accent)
                    row("Trash", r.trash, of: r.volumeUsed, color: theme.color(forHashable: ".trash"))
                    row(r.snapshotCount > 0 ? "Purgeable (\(r.snapshotCount) snapshot\(r.snapshotCount == 1 ? "" : "s"))" : "Purgeable",
                        r.purgeable, of: r.volumeUsed, color: theme.color(forHashable: ".purge"))
                    row("Unaccounted", r.unaccounted, of: r.volumeUsed, color: theme.textSecondary)
                }

                if r.scanExceedsUsed {
                    note("The scan is larger than the reported used space — this is attribution mode counting hardlinks and APFS clones more than once. Switch to Exact to dedup hardlinks.")
                }
                if r.skippedPaths > 0 {
                    note("\(Format.count(r.skippedPaths)) path\(r.skippedPaths == 1 ? "" : "s") couldn't be read (permissions) and aren't included in the scan.")
                }
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring Trash and snapshots…").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
            } else {
                Text("Reconciliation is only available for whole-volume scans.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func row(_ label: String, _ value: Int64, of total: Int64, color: Color) -> some View {
        let fraction = total > 0 ? min(1, Double(value) / Double(total)) : 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule().fill(color).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
            Text(Format.bytes(value))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
