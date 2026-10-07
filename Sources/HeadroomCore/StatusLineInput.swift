import Foundation

/// The subset of Claude Code's status line JSON that Headroom reads.
/// https://code.claude.com/docs/en/statusline — every field is optional because
/// Claude Code omits several until the session's first API response.
public struct StatusLineInput: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public var id: String?
        public var displayName: String?
    }

    public struct Workspace: Decodable, Sendable {
        public var currentDir: String?
        public var projectDir: String?
    }

    public struct Cost: Decodable, Sendable {
        public var totalCostUsd: Double?
    }

    public struct ContextWindow: Decodable, Sendable {
        public var usedPercentage: Double?
    }

    public struct Window: Decodable, Sendable {
        public var usedPercentage: Double?
        public var resetsAt: Double?
    }

    public struct RateLimits: Decodable, Sendable {
        public var fiveHour: Window?
        public var sevenDay: Window?
    }

    public struct PromptCache: Decodable, Sendable {
        public struct MissCause: Decodable, Sendable {
            public var causes: [String]?
        }

        public var warm: Bool?
        public var expiresAt: Double?
        public var recacheTokensIfCold: Double?
        public var hitRatio: Double?
        public var misses: Int?
        public var lastMissAt: Double?
        public var lastMissCause: MissCause?
    }

    public var sessionId: String?
    public var sessionName: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var workspace: Workspace?
    public var model: Model?
    public var cost: Cost?
    public var contextWindow: ContextWindow?
    public var rateLimits: RateLimits?
    public var promptCache: PromptCache?

    public static func decode(_ data: Data) throws -> StatusLineInput {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StatusLineInput.self, from: data)
    }
}
