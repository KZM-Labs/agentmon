import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var prefs: Preferences
    @State private var showingPreferences = false
    @State private var hookStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if showingPreferences {
                PreferencesPane(prefs: prefs, hookStatus: $hookStatus, dismiss: { showingPreferences = false })
            } else {
                sessionList
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Agentmon")
                .font(.system(size: 13, weight: .semibold))
            if let kind = store.lastHookKind {
                Text("· hook:\(kind.lowercased())")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(scanStatus)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scanStatus: String {
        let age = Int(Date().timeIntervalSince(store.lastScan))
        if age < 2 { return "live" }
        return "\(age)s ago"
    }

    @ViewBuilder
    private var sessionList: some View {
        if store.liveSessions.isEmpty && store.recentSessions.isEmpty {
            VStack(spacing: 6) {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Start `claude` in any project")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.liveSessions.isEmpty {
                        sectionHeader("ACTIVE (\(store.liveSessions.count))")
                        ForEach(store.liveSessions) { session in
                            SessionRow(session: session, showCost: prefs.showCost)
                        }
                    }
                    if !store.recentSessions.isEmpty {
                        sectionHeader("RECENT")
                        ForEach(store.recentSessions) { session in
                            SessionRow(session: session, showCost: prefs.showCost)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if prefs.showCost {
                let cost = store.totalCost
                if cost > 0.001 {
                    Text(String(format: "$%.2f total", cost))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(showingPreferences ? "Back" : "Preferences") {
                showingPreferences.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PreferencesPane: View {
    @ObservedObject var prefs: Preferences
    @Binding var hookStatus: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(label: "Notifications") {
                Toggle("", isOn: $prefs.notificationsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Idle threshold")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(Int(prefs.idleThresholdMinutes)) min")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $prefs.idleThresholdMinutes, in: 5...120, step: 5)
            }

            row(label: "Show cost estimate") {
                Toggle("", isOn: $prefs.showCost)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("HOOK INTEGRATION")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
                Text("Push events drop update latency from ~2s to ~50ms. Writes to ~/.claude/settings.json with a .bak backup.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install Hooks") {
                        let r = HookInstaller.install()
                        if let err = r.error {
                            hookStatus = "Error: \(err)"
                        } else if r.alreadyPresent {
                            hookStatus = "Already installed."
                        } else {
                            hookStatus = "Installed. Restart Claude Code to activate."
                        }
                    }
                    Button("Uninstall") {
                        let ok = HookInstaller.uninstall()
                        hookStatus = ok ? "Uninstalled." : "Could not modify settings.json."
                    }
                    .buttonStyle(.bordered)
                }
                if let s = hookStatus {
                    Text(s)
                        .font(.system(size: 10))
                        .foregroundColor(s.hasPrefix("Error") ? .red : .secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .medium))
            Spacer()
            content()
        }
    }
}

struct SessionRow: View {
    let session: Session
    let showCost: Bool

    var body: some View {
        Button {
            resumeSession()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if showCost && session.usage.outputTokens > 0 {
                        Text(usageLine)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 4)
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stateColor: Color {
        switch session.state {
        case .active: return .green
        case .idle:   return .yellow
        case .stale:  return .gray
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let m = session.model { parts.append(shortModel(m)) }
        parts.append(session.displayCwd)
        if let b = session.gitBranch, !b.isEmpty { parts.append("(\(b))") }
        return parts.joined(separator: " · ")
    }

    private var usageLine: String {
        let u = session.usage
        let cost = ModelPricing.forModel(session.model).cost(for: u)
        let inK = (u.totalIn) / 1_000
        let outK = u.outputTokens / 1_000
        return String(format: "%dk in · %dk out · $%.3f", inK, outK, cost)
    }

    private func shortModel(_ m: String) -> String {
        let lower = m.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return m
    }

    private var relativeTime: String {
        let age = Date().timeIntervalSince(session.lastActivity)
        if age < 60 { return "\(Int(age))s" }
        if age < 3_600 { return "\(Int(age / 60))m" }
        if age < 86_400 { return "\(Int(age / 3_600))h" }
        return "\(Int(age / 86_400))d"
    }

    private func resumeSession() {
        let cwd = session.cwd ?? NSHomeDirectory()
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(shellEscape(cwd)) && claude --resume \(session.id)"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
