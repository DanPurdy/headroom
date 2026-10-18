import HeadroomCore
import SwiftUI

/// The settings page of the dropdown, in tabs.
struct SettingsPage: View {
    let model: UsageModel
    @AppStorage("settingsTab") private var tab = Tab.accounts

    enum Tab: String {
        case accounts, alerts, general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $tab) {
                Text("Accounts").tag(Tab.accounts)
                Text("Alerts").tag(Tab.alerts)
                Text("General").tag(Tab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .accounts: accounts
            case .alerts: alerts
            case .general: general
            }

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        // A first run lands where setup happens.
        .onAppear { if model.accounts.isEmpty { tab = .accounts } }
        // Clicking empty space ends editing a label, which saves it.
        .contentShape(Rectangle())
        .onTapGesture { NSApplication.shared.keyWindow?.makeFirstResponder(nil) }
    }

    @ViewBuilder private var accounts: some View {
        Text("Claude Code accounts")
            .font(.subheadline.weight(.semibold))
        Text("Found on this Mac: ~/.claude and every ~/.claude-* folder. Each is one account. Connect the ones you use.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

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
        Button("Add folder…") { chooseClaudeFolder(model) }
            .controlSize(.small)
            .help("Add a Claude Code folder outside ~/.claude*")
        if model.hasLiveAccounts {
            LiveIntervalSetting(model: model)
        }

        Divider()

        Text("Codex accounts")
            .font(.subheadline.weight(.semibold))
        Text("Found on this Mac: ~/.codex and every ~/.codex-* folder. Track the ones you use.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if model.codexRows.isEmpty {
            Text("No Codex folders found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Headroom looks for ~/.codex and ~/.codex-* folders with Codex sessions in them")
        }
        ForEach(model.codexRows) { row in
            CodexRowView(row: row, model: model)
        }
    }

    @ViewBuilder private var alerts: some View {
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
            .help("Notify when a limit passes this, and again when it resets. With Live on, also when an account starts on extra usage.")

            if model.hasLiveAccounts {
                SpendAlertSetting(model: model)
            } else {
                Note("Turn Live on for an account (Accounts) to be warned about extra usage spend.")
            }
            Note("To be warned before a session's prompt cache goes cold, click its 🔥 countdown in the menu.")
        } else {
            Note("Notifications need Headroom installed as an app, in Applications.")
        }
    }

