import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastScan: Date = .distantPast
    @Published private(set) var lastHookKind: String?    // last hook event name, for footer status

    private let projectsDir: URL
    private let fm = FileManager.default
    private let iso = ISO8601DateFormatter()
    private var pollTimer: Timer?

    /// Callback fired when a session transitions to idle past the configured threshold.
    /// Set by AppDelegate to wire notifications. Only fires once per session-threshold pair.
    var onIdleAlert: ((Session) -> Void)?
    private var alertedSessions: Set<String> = []

    var idleThreshold: TimeInterval = 30 * 60  // 30 min default; overwritten from Preferences

    init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) {
        self.projectsDir = projectsDir
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        loadPersistedState()
    }

    // MARK: - Persistence

    private static var stateFile: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Agentmon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: Self.stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Session].self, from: data) else { return }
        // Only keep sessions whose JSONL file still exists — pruned files mean stale offsets
        let fm = FileManager.default
        sessions = decoded.filter { fm.fileExists(atPath: $0.filePath) }
    }

    private func persistState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: Self.stateFile, options: .atomic)
    }

    func start() {
        Task { await self.rescan() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.rescan()
                self?.checkIdleAlerts()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Hook-driven push entry point — immediate rescan.
    func handleHook(_ event: HookEvent) {
        lastHookKind = event.kind.rawValue
        Task { @MainActor in
            await self.rescan()
            self.checkIdleAlerts()
        }
    }

    var liveSessions: [Session] {
        sessions
            .filter { $0.state != .stale && !Preferences.shared.isMuted($0.cwd) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var recentSessions: [Session] {
        let cutoff = Date().addingTimeInterval(-86_400)
        return sessions
            .filter { $0.state == .stale && $0.lastActivity > cutoff && !Preferences.shared.isMuted($0.cwd) }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(10)
            .map { $0 }
    }

    /// All distinct cwds we've ever observed — used by Preferences to list mute targets.
    var knownProjects: [String] {
        let cwds = Set(sessions.compactMap { $0.cwd })
        return cwds.sorted()
    }

    var totalUsage: TokenUsage {
        sessions.reduce(TokenUsage()) { $0 + $1.usage }
    }

    /// Estimated cost across all sessions in the current view, summed per model.
    var totalCost: Double {
        sessions.reduce(0) { acc, s in
            acc + ModelPricing.forModel(s.model).cost(for: s.usage)
        }
    }

    private func checkIdleAlerts() {
        guard let cb = onIdleAlert else { return }
        let now = Date()
        for s in sessions where !Preferences.shared.isMuted(s.cwd) {
            let age = now.timeIntervalSince(s.lastActivity)
            if age >= idleThreshold && age < idleThreshold + 30 && !alertedSessions.contains(s.id) {
                alertedSessions.insert(s.id)
                cb(s)
            }
            if age < 30 {
                alertedSessions.remove(s.id)
            }
        }
    }

    private func rescan() async {
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        var updated = sessions
        var idx: [String: Int] = [:]
        for (i, s) in updated.enumerated() { idx[s.id] = i }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = attrs.contentModificationDate,
                      Date().timeIntervalSince(mtime) < 86_400 else { continue }
                ingestFile(file, into: &updated, idx: &idx)
            }
        }

        sessions = updated
        lastScan = Date()
        persistState()
    }

    private func ingestFile(_ file: URL, into sessions: inout [Session], idx: inout [String: Int]) {
        let sessionId = file.deletingPathExtension().lastPathComponent
        let existingOffset = idx[sessionId].map { sessions[$0].fileOffset } ?? 0
        let existingCount = idx[sessionId].map { sessions[$0].messageCount } ?? 0
        let existingUsage = idx[sessionId].map { sessions[$0].usage } ?? TokenUsage()

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize <= existingOffset { return }

        try? handle.seek(toOffset: existingOffset)
        guard let data = try? handle.readToEnd() else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        let completeLines = lines.dropLast()  // always skip final (empty or partial)
        guard !completeLines.isEmpty else { return }

        var newCount = 0
        var addedUsage = TokenUsage()
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
            if let u = parsed.message?.usage {
                addedUsage = addedUsage + u.asTokenUsage
            }
        }

        // Compute new offset = existing + length of complete lines
        let completeLength: UInt64
        if text.hasSuffix("\n") {
            completeLength = UInt64(data.count)
        } else if let lastNL = text.range(of: "\n", options: .backwards) {
            let idx = text.distance(from: text.startIndex, to: lastNL.upperBound)
            completeLength = UInt64(idx)
        } else {
            completeLength = 0
        }
        let newOffset = existingOffset + completeLength

        if let i = idx[sessionId] {
            if let ts = latestTimestamp { sessions[i].lastActivity = ts }
            if !latestType.isEmpty { sessions[i].lastEventType = latestType }
            if let c = cwd { sessions[i].cwd = c }
            if let m = model { sessions[i].model = m }
            if let b = gitBranch { sessions[i].gitBranch = b }
            sessions[i].fileOffset = newOffset
            sessions[i].messageCount = existingCount + newCount
            sessions[i].usage = existingUsage + addedUsage
        } else {
            let s = Session(
                id: sessionId,
                cwd: cwd,
                model: model,
                gitBranch: gitBranch,
                lastActivity: latestTimestamp ?? Date(),
                lastEventType: latestType.isEmpty ? "unknown" : latestType,
                filePath: file.path,
                fileOffset: newOffset,
                messageCount: newCount,
                usage: addedUsage
            )
            sessions.append(s)
            idx[sessionId] = sessions.count - 1
        }
    }
}
