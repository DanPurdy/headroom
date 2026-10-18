import AppKit
import HeadroomCore
import SwiftUI

/// How much the menu bar item shows. Settings → Menu bar.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// Each account's label, bars and percentages.
    case bars
    /// Label and bars only, for a narrower item.
    case compact
    /// Headroom's icon alone; the usage is in the dropdown.
    case icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: "Bars and percentages"
        case .compact: "Bars only"
        case .icon: "Icon only"
        }
    }
}

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
    var showsPercentages = true

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
            if showsPercentages {
                // Fixed width so the item doesn't shift as numbers change.
                Text(Formatting.percent(clamped))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .frame(width: 20, alignment: .leading)
            }
        }
        .frame(height: 8)
    }

    /// A menu bar label can only be Text or Image, so render the gauge to a template image,
    /// which macOS tints to match a light or dark menu bar. nil when there's nothing to draw
    /// (no columns, or the icon style): the caller shows Headroom's icon instead.
    @MainActor
    static func image(for columns: [Column], style: MenuBarStyle = .bars) -> NSImage? {
        guard !columns.isEmpty, style != .icon else { return nil }
        let renderer = ImageRenderer(content: MenuBarGauge(columns: columns, showsPercentages: style == .bars))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