    @ViewBuilder private var general: some View {
        Text("Menu bar")
            .font(.subheadline.weight(.semibold))
        Picker("Show", selection: Binding(get: { model.menuBarStyle }, set: { model.setMenuBarStyle($0) })) {
            ForEach(MenuBarStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .controlSize(.small)
        .font(.callout)
        .help("How much the menu bar item shows. The dropdown always shows everything.")
        if model.menuBarStyle != .icon, !model.accounts.isEmpty {
            Text("Accounts in the menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.accounts) { row in
                Toggle(isOn: Binding(get: { !model.hiddenMenuBarAccounts.contains(row.key) },
                                     set: { model.setShownInMenuBar(row.key, $0) })) {
                    HStack(spacing: 5) {
                        Circle().fill(row.tint).frame(width: 7, height: 7)
                        Text(row.label)
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.callout)
            }
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
            if let update = model.update {
                Button(model.updating ? "Updating…" : "Update now", action: model.installUpdate)
                    .disabled(model.updating)
                    .help("Install \(update.version) and reopen Headroom")
            } else {
                Button(model.checkingForUpdates ? "Checking…" : "Check now", action: model.checkForUpdatesNow)
                    .disabled(model.checkingForUpdates)
                if let result = model.updateCheckResult {
                    Text(result).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .font(.callout)

        Divider()

        HStack {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Setup guide…") { model.showGuide() }
                .buttonStyle(.link)
            Link("GitHub", destination: URL(string: "https://github.com/DanPurdy/headroom")!)
        }
        .font(.caption)
    }
}

/// How often Live checks an account that's on extra usage.
struct LiveIntervalSetting: View {
    let model: UsageModel

    private var steps: [Int] { LiveSchedule.extraUsageMinutes }

    var body: some View {
        HStack {
            Text("On extra usage, check Live every")
            Slider(value: Binding(get: { Double(steps.firstIndex(of: model.extraUsageMinutes) ?? 0) },
                                  set: { model.setExtraUsageMinutes(steps[min(max(Int($0.rounded()), 0), steps.count - 1)]) }),
                   in: 0...Double(steps.count - 1), step: 1)
                .frame(width: 90)
            Text("\(model.extraUsageMinutes) min")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .font(.callout)
        .help("While an account's plan limit is full and it's spending extra usage, Live checks this often instead of hourly")
    }
}

/// Notify once this month's extra usage passes an amount.
struct SpendAlertSetting: View {
    let model: UsageModel
    @State private var enabled: Bool
    @State private var amount: String
    @FocusState private var editingAmount: Bool

    private static let defaultAmount = "100"

    init(model: UsageModel) {
        self.model = model
        _enabled = State(initialValue: !model.extraUsageAlertAmount.isEmpty)
        _amount = State(initialValue: model.extraUsageAlertAmount.isEmpty ? Self.defaultAmount : model.extraUsageAlertAmount)
    }

    /// The Live accounts' currency, when they share one.
    private var currency: String? {
        let currencies = Set(model.accounts.filter { $0.live != nil }.compactMap { $0.snapshot?.extraUsage?.currency })
        return currencies.count == 1 ? currencies.first : nil
    }

    var body: some View {
        HStack(spacing: 4) {
            Toggle("Notify when extra usage passes", isOn: Binding(get: { enabled }, set: { enabled = $0; save() }))
                .toggleStyle(.checkbox)
            if let currency {
                Text(Formatting.currencySymbol(currency))
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
            TextField("Amount", text: $amount, prompt: Text(Self.defaultAmount))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(!enabled)
                .focused($editingAmount)
                .onSubmit(save)
                .onChange(of: editingAmount) { _, editing in if !editing { save() } }
                .onDisappear(perform: save)
        }
        .controlSize(.small)
        .font(.callout)
        .help("Once a month per account, when its extra usage spend passes this amount, in its own currency. Saved when you press Return or click away.")
    }

    private func save() {
        if SpendAlerts.amount(from: amount) == nil {
            amount = model.extraUsageAlertAmount.isEmpty ? Self.defaultAmount : model.extraUsageAlertAmount
        }
        let saved = enabled ? amount.trimmingCharacters(in: .whitespaces) : ""
        if saved != model.extraUsageAlertAmount {
            model.setExtraUsageAlertAmount(saved)
        }
    }
}

/// Hidden folders shown, since Claude Code folders usually start with a dot.
@MainActor
func chooseClaudeFolder(_ model: UsageModel) {
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

struct SetupRowView: View {
    let row: SetupRow
    let model: UsageModel
    @State private var label: String
    @FocusState private var editingLabel: Bool

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
                    .focused($editingLabel)
                    .onSubmit(saveLabel)
                    .onChange(of: editingLabel) { _, editing in if !editing { saveLabel() } }
                    .onDisappear(perform: saveLabel) // closing the menu saves too
                    .help("Saved when you press Return or click away")
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
        alert.informativeText = "Headroom will read this account's Claude Code login from your Keychain and use it to ask Anthropic for your usage, once an hour (more often while the account is on extra usage, set in Settings) and when you press ⟳. This also counts claude.ai, the desktop app and other devices.\n\nmacOS will ask for your password. The login is kept in memory only and sent only to Anthropic. When Claude Code renews it, Live pauses until you press ⟳."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Renames a connected account; an emptied label goes back to the current one.
    private func saveLabel() {
        guard case .installed(let current) = row.state else { return }
        if label.trimmingCharacters(in: .whitespaces).isEmpty {
            label = current
        } else if current != label {
            model.install(configDir: row.configDir, label: label)
        }
    }

    @ViewBuilder private var status: some View {
        switch row.state {
        case .notInstalled:
            Text("Not connected").foregroundStyle(.secondary)
        case .installed:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
            Button("Connect") { model.install(configDir: row.configDir, label: label) }
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

struct CodexRowView: View {
    let row: CodexRow
    let model: UsageModel
    @State private var label: String
    @FocusState private var editingLabel: Bool

    init(row: CodexRow, model: UsageModel) {
        self.row = row
        self.model = model
        _label = State(initialValue: row.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.home.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if row.isTracked {
                    Label("Tracking", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not tracked").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Label", text: $label, prompt: Text("Label"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($editingLabel)
                    .onSubmit(saveLabel)
                    .onChange(of: editingLabel) { _, editing in if !editing { saveLabel() } }
                    .onDisappear(perform: saveLabel) // closing the menu saves too
                    .help("Saved when you press Return or click away")
                Spacer()
                if !row.isTracked {
                    Button("Track") { model.trackCodex(home: row.home, label: label) }
                        .help("Read usage from this folder's Codex session logs. Nothing in it is changed.")
                } else {
                    if row.label != label {
                        Button("Rename") { model.trackCodex(home: row.home, label: label) }
                    }
                    Button("Stop") { model.untrackCodex(home: row.home) }
                        .help("Stop reading this folder and forget its usage")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Renames a tracked home; an emptied label goes back to the current one.
    private func saveLabel() {
        guard row.isTracked else { return }
        if label.trimmingCharacters(in: .whitespaces).isEmpty {
            label = row.label
        } else if row.label != label {
            model.trackCodex(home: row.home, label: label)
        }
    }
}
