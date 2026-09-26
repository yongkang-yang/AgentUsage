// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import Dispatch
import Foundation

/// The agents this app tracks, in the order they are listed.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, copilot, antigravity, opencodeGo

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        case .opencodeGo: "OpenCode Go"
        }
    }

    /// The SVG in Resources/AgentIcons. Monochrome ones have an @dark twin.
    public var iconName: String {
        switch self {
        case .claude: "claude-icon"
        case .codex: "codex-icon"
        case .copilot: "copilot-icon"
        case .antigravity: "antigravity-icon"
        case .opencodeGo: "opencode-go-icon"
        }
    }
}

/// One quota: how much is left and when it resets.
public struct UsageWindow: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    /// 0–100.
    public let percentRemaining: Int
    public let resetsAt: Date?
    /// Extra facts about the window, e.g. "120 / 300 credits".
    public let note: String?

    public init(label: String, percentRemaining: Int, resetsAt: Date? = nil, note: String? = nil) {
        self.label = label
        self.percentRemaining = max(0, min(100, percentRemaining))
        self.resetsAt = resetsAt
        self.note = note
    }
}

/// Windows that belong together, e.g. one of Antigravity's quota groups.
public struct UsageGroup: Equatable, Sendable, Identifiable {
    public var id: String { title ?? "" }
    public let title: String?
    public let windows: [UsageWindow]

    public init(title: String? = nil, windows: [UsageWindow]) {
        self.title = title
        self.windows = windows
    }
}

/// Why an agent has no numbers, in a word for the row and a sentence for the detail.
public struct AgentError: Error, Equatable, Sendable, LocalizedError {
    public let label: String
    public let message: String

    public init(_ label: String, _ message: String) {
        self.label = label
        self.message = message
    }

    public var errorDescription: String? { message }

    static func notConfigured(_ message: String) -> AgentError { AgentError("Not Configured", message) }
    static func expired(_ message: String) -> AgentError { AgentError("Token Expired", message) }
    static func network(_ message: String) -> AgentError { AgentError("Network Error", message) }
    static func parse(_ message: String) -> AgentError { AgentError("Error", message) }
    static func http(_ status: Int) -> AgentError {
        AgentError("Error", "HTTP \(status): \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)")
    }
}

/// One agent account's usage, or why it couldn't be read.
public struct AgentReport: Equatable, Sendable, Identifiable {
    public let id: String
    public let agent: AgentKind
    /// Set when the agent has several accounts.
    public let account: String?
    public let plan: String?
    /// The binding constraint, shown beside the name: the lowest window that
    /// limits what the account can actually spend.
    public let headline: Int?
    public let groups: [UsageGroup]
    public let details: [String]
    public let error: AgentError?
    public let fetchedAt: Date

    public init(agent: AgentKind, id: String? = nil, account: String? = nil, plan: String? = nil, headline: Int?,
                groups: [UsageGroup], details: [String] = [], fetchedAt: Date = Date()) {
        self.id = id ?? agent.rawValue
        self.agent = agent
        self.account = account
        self.plan = plan
        self.headline = headline.map { max(0, min(100, $0)) }
        self.groups = groups
        self.details = details
        self.error = nil
        self.fetchedAt = fetchedAt
    }

    public init(agent: AgentKind, id: String? = nil, account: String? = nil, error: AgentError, fetchedAt: Date = Date()) {
        self.id = id ?? agent.rawValue
        self.agent = agent
        self.account = account
        self.plan = nil
        self.headline = nil
        self.groups = []
        self.details = []
        self.error = error
        self.fetchedAt = fetchedAt
    }

    public var title: String { account.map { "\(agent.name) · \($0)" } ?? agent.name }
}

/// What the providers need from the outside world, so tests can stand in for it.
public struct UsageEnvironment: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Runs a tool and returns its standard output (and standard error, when
    /// asked), or throws on a non-zero exit or timeout.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ mergeStandardError: Bool) async throws -> String

    public var transport: Transport
    public var run: Runner
    public var home: URL
    public var now: @Sendable () -> Date

    public init(transport: @escaping Transport, run: @escaping Runner, home: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.run = run
        self.home = home
        self.now = now
    }

    public static let live = UsageEnvironment(
        transport: { try await URLSession.shared.data(for: $0) },
        run: { try await ProcessRunner.run($0, $1, mergeStandardError: $2) },
        home: FileManager.default.homeDirectoryForCurrentUser
    )

    func readFile(_ relative: String) -> Data? {
        FileManager.default.contents(atPath: home.appendingPathComponent(relative).path)
    }

    /// GET or POST with a timeout, mapping transport failures to a network error.
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.network("No HTTP response.") }
            return (data, http)
        } catch let error as AgentError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AgentError.network("Request timeout. Please check your network connection.")
        } catch {
            throw AgentError.network(error.localizedDescription)
        }
    }
}

public enum ProcessRunner {
    public struct Failed: Error {}

    public static func run(_ executable: String, _ arguments: [String], mergeStandardError: Bool = false,
                           timeout: TimeInterval = 8) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = mergeStandardError ? output : FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            // Drain while it runs, so a long output can't fill the pipe and stall it.
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    continuation.resume(throwing: Failed())
                }
            }
        }
    }
}
