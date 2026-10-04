import HeadroomCore
import SwiftUI

struct SettingsView: View {
    let model: UsageModel

    var body: some View {
        Form {
            Section {
                if model.setupRows.isEmpty {
                    Text("No Claude Code folders found in your home folder.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.setupRows) { row in
                    SetupRowView(row: row, model: model)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Claude Code accounts")
            } footer: {
                Text("Each Claude Code folder is one login. Installing wraps that folder's status line so Headroom can record your usage. Your existing status line keeps working, and Remove puts it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
            }

            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Link("github.com/DanPurdy/headroom", destination: URL(string: "https://github.com/DanPurdy/headroom")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.configDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout.monospaced())
                TextField("Label", text: $label, prompt: Text("Label"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            Spacer()
            switch row.state {
            case .notInstalled:
                Button("Install") { model.install(configDir: row.configDir, label: label) }
                    .buttonStyle(.borderedProminent)
            case .installed(let current):
                if current != label {
                    Button("Rename") { model.install(configDir: row.configDir, label: label) }
                } else {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Remove") { model.uninstall(configDir: row.configDir) }
            case .stale:
                Button("Repair") { model.install(configDir: row.configDir, label: label) }
                    .help("Installed, but pointing at an older copy of Headroom.")
                Button("Remove") { model.uninstall(configDir: row.configDir) }
            }
        }
    }
}
