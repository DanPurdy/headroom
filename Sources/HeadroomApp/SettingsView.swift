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
                Text("No Claude Code folders found in your home folder. Headroom needs Claude Code on this Mac: install it and log in, or add your folder if it lives somewhere else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.setupRows) { row in
                SetupRowView(row: row, model: model)
            }
            Button("Add folder…", action: chooseFolder)
                .controlSize(.small)
                .help("Add a Claude Code config folder that isn't ~/.claude or ~/.claude-*")
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Each folder is one Claude login. Install wraps its status line so Headroom records usage after every Claude Code reply. Your status line keeps working, and Remove puts it back.\n\nLive also checks usage hourly and on ⟳, catching use from claude.ai, the desktop app and other devices. It reads Claude Code's saved login from your Keychain (read-only; macOS asks first) and calls Anthropic's undocumented usage endpoint.")
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

extension SettingsPage {
    /// Hidden folders shown, since Claude Code folders usually start with a dot.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose a Claude Code folder"
        panel.prompt = "Add"
        NSApplication.shared.activate()
        if panel.runModal() == .OK, let url = panel.url {
            model.addConfigDir(url.path)
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
                    .onSubmit(saveLabel)
                    .help("Name shown for this account. Press Return to save.")
                Spacer()
                actions
            }
            .controlSize(.small)
            Toggle("Live usage", isOn: Binding(get: { row.liveEnabled },
                                               set: { model.setLive(configDir: row.configDir, enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func saveLabel() {
        if case .installed(let current) = row.state, current != label {
            model.install(configDir: row.configDir, label: label)
        }
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
            if row.isUserAdded {
                Button("Forget") { model.forgetConfigDir(row.configDir) }
                    .help("Remove this folder from Headroom's list")
            }
            Button("Install") { model.install(configDir: row.configDir, label: label) }
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
