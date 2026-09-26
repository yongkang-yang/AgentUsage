// SPDX-License-Identifier: GPL-3.0-or-later
import AgentUsageKit
import AppKit
import Combine

/// Settings, and the latest report from every enabled agent.
@MainActor
final class UsageStore: ObservableObject {
    enum Keys {
        static func enabled(_ agent: AgentKind) -> String { "enabled.\(agent.rawValue)" }
        static let codexHomes = "codexAdditionalHomes"
        static let opencodeWorkspace = "opencodeGoWorkspaceID"
        static let refreshMinutes = "refreshMinutes"
        static let showPercent = "menuBarShowsPercent"
        static let copilotToken = "copilotToken"
        static let opencodeCookie = "opencodeGoAuthCookie"
    }

    @Published private(set) var reports: [AgentKind: [AgentReport]] = [:]
    @Published private(set) var loading: Set<AgentKind> = []
    @Published private(set) var lastRefresh: Date?
    @Published var enabled: Set<AgentKind> {
        didSet {
            for agent in AgentKind.allCases {
                UserDefaults.standard.set(enabled.contains(agent), forKey: Keys.enabled(agent))
            }
            for agent in enabled.subtracting(oldValue) { refresh(agent) }
        }
    }
    @Published var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: Keys.refreshMinutes)
            scheduleTimer()
        }
    }
    @Published var showsPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showsPercentInMenuBar, forKey: Keys.showPercent) }
    }

    private var tasks: [AgentKind: Task<Void, Never>] = [:]
    private var timer: Timer?
    private let env = UsageEnvironment.live

    /// Opening the panel re-fetches only when the numbers have had time to move.
    static let staleAfter: TimeInterval = 120

    init() {
        let defaults = UserDefaults.standard
        enabled = Set(AgentKind.allCases.filter { defaults.object(forKey: Keys.enabled($0)) as? Bool ?? true })
        let minutes = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = minutes > 0 ? minutes : 15
        showsPercentInMenuBar = defaults.object(forKey: Keys.showPercent) as? Bool ?? true
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer?.tolerance = 30
    }

    /// Every enabled agent's reports, in list order.
    var visibleReports: [AgentReport] {
        AgentKind.allCases.filter(enabled.contains).flatMap { reports[$0] ?? [] }
    }

    /// Agents still waiting for their first report.
    var pendingAgents: [AgentKind] {
        AgentKind.allCases.filter { enabled.contains($0) && reports[$0] == nil }
    }

    /// The tightest headline across every account: what the menu bar shows.
    var lowestHeadline: Int? { visibleReports.compactMap(\.headline).min() }

    var isLoading: Bool { !loading.isEmpty }

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.staleAfter, pendingAgents.isEmpty { return }
        refreshAll()
    }

    func refreshAll() {
        for agent in AgentKind.allCases where enabled.contains(agent) { refresh(agent) }
    }

    func refresh(_ agent: AgentKind) {
        guard enabled.contains(agent), tasks[agent] == nil else { return }
        loading.insert(agent)
        let env = self.env
        let defaults = UserDefaults.standard
        let codexHomes = defaults.string(forKey: Keys.codexHomes) ?? ""
        let workspace = defaults.string(forKey: Keys.opencodeWorkspace) ?? ""
        let copilotToken = Keychain.read(Keys.copilotToken)
        let cookie = Keychain.read(Keys.opencodeCookie)
        tasks[agent] = Task { [weak self] in
            let result: [AgentReport]
            switch agent {
            case .claude: result = [await ClaudeProvider.fetch(env)]
            case .codex: result = await CodexProvider.fetch(env, additionalHomes: codexHomes)
            case .copilot: result = await CopilotProvider.fetch(env, manualToken: copilotToken)
            case .antigravity: result = [await AntigravityProvider.fetch(env)]
            case .opencodeGo: result = [await OpenCodeGoProvider.fetch(env, workspaceID: workspace, authCookie: cookie)]
            }
            guard let self else { return }
            self.reports[agent] = result
            self.loading.remove(agent)
            self.tasks[agent] = nil
            self.lastRefresh = Date()
        }
    }
}
