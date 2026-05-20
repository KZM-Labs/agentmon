import Foundation

enum SessionState: String {
    case active   // activity within last 30s
    case idle     // 30s–5min
    case stale    // >5min but <24h
}

struct Session: Identifiable, Equatable {
    let id: String              // sessionId UUID
    var cwd: String?            // working directory
    var model: String?          // e.g. claude-opus-4-7
    var gitBranch: String?
    var lastActivity: Date
    var lastEventType: String   // user / assistant / tool_use
    var filePath: String        // absolute path to JSONL
    var fileOffset: UInt64      // bytes read so far
    var messageCount: Int

    var state: SessionState {
        let age = Date().timeIntervalSince(lastActivity)
        if age < 30 { return .active }
        if age < 300 { return .idle }
        return .stale
    }

    var displayCwd: String {
        guard let cwd else { return "~" }
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    var displayName: String {
        // Last path component of cwd, or session UUID prefix
        if let cwd, let last = cwd.split(separator: "/").last {
            return String(last)
        }
        return String(id.prefix(8))
    }
}

/// One parsed JSONL line — minimal fields we actually use
struct JSONLine: Decodable {
    let sessionId: String?
    let cwd: String?
    let timestamp: String?
    let type: String?
    let gitBranch: String?
    let version: String?
    let message: MessageStub?

    struct MessageStub: Decodable {
        let model: String?
    }
}
