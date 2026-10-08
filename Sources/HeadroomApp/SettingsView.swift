import HeadroomCore
import SwiftUI

/// The settings page of the dropdown.
struct SettingsPage: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code accounts")
                .font(.subheadline.weight(.semibold))

            if model.isTranslocated {
                Text("Move Headroom to Applications to install.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.setupRows.isEmpty {
                Text("No Claude Code folders found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.setupRows) { row in
                SetupRowView(row: row, model: model)
            }
            Button("Add folder…", action: chooseFolder)
                .controlSize(.small)
                .help("Add a Claude Code folder outside ~/.claude*")
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            HStack {
                Toggle("Check for updates", isOn: Binding(get: { model.checksForUpdates },
                                                          set: { model.setChecksForUpdates($0) }))
                    .toggleStyle(.switch)
                    .help("Asks GitHub for the latest release once a day")
                Button(model.checkingForUpdates ? "Checking…" : "Check now", action: model.checkForUpdatesNow)
                    .disabled(model.checkingForUpdates)
                if let update = model.update {
                    Button(model.updating ? "Updating…" : "Update to \(update.version)", action: model.installUpdate)
                        .disabled(model.updating)
                        .help("Download it, replace this copy and reopen Headroom")
                } else if let result = model.updateCheckResult {
                    Text(result).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .font(.callout)

            if model.notificationsAvailable {
                Picker("Usage alerts", selection: Binding(get: { model.alertThreshold },
                                                          set: { model.setAlertThreshold($0) })) {
                    Text("Off").tag(0)
                    Text("At 80%").tag(80)
                    Text("At 90%").tag(90)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
                .font(.callout)
                .help("Notify when a limit passes this, and again when it resets")
            }

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
                    .help("Press Return to save")
                Spacer()
                actions
            }
            .controlSize(.small)
            Toggle("Live usage", isOn: Binding(get: { row.liveEnabled }, set: setLive))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help("Also counts claude.ai, the desktop app and other devices")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func setLive(_ enabled: Bool) {
        if enabled, !confirmLive() { return }
        model.setLive(configDir: row.configDir, enabled: enabled)
    }

    private func confirmLive() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn on Live usage?"
        alert.informativeText = "Headroom will read this account's Claude Code login from your Keychain and use it to ask Anthropic for your usage, once an hour and when you press ⟳. This also counts claude.ai, the desktop app and other devices.\n\nmacOS will ask for your password. The login is kept in memory only and sent only to Anthropic. When Claude Code renews it, Live pauses until you press ⟳."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
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
                .help("Points at an older copy of Headroom")
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
                .help("Record usage after each Claude Code reply. Your status line keeps working.")
        case .installed(let current):
            if current != label {
                Button("Rename") { model.install(configDir: row.configDir, label: label) }
            }
            Button("Remove") { model.uninstall(configDir: row.configDir) }
                .help("Restore your original status line")
        case .stale:
            Button("Repair") { model.install(configDir: row.configDir, label: label) }
            Button("Remove") { model.uninstall(configDir: row.configDir) }
        }
    }
}
