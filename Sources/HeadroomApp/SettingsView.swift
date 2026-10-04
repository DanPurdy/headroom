import HeadroomCore
import SwiftUI

/// The settings page of the dropdown.
struct SettingsPage: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code accounts")
                .font(.subheadline.weight(.semibold))

            if model.setupRows.isEmpty {
                Text("No Claude Code folders found in your home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.setupRows) { row in
                SetupRowView(row: row, model: model)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Each folder is one Claude login. Install wraps its status line so Headroom can record usage. Your status line keeps working, and Remove puts it back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            Divider()

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/DanPurdy/headroom")!)
            }
            .font(.caption)
        }
    }
}

struct SetupRowView: View {
    let row: SetupRow
    let model: UsageModel
    @State private var label: String

    init(row: SetupRow, model: UsageModel) {
        self.row = row
        self.model = model
        _label = State(initialValue: row.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.configDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                status
            }
            HStack {
                TextField("Label", text: $label, prompt: Text("Label"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Spacer()
                actions
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch row.state {
        case .notInstalled:
            Text("Not connected").foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stale:
            Text("Needs repair").foregroundStyle(.orange)
                .help("Installed, but pointing at an older copy of Headroom.")
        }
    }

    @ViewBuilder private var actions: some View {
        switch row.state {
        case .notInstalled:
            Button("Install") { model.install(configDir: row.configDir, label: label) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        case .installed(let current):
            if current != label {
                Button("Rename") { model.install(configDir: row.configDir, label: label) }
            }
            Button("Remove") { model.uninstall(configDir: row.configDir) }
        case .stale:
            Button("Repair") { model.install(configDir: row.configDir, label: label) }
            Button("Remove") { model.uninstall(configDir: row.configDir) }
        }
    }
}
