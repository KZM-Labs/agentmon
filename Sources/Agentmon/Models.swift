import Foundation

enum SessionState: String {
    case active   // activity within last 30s
    case idle     // 30s–5min
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
    }

    struct UsageStub: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
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
