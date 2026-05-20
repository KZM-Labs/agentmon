import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.liveSessions.isEmpty && store.recentSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !store.liveSessions.isEmpty {
                            sectionHeader("ACTIVE (\(store.liveSessions.count))")
                            ForEach(store.liveSessions) { session in
                                SessionRow(session: session)
                            }
                        }
                        if !store.recentSessions.isEmpty {
                            sectionHeader("RECENT")
                            ForEach(store.recentSessions) { session in
                                SessionRow(session: session)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Agentmon")
                .font(.system(size: 13, weight: .semibold))
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

    private var emptyState: some View {
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
            Button("Open ~/.claude/projects") { openProjectsFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openProjectsFolder() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        NSWorkspace.shared.open(url)
    }
}

struct SessionRow: View {
    let session: Session

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
                }
                Spacer(minLength: 4)
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
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

    private func shortModel(_ m: String) -> String {
        // claude-opus-4-7 → opus-4.7, claude-sonnet-4-6 → sonnet-4.6
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
        // Open Terminal with `claude --resume <id>` in the session's cwd
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
