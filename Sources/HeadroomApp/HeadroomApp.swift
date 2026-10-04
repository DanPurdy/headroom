import SwiftUI

@main
struct HeadroomApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsageView(model: model)
        } label: {
            if let title = model.menuBarTitle {
                Text(title)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
