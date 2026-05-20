import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastScan: Date = .distantPast

    private let projectsDir: URL
    private let fm = FileManager.default
    private let iso = ISO8601DateFormatter()
    private var pollTimer: Timer?

    init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) {
        self.projectsDir = projectsDir
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() {
        // initial scan
        Task { await self.rescan() }
        // poll every 2s
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.rescan() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Active or idle (i.e. activity within last 5 min)
    var liveSessions: [Session] {
        sessions
            .filter { $0.state != .stale }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Last 24h, excluding live
    var recentSessions: [Session] {
        let cutoff = Date().addingTimeInterval(-86_400)
        return sessions
            .filter { $0.state == .stale && $0.lastActivity > cutoff }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(10)
            .map { $0 }
    }

    private func rescan() async {
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        var updated = sessions
        // Index by id for O(1) lookup
        var idx: [String: Int] = [:]
        for (i, s) in updated.enumerated() { idx[s.id] = i }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Only consider files modified in last 24h to skip ancient logs
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = attrs.contentModificationDate,
                      Date().timeIntervalSince(mtime) < 86_400 else { continue }

                await ingestFile(file, into: &updated, idx: &idx)
            }
        }

        sessions = updated
        lastScan = Date()
    }

    private func ingestFile(_ file: URL, into sessions: inout [Session], idx: inout [String: Int]) async {
        let sessionId = file.deletingPathExtension().lastPathComponent

        // Find existing session for this file (by id) to get offset
        let existingOffset = idx[sessionId].map { sessions[$0].fileOffset } ?? 0
        let existingCount = idx[sessionId].map { sessions[$0].messageCount } ?? 0

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize <= existingOffset { return }  // nothing new

        try? handle.seek(toOffset: existingOffset)
        guard let data = try? handle.readToEnd() else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        // Parse new lines. Last partial line (no trailing \n) is skipped — we'll get it next poll.
        let lines = text.components(separatedBy: "\n")
        let completeLines = text.hasSuffix("\n") ? lines.dropLast() : lines.dropLast()  // always drop last (either empty or partial)
        guard !completeLines.isEmpty else { return }

        var newCount = 0
        var latestTimestamp: Date?
        var latestType = ""
        var cwd: String?
        var model: String?
        var gitBranch: String?

        let decoder = JSONDecoder()
        for line in completeLines {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let parsed = try? decoder.decode(JSONLine.self, from: lineData) else { continue }
            newCount += 1
            if let ts = parsed.timestamp, let date = iso.date(from: ts) {
                if latestTimestamp == nil || date > latestTimestamp! { latestTimestamp = date }
            }
            if let t = parsed.type, !t.isEmpty { latestType = t }
            if let c = parsed.cwd { cwd = c }
            if let m = parsed.message?.model { model = m }
            if let b = parsed.gitBranch { gitBranch = b }
        }

        // Compute new offset — how much of `data` was complete lines
        let completeLength: UInt64
        if text.hasSuffix("\n") {
            completeLength = UInt64(data.count)
        } else {
            // Find last newline
            if let lastNL = text.range(of: "\n", options: .backwards) {
                let idx = text.distance(from: text.startIndex, to: lastNL.upperBound)
                completeLength = UInt64(idx)
            } else {
                completeLength = 0
            }
        }
        let newOffset = existingOffset + completeLength

        if let i = idx[sessionId] {
            // Update existing
            if let ts = latestTimestamp { sessions[i].lastActivity = ts }
            if !latestType.isEmpty { sessions[i].lastEventType = latestType }
            if let c = cwd { sessions[i].cwd = c }
            if let m = model { sessions[i].model = m }
            if let b = gitBranch { sessions[i].gitBranch = b }
            sessions[i].fileOffset = newOffset
            sessions[i].messageCount = existingCount + newCount
        } else {
            // Need at least a timestamp to insert
            let s = Session(
                id: sessionId,
                cwd: cwd,
                model: model,
                gitBranch: gitBranch,
                lastActivity: latestTimestamp ?? Date(),
                lastEventType: latestType.isEmpty ? "unknown" : latestType,
                filePath: file.path,
                fileOffset: newOffset,
                messageCount: newCount
            )
            sessions.append(s)
            idx[sessionId] = sessions.count - 1
        }
    }
}
