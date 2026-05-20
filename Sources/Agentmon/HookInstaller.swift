import Foundation

/// Installs Agentmon hook entries into ~/.claude/settings.json.
/// Deep-merges into existing `hooks` block; never overwrites unrelated keys.
enum HookInstaller {
    static let port = 7842
    static let signature = "agentmon-hook-v1"

    struct InstallResult {
        let installed: Bool
        let alreadyPresent: Bool
        let backupPath: String?
        let error: String?
    }

    static func install() -> InstallResult {
        let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) else {
                return InstallResult(installed: false, alreadyPresent: false, backupPath: nil, error: "Could not read \(settingsPath)")
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            } else if !data.isEmpty {
                return InstallResult(installed: false, alreadyPresent: false, backupPath: nil, error: "settings.json is not valid JSON")
            }
        }

        // Build the hook command — fire-and-forget POST to local daemon
        let cmd = "curl -s -X POST http://127.0.0.1:\(port)/hook -H 'Content-Type: application/json' --max-time 1 -d \"$(cat)\" >/dev/null 2>&1 || true"

        let hookEntry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": cmd,
                "_agentmon": signature
            ]]
        ]

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var alreadyPresent = true

        for event in ["Stop", "SubagentStop", "Notification", "SessionStart"] {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            let exists = arr.contains { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["_agentmon"] as? String) == signature }
            }
            if !exists {
                arr.append(hookEntry)
                alreadyPresent = false
            }
            hooks[event] = arr
        }
        root["hooks"] = hooks

        // Backup
        var backupPath: String? = nil
        if fm.fileExists(atPath: settingsPath) {
            let backup = settingsPath + ".agentmon.bak"
            try? fm.removeItem(atPath: backup)
            try? fm.copyItem(atPath: settingsPath, toPath: backup)
            backupPath = backup
        }

        // Write
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            return InstallResult(installed: !alreadyPresent, alreadyPresent: alreadyPresent, backupPath: backupPath, error: nil)
        } catch {
            return InstallResult(installed: false, alreadyPresent: false, backupPath: backupPath, error: error.localizedDescription)
        }
    }

    static func uninstall() -> Bool {
        let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }

        guard var hooks = root["hooks"] as? [String: Any] else { return true }
        for event in ["Stop", "SubagentStop", "Notification", "SessionStart"] {
            guard var arr = hooks[event] as? [[String: Any]] else { continue }
            arr.removeAll { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["_agentmon"] as? String) == signature }
            }
            hooks[event] = arr
        }
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        return true
    }
}
