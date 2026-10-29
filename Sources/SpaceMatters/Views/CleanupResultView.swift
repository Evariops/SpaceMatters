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
    /// Tools found running for the selected targets when Clean was pressed —
    /// named in the confirmation so "my build failed" is never a surprise.
    @State private var activeWarnings: [String: Set<String>] = [:]

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
        .alert("A cleaner reported a problem", isPresented: Binding(
            get: { !controller.lastNativeIssues.isEmpty },
            set: { if !$0 { controller.dismissNativeIssues() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.lastNativeIssues.joined(separator: "\n"))
        }
    }

    private var confirmMessage: String {
        let names = controller.selectedRows.map(\.item.name).joined(separator: ", ")
        var message = "\(names) — about \(Format.bytes(controller.totalSelected)) will be reclaimed. "
            + "Caches are re-downloaded or rebuilt on demand."
        // Targets whose bytes do not come back are named one by one rather than
        // covered by a blanket sentence: the warning appears exactly when it
        // applies, so it is never diluted into background noise.
        let permanent = controller.selectedRows.filter { !$0.item.regenerable }
        for row in permanent {
            message += "\n\n⚠️ \(row.item.name) is not a cache: \(row.item.note)"
        }
        let tools = activeWarnings.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if !tools.isEmpty {
            message += "\n\n⚠️ Running right now: \(tools.sorted().joined(separator: ", ")) — "
                + "their in-progress builds or installs may fail."
        }
        return message
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
                        subtitle: foundSubtitle)
            summaryCard("Selected", value: Format.bytes(controller.totalSelected),
                        subtitle: "\(controller.selectedRows.count) of \(controller.locationCount)")
            // Shown as soon as a clean ran — a batch where everything failed
            // must not hide its failures behind the absent card.
            if controller.lastFreed > 0 || controller.lastFailures > 0 || controller.lastRefused > 0 {
                summaryCard("Freed", value: Format.bytes(controller.lastFreed),
                            subtitle: freedSubtitle, accent: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.panelBackground)
    }

    private var foundSubtitle: String {
        if controller.rows.contains(where: { $0.size == .searching }) { return "still searching…" }
        if controller.state == .sizing { return "still measuring…" }
        return "\(controller.locationCount) locations"
    }

    /// Failures (in use, locked) and fence refusals (a bug indicator) are
    /// different stories — never fold one into the other.
    private var freedSubtitle: String {
        var parts: [String] = []
        if controller.lastFailures > 0 { parts.append("\(controller.lastFailures) in use or locked") }
        if controller.lastRefused > 0 { parts.append("\(controller.lastRefused) skipped by the safety fence") }
        return parts.isEmpty ? "measured after cleaning" : parts.joined(separator: " · ")
    }

    private func summaryCard(_ title: String, value: String, subtitle: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent ? theme.accent : theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 9)).foregroundStyle(theme.textSecondary.opacity(0.8))
        }
        .frame(width: 170, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.separator))
    }

    // MARK: List

    /// One table-like panel: a header row carrying the select-all checkbox
    /// (same container and paddings as the rows, so the checkbox column lines
    /// up exactly), category bands inside it, hairlines between rows. Full
    /// width, aligned with the summary strip.
    private var list: some View {
        // The bars are relative to the heaviest row, so the largest finding
        // always spans the whole track and the rest read against it.
        let heaviest = controller.rows.map(\.size.bytes).max() ?? 0
        return ScrollView {
            VStack(spacing: 0) {
                selectAllHeader
                ForEach(controller.categories, id: \.self) { category in
                    Divider().overlay(theme.separator)
                    Text(category)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(theme.windowBackground.opacity(0.6))
                    let rows = controller.rows(in: category)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 {
                            Divider().overlay(theme.separator.opacity(0.5)).padding(.leading, 36)
                        }
                        CleanupRowView(row: row, theme: theme,
                                       heaviest: heaviest, total: controller.totalFound,
                                       disabled: controller.state == .cleaning) {
                            controller.toggle(row.id)
                        }
                    }
                }
            }
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.separator))
            .padding(14)
        }
    }

    /// Header row of the table: the tri-state select-all checkbox, in the same
    /// column as the row checkboxes below it.
    private var selectAllHeader: some View {
        HStack(spacing: 8) {
            CheckSquare(state: selectAllCheckState, theme: theme,
                        disabled: controller.state == .cleaning) {
                controller.toggleAll()
            }
            .accessibilityLabel("Select all")
            Text("Select all")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(Format.bytes(controller.totalSelected))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(controller.totalSelected > 0 ? theme.textPrimary : theme.textSecondary.opacity(0.6))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if controller.state != .cleaning { controller.toggleAll() } }
    }

    private var selectAllCheckState: CheckSquare.CheckState {
        switch controller.selectAllState {
        case .none: return .off
        case .some: return .mixed
        case .all: return .on
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
                // Not all of it is a cache any more: build output and orphaned
                // editor state are offered too, and the footer must not promise
                // that everything listed comes back on its own.
                Text(controller.rows.allSatisfy(\.item.regenerable)
                     ? "Everything here is safe to remove: caches and build output are "
                       + "re-downloaded or rebuilt when needed."
                     : "Safe to remove — though the rows marked below are not caches and "
                       + "will not come back. Select those one by one.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button {
                activeWarnings = ToolActivity.activeTools(
                    for: Set(controller.selectedRows.map(\.id)))
                confirmClean = true
            } label: {
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

/// Checkbox drawn from SF Symbols so the select-all checkbox can show a mixed
/// state (SwiftUI's native `.checkbox` toggle is two-state only) and every
/// checkbox in the list shares one look.
private struct CheckSquare: View {
    enum CheckState { case off, on, mixed }
    let state: CheckState
    let theme: Theme
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state == .off ? theme.textSecondary : theme.accent)
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityValue(state == .on ? "checked" : state == .mixed ? "partially checked" : "unchecked")
    }

    private var symbol: String {
        switch state {
        case .off: return "square"
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        }
    }
}

private struct CleanupRowView: View {
    let row: CleanupController.Row
    let theme: Theme
    /// Bytes of the heaviest row — the full length of the weight bar.
    let heaviest: Int64
    /// Bytes of every row — what the bar's tooltip states a share of.
    let total: Int64
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            CheckSquare(state: row.selected ? .on : .off, theme: theme,
                        disabled: disabled || !row.size.isSelectable, action: toggle)

            Image(systemName: row.item.icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
                .frame(width: 18)

            Text(row.item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(2)

            Text(row.item.note)
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)

            // The one distinction the row must carry on its face: these bytes
            // do not come back. It is also why select-all skips the row, so the
            // badge explains an absence the user would otherwise have to notice.
            if !row.item.regenerable {
                Text("not a cache")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE0915A))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(hex: 0xE0915A).opacity(0.14)))
                    .layoutPriority(1)
                    .help("Deleting this frees space permanently — nothing regenerates it, "
                          + "so it is never included in Select all.")
            }

            if let native = row.nativeLabel {
                Text("via \(native)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.accent.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.opacity(0.12)))
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            // Discovered targets carry hundreds of paths; listing them would be
            // a truncated smear, so they summarise instead. The full list is
            // still in the tooltip and in the journal.
            Text(row.item.locationLabel ?? row.item.paths.map(abbreviate).joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary.opacity(0.7))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
                // A summary label is short and says nothing once cut ("3…IR"):
                // it keeps its width and the note gives way instead. A path
                // still truncates in the middle, where it loses least.
                .fixedSize(horizontal: row.item.locationLabel != nil, vertical: false)
                .help(row.item.paths.prefix(40).map(abbreviate).joined(separator: "\n")
                      + (row.item.paths.count > 40 ? "\n… and \(row.item.paths.count - 40) more" : ""))

            weightBar

            sizeLabel
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        // Still searching, or nothing there: present, but not something to act on.
        .opacity(row.size == .searching || row.size.isEmpty ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled && row.size.isSelectable { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.item.name), \(sizeAccessibility)"
                            + (share.map { ", \($0) of everything found" } ?? ""))
    }

    /// This row's weight against the heaviest one: length and heat say the
    /// same thing, so the colour is never the only carrier. A row with nothing
    /// measured yet keeps an empty track, so the column never shifts.
    private var weightBar: some View {
        let bytes = row.size.bytes
        let fraction = heaviest > 0 ? Double(bytes) / Double(heaviest) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.barTrack)
                if bytes > 0 {
                    // A sliver even for a few KiB: present, just negligible.
                    Capsule().fill(Theme.heatColor(fraction))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
        }
        .frame(width: 110, height: 5)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .help(share.map { "\(Format.bytes(bytes)) — \($0) of everything found" } ?? "")
        .accessibilityHidden(true)
    }

    /// Share of the mode's total, as the tooltip and VoiceOver state it.
    private var share: String? {
        let bytes = row.size.bytes
        guard bytes > 0, total > 0 else { return nil }
        let percent = Double(bytes) / Double(total) * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    @ViewBuilder
    private var sizeLabel: some View {
        switch row.size {
        case .searching:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Searching")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
        case .pending:
            ProgressView().controlSize(.mini)
        case .sized(0):
            Text("Empty")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
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
        case .blocked(let reason):
            Label("Protected", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(hex: 0xE0915A))
                .help(reason)
        }
    }

    private var sizeAccessibility: String {
        switch row.size {
        case .searching: return "searching"
        case .pending: return "measuring"
        case .sized(0): return "empty"
        case .sized(let bytes): return Format.bytes(bytes)
        case .denied: return "needs Full Disk Access"
        case .blocked(let reason): return "protected: \(reason)"
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
