import AppKit
import HeadroomCore
import SwiftUI

/// The menu bar item: one column per account, its label beside two stacked bars,
/// 5-hour usage on top and weekly underneath.
struct MenuBarGauge: View {
    struct Column: Identifiable {
        var id: String
        var label: String
        var fiveHour: Double
        var weekly: Double
        /// Dimmed when the reading may be out of date.
        var stale = false
    }

    let columns: [Column]

    private static let barWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            ForEach(columns) { column in
                HStack(spacing: 4) {
                    Text(column.label)
                        .font(.system(size: 11, weight: .medium))
                    VStack(alignment: .leading, spacing: 1) {
                        row(column.fiveHour)
                        row(column.weekly)
                    }
                }
                .opacity(column.stale ? 0.45 : 1)
            }
        }
        .frame(height: 18)
        .foregroundStyle(.black) // template image: only alpha matters
    }

    private func row(_ percentage: Double) -> some View {
        let clamped = min(max(percentage, 0), 100)
        return HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).opacity(0.3)
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: Self.barWidth * clamped / 100)
            }
            .frame(width: Self.barWidth, height: 4)
            // Fixed width so the item doesn't shift as numbers change.
            Text(Formatting.percent(clamped))
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .frame(width: 20, alignment: .leading)
        }
        .frame(height: 8)
    }

    /// A menu bar label can only be Text or Image, so render the gauge to a template image,
    /// which macOS tints to match a light or dark menu bar.
    @MainActor
    static func image(for columns: [Column]) -> NSImage? {
        guard !columns.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarGauge(columns: columns))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
