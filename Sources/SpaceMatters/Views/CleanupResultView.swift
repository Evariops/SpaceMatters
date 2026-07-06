import SwiftUI

/// Low-Hanging Fruits mode: the known-safe cleanup targets found on this Mac,
/// sized live, grouped by category. Nothing is pre-selected; cleaning asks for
/// confirmation and reports measured (not assumed) freed bytes.
struct CleanupResultView: View {
    @Bindable var controller: CleanupController
    let app: AppModel
    @Binding var isDark: Bool
    @Environment(\.theme) private var theme

    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.separator)
            summaryStrip
            Divider().overlay(theme.separator)

            if controller.rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32)).foregroundStyle(theme.textSecondary)
                    Text("Nothing to clean — no known caches found.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            Divider().overlay(theme.separator)
            footer
        }
        .background(theme.windowBackground)
        .alert("Clean selected items?", isPresented: $confirmClean) {
            Button("Clean", role: .destructive) {
                Task { await controller.cleanSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let names = controller.selectedRows.map(\.item.name).joined(separator: ", ")
        return "\(names) — about \(Format.bytes(controller.totalSelected)) will be reclaimed. "
            + "Caches are re-downloaded or rebuilt on demand; emptying the Trash is permanent."
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
            .disabled(controller.state == .cleaning)

            Divider().frame(height: 22).overlay(theme.separator)
            Text("Low-Hanging Fruits")
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
            summaryCard("Reclaimable found", value: Format.bytes(controller.totalFound),
                        subtitle: controller.state == .sizing ? "still measuring…" : "\(controller.rows.count) locations")
            summaryCard("Selected", value: Format.bytes(controller.totalSelected),
                        subtitle: "\(controller.selectedRows.count) of \(controller.rows.count)")
            if controller.lastFreed > 0 {
                summaryCard("Freed", value: Format.bytes(controller.lastFreed),
                            subtitle: controller.lastFailures > 0
                                ? "\(controller.lastFailures) items couldn't be removed"
                                : "measured after cleaning",
                            accent: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.panelBackground)
    }

    private func summaryCard(_ title: String, value: String, subtitle: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent ? theme.accent : theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 10)).foregroundStyle(theme.textSecondary.opacity(0.8))
        }
        .frame(width: 190, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator))
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(controller.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .textCase(.uppercase)
                        VStack(spacing: 1) {
                            ForEach(controller.rows(in: category)) { row in
                                CleanupRowView(row: row, theme: theme,
                                               disabled: controller.state == .cleaning) {
                                    controller.toggle(row.id)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.panelBackground))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.separator))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if controller.state == .cleaning {
                ProgressView().controlSize(.small)
                Text("Cleaning…")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else {
                Text("Everything here is safe to remove: caches are re-downloaded or rebuilt when needed.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button { confirmClean = true } label: {
                Text(controller.totalSelected > 0
                     ? "Clean \(Format.bytes(controller.totalSelected))"
                     : "Clean")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(controller.selectedRows.isEmpty
                                               ? Color.gray.opacity(0.4) : Color(hex: 0xE0915A)))
            }
            .buttonStyle(.plain)
            .disabled(controller.selectedRows.isEmpty || controller.state != .ready)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.panelBackground)
    }
}

private struct CleanupRowView: View {
    let row: CleanupController.Row
    let theme: Theme
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { row.selected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled || !row.size.isSelectable)

            Image(systemName: row.item.icon)
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(row.item.note)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(row.item.paths.map(abbreviate).joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary.opacity(0.7))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)

            sizeLabel
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.item.name), \(sizeAccessibility)")
    }

    @ViewBuilder
    private var sizeLabel: some View {
        switch row.size {
        case .pending:
            ProgressView().controlSize(.mini)
        case .sized(let bytes):
            Text(Format.bytes(bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
        case .denied:
            Button(action: FullDiskAccess.openSettings) {
                Label("Needs access", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE0915A))
            }
            .buttonStyle(.plain)
            .help("Grant Full Disk Access to measure and clean this location")
        }
    }

    private var sizeAccessibility: String {
        switch row.size {
        case .pending: return "measuring"
        case .sized(let bytes): return Format.bytes(bytes)
        case .denied: return "needs Full Disk Access"
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension CleanupController.SizeState {
    /// Only measured rows can be selected — a denied or still-sizing row has no
    /// trustworthy size to confirm against.
    var isSelectable: Bool {
        if case .sized = self { return true }
        return false
    }
}
