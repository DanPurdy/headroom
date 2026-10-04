import SwiftUI

@main
struct HeadroomApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsageView(model: model)
        } label: {
            if let gauge = MenuBarGauge.image(for: model.menuBarColumns) {
                Image(nsImage: gauge)
                    .accessibilityLabel(model.menuBarDescription)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
