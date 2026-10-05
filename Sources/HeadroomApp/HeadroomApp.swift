import AppKit
import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything lives in the status item's panel; an app needs at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusPanel: StatusPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusPanel = StatusPanel(model: UsageModel())
    }
}

/// The menu bar item and its dropdown panel.
///
/// Not SwiftUI's `MenuBarExtra`: its window leaves a ghost of its old outline behind when the
/// content shrinks (e.g. switching pages), so this panel sizes itself to the content explicitly,
/// keeping its top edge under the menu bar.
@MainActor
final class StatusPanel: NSObject {
    private let model: UsageModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = Panel()
    private var clickMonitor: Any?

    init(model: UsageModel) {
        self.model = model
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        panel.onClose = { [weak self] in self?.close() }
        updateButton()
    }

    /// Redraws the menu bar gauge whenever what it shows changes.
    private func updateButton() {
        let (columns, description) = withObservationTracking {
            (model.menuBarColumns, model.menuBarDescription)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateButton() }
        }
        guard let button = statusItem.button else { return }
        button.image = MenuBarGauge.image(for: columns)
            ?? NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Headroom")
        button.setAccessibilityLabel(description.isEmpty ? "Headroom" : description)
    }

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        // Built on each open and dropped on close, so nothing (e.g. countdown timers) runs while hidden.
        let root = UsageView(model: model)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in self?.resize(to: size) }
        let hosting = NSHostingView(rootView: root)
        // Reports its size but adds no window constraints: the panel follows the content.
        hosting.sizingOptions = [.intrinsicContentSize]

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        hosting.frame = background.bounds
        resize(to: hosting.fittingSize)
        statusItem.button?.highlight(true)
        panel.orderFrontRegardless()
        panel.makeKey()

        // A click anywhere outside Headroom closes it, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        statusItem.button?.highlight(false)
        clickMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
    }

    /// Hangs the panel from the menu bar, under the status item, kept on screen.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0,
              let buttonWindow = statusItem.button?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.frame
        let visible = screen.visibleFrame
        let height = min(size.height, visible.height - 8)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 4 - height, width: size.width, height: height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}

/// A borderless-looking panel that can take keyboard focus (for renaming accounts) without
/// activating the app, with rounded corners and a normal window shadow.
final class Panel: NSPanel {
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = true
        // Above other apps' windows, but below the Add folder… sheet (a modal panel).
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    /// Escape closes it, like a menu.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
