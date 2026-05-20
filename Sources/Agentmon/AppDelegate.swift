import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = SessionStore()
    private let prefs = Preferences.shared
    private var hookServer: HookServer?
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
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store, prefs: prefs))

        // Wire idle notifications
        store.idleThreshold = prefs.idleThresholdMinutes * 60
        store.onIdleAlert = { [weak self] session in
            self?.deliverIdleNotification(for: session)
        }
        prefs.$idleThresholdMinutes
            .sink { [weak self] mins in self?.store.idleThreshold = mins * 60 }
            .store(in: &cancellables)

        // Notification permission (silent if denied — UI still works)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        store.start()

        // Hook server — listens on 127.0.0.1:7842 for push events
        hookServer = HookServer { [weak self] event in
            Task { @MainActor [weak self] in
                self?.store.handleHook(event)
            }
        }
        hookServer?.start()

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusBar() }
        }

        updateStatusBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookServer?.stop()
        store.stop()
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
        let waiting = store.liveSessions.filter { $0.state == .waiting }.count
        let idle = store.liveSessions.filter { $0.state == .idle }.count
        let total = active + waiting + idle

        guard let button = statusItem.button else { return }

        // Priority: waiting (you need to do something) > active (it's working) > idle
        let symbol: String
        let color: NSColor
        if waiting > 0 {
            symbol = "circle.fill"
            color = .systemBlue
        } else if active > 0 {
            symbol = "circle.fill"
            color = .systemGreen
        } else if idle > 0 {
            symbol = "circle.dotted"
            color = .systemYellow
        } else {
            symbol = "circle"
            color = .secondaryLabelColor
        }

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agentmon")?
            .withSymbolConfiguration(config)

        button.image = image
        button.imagePosition = total > 0 ? .imageLeading : .imageOnly
        button.title = total > 0 ? "  \(total)" : ""
    }

    private func deliverIdleNotification(for session: Session) {
        guard prefs.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Idle session"
        content.body = "\(session.displayName) — idle for \(Int(prefs.idleThresholdMinutes)) min"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "agentmon.idle.\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
