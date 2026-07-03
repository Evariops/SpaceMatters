import SwiftUI

/// File-type breakdown: which extensions consume the most space.
struct TypeBreakdownView: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = controller.extRows
        let maxSize = rows.first?.size(controller.metric) ?? 1

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("File types")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                if controller.selectedExt != nil {
                    Button { controller.toggleExt(controller.selectedExt!) } label: {
                        Text("clear filter").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(rows.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().overlay(theme.separator)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        TypeRow(row: row, metric: controller.metric, maxSize: max(maxSize, 1),
                                isSelected: controller.selectedExt == row.key) {
                            controller.toggleExt(row.key)
                        }
                    }
                }
            }
        }
        .background(theme.panelBackground)
    }
}

private struct TypeRow: View {
    let row: ExtRow
    let metric: SizeMetric
    let maxSize: Int64
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var fraction: Double {
        maxSize > 0 ? min(1, Double(row.size(metric)) / Double(maxSize)) : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.color(forHashable: row.name))
                .frame(width: 10, height: 10)

            Text(row.name)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule()
                        .fill(theme.color(forHashable: row.name))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 5)

            Text(Format.bytes(row.size(metric)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)

            Text(Format.count(row.count))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(theme.textSecondary.opacity(0.7))
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? theme.rowSelected : (hovering ? theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}
