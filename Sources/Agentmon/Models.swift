import Foundation

enum SessionState: String {
    case active   // recent activity, assistant is working
    case waiting  // assistant finished, awaiting user input
    case idle     // 30s–5min with no clear waiting signal
    case stale    // >5min but <24h
}

struct TokenUsage: Equatable, Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreate: Int = 0
    var cacheRead: Int = 0

    var totalIn: Int { inputTokens + cacheCreate + cacheRead }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreate: lhs.cacheCreate + rhs.cacheCreate,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

struct Session: Identifiable, Equatable, Codable {
    let id: String              // sessionId UUID
    var cwd: String?
    var model: String?          // e.g. claude-opus-4-7
    var gitBranch: String?
    var lastActivity: Date
    var lastEventType: String   // user / assistant / tool_use
    var filePath: String
    var fileOffset: UInt64
    var messageCount: Int
    var usage: TokenUsage = TokenUsage()
    /// tool_use_id → tool name, populated when assistant emits tool_use,
    /// cleared when user line carries the matching tool_result.
    var pendingTools: [String: String] = [:]
    /// Track when each pending tool started (for "stuck on tool" UX later).
    var pendingToolStartedAt: [String: Date] = [:]

    /// The most recently dispatched tool that hasn't yet returned a tool_result.
    var currentTool: String? {
        // Pick the tool whose start time is latest
        let latest = pendingToolStartedAt.max(by: { $0.value < $1.value })
        guard let id = latest?.key else { return nil }
        return pendingTools[id]
    }

    var state: SessionState {
        let age = Date().timeIntervalSince(lastActivity)
        // If a tool is mid-flight, the session is working — not waiting on user
        if !pendingTools.isEmpty {
            if age < 300 { return .active }
            return .idle  // tool stalled out
        }
        // Assistant typed last + a few seconds passed = waiting on user input
        if lastEventType == "assistant" && age >= 5 && age < 1_800 {
            return .waiting
        }
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
        if let cwd, let last = cwd.split(separator: "/").last {
            return String(last)
        }
        return String(id.prefix(8))
    }
}

/// One parsed JSONL line — minimal fields we actually use.
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
        let usage: UsageStub?
        let content: [ContentBlock]?

        // message.content is polymorphic: array of blocks OR plain string.
        // We only care about tool_use / tool_result blocks; ignore everything else.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            usage = try c.decodeIfPresent(UsageStub.self, forKey: .usage)
            if let arr = try? c.decode([ContentBlock].self, forKey: .content) {
                content = arr
            } else {
                content = nil
            }
        }
        enum CodingKeys: String, CodingKey { case model, usage, content }
    }

    struct UsageStub: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    /// Minimal block representation. Unknown block types decode with `type` only.
    struct ContentBlock: Decodable {
        let type: String?
        let name: String?           // tool_use
        let id: String?             // tool_use
        let tool_use_id: String?    // tool_result
    }
}

extension JSONLine.UsageStub {
    var asTokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: input_tokens ?? 0,
            outputTokens: output_tokens ?? 0,
            cacheCreate: cache_creation_input_tokens ?? 0,
            cacheRead: cache_read_input_tokens ?? 0
        )
    }
}

/// Pricing for cost display. Per-million-token rates. Rough numbers — display only.
struct ModelPricing {
    let inputPerM: Double
    let outputPerM: Double
    let cacheCreateMultiplier: Double  // applied to inputPerM
    let cacheReadMultiplier: Double    // applied to inputPerM

    static func forModel(_ model: String?) -> ModelPricing {
        let m = (model ?? "").lowercased()
        if m.contains("opus") {
            return ModelPricing(inputPerM: 15, outputPerM: 75, cacheCreateMultiplier: 1.25, cacheReadMultiplier: 0.10)
        }
        if m.contains("haiku") {
            return ModelPricing(inputPerM: 1, outputPerM: 5, cacheCreateMultiplier: 1.25, cacheReadMultiplier: 0.10)
        }
        // Default to Sonnet pricing
        return ModelPricing(inputPerM: 3, outputPerM: 15, cacheCreateMultiplier: 1.25, cacheReadMultiplier: 0.10)
    }

    func cost(for usage: TokenUsage) -> Double {
        let inputCost = Double(usage.inputTokens) / 1_000_000 * inputPerM
        let cacheCreateCost = Double(usage.cacheCreate) / 1_000_000 * inputPerM * cacheCreateMultiplier
        let cacheReadCost = Double(usage.cacheRead) / 1_000_000 * inputPerM * cacheReadMultiplier
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerM
        return inputCost + cacheCreateCost + cacheReadCost + outputCost
    }
}
