import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = SessionStore()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store))

        store.start()

        // Re-render the status bar label whenever sessions change
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        // Tick every second for relative-time updates ("2s ago" → "3s ago")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }

        updateStatusBar()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusBar() {
        let active = store.liveSessions.filter { $0.state == .active }.count
        let idle = store.liveSessions.filter { $0.state == .idle }.count
        let total = active + idle

        guard let button = statusItem.button else { return }

        let symbol: String
        if active > 0 {
            symbol = "circle.fill"  // green
        } else if idle > 0 {
            symbol = "circle.dotted"
        } else {
            symbol = "circle"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [statusColor(active: active, idle: idle)]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agentmon")?
            .withSymbolConfiguration(config)

        button.image = image
        button.imagePosition = total > 0 ? .imageLeading : .imageOnly
        button.title = total > 0 ? "  \(total)" : ""
    }

    private func statusColor(active: Int, idle: Int) -> NSColor {
        if active > 0 { return .systemGreen }
        if idle > 0 { return .systemYellow }
        return .secondaryLabelColor
    }
}
