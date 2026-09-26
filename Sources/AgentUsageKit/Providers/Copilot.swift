// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// GitHub Copilot's premium-request (AI credit) and chat quotas, from the
/// same internal endpoint the editors use.
public enum CopilotProvider {
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    public struct Account: Equatable, Sendable {
        public let id: String
        public let label: String
        public let token: String
    }

    /// Tokens from, in order: the one set in Settings, the GitHub CLI, and
    /// GITHUB_TOKEN / GH_TOKEN from your login shell. The same token found
    /// twice is one account.
    public static func accounts(_ env: UsageEnvironment, manualToken: String) async -> [Account] {
        var accounts: [Account] = []
        func add(_ id: String, _ label: String, _ token: String?) {
            guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
                  !accounts.contains(where: { $0.token == token }) else { return }
            accounts.append(Account(id: id, label: label, token: token))
        }
        add("copilot-manual", "Token", manualToken)
        async let cli = ghToken(env)
        async let shell = shellTokens(env)
        let (cliToken, shellTokens) = await (cli, shell)
        add("copilot-gh-cli", "GitHub CLI", cliToken)
        add("copilot-github-env", "GITHUB_TOKEN", shellTokens.github)
        add("copilot-gh-env", "GH_TOKEN", shellTokens.gh)
        return accounts
    }

    /// Apps opened from the Dock don't get the shell's PATH, so gh is looked
    /// for where installers put it.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static func ghToken(_ env: UsageEnvironment) async -> String? {
        for path in ghCandidates where FileManager.default.isExecutableFile(atPath: path) {
            if let token = try? await env.run(path, ["auth", "token"], false) {
                return token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static let markers = (github: ("__GITHUB_TOKEN_START__", "__GITHUB_TOKEN_END__"), gh: ("__GH_TOKEN_START__", "__GH_TOKEN_END__"))

    /// GITHUB_TOKEN and GH_TOKEN as an interactive login shell sets them.
    static func shellTokens(_ env: UsageEnvironment) async -> (github: String?, gh: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "printf '\(markers.github.0)%s\(markers.github.1)\\n' \"$GITHUB_TOKEN\"; printf '\(markers.gh.0)%s\(markers.gh.1)\\n' \"$GH_TOKEN\""
        guard let output = try? await env.run(shell, ["-ilc", script], false) else { return (nil, nil) }
        return (marked(output, markers.github), marked(output, markers.gh))
    }

    static func marked(_ output: String, _ marker: (String, String)) -> String? {
        guard let start = output.range(of: marker.0, options: .backwards),
              let end = output.range(of: marker.1, range: start.upperBound..<output.endIndex) else { return nil }
        let value = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func fetch(_ env: UsageEnvironment, manualToken: String) async -> [AgentReport] {
        let accounts = await accounts(env, manualToken: manualToken)
        guard !accounts.isEmpty else {
            return [AgentReport(agent: .copilot, error: .notConfigured(
                "No GitHub token found. Sign in with 'gh auth login', set GH_TOKEN or GITHUB_TOKEN, or add a token in Settings."))]
        }
        let labelled = accounts.count > 1
        var reports: [AgentReport] = []
        for account in accounts {
            reports.append(await fetch(account, env, label: labelled ? account.label : nil))
        }
        return reports
    }

    static func fetch(_ account: Account, _ env: UsageEnvironment, label: String?) async -> AgentReport {
        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.setValue("token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        do {
            let (data, response) = try await env.fetch(request)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AgentError.expired("Copilot token expired or invalid. Sign in again with 'gh auth login' or update the token in Settings.")
            }
            guard (200..<300).contains(response.statusCode) else { throw AgentError.http(response.statusCode) }
            return try parse(data, id: account.id, label: label, now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .copilot, id: account.id, account: label, error: error)
        } catch {
            return AgentReport(agent: .copilot, id: account.id, account: label, error: .network(error.localizedDescription))
        }
    }

    static func percentRemaining(_ snapshot: [String: Any]?) -> Int? {
        guard let snapshot else { return nil }
        if let direct = JSON.number(snapshot["percent_remaining"]) { return UsageFormat.clampPercent(direct) }
        if let entitlement = JSON.number(snapshot["entitlement"]), entitlement > 0, let remaining = JSON.number(snapshot["remaining"]) {
            return UsageFormat.clampPercent(remaining / entitlement * 100)
        }
        return nil
    }

    /// `limited_user_quotas` holds what's left of the month, not what's used.
    static func fromMonthly(_ monthly: Any?, _ limited: Any?) -> Int? {
        guard let monthly = JSON.number(monthly), monthly > 0, let limited = JSON.number(limited) else { return nil }
        return UsageFormat.clampPercent(limited / monthly * 100)
    }

    static func formatPlan(_ plan: String?) -> String {
        let parts = (plan ?? "").split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard !parts.isEmpty else { return "Unknown" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    static func parse(_ data: Data, id: String = "copilot", label: String? = nil, now: Date = Date()) throws -> AgentReport {
        guard let body = JSON.object(data) else { throw AgentError.parse("Invalid Copilot API response format") }
        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"] as? [String: Any]
        let monthly = body["monthly_quotas"] as? [String: Any]
        let limited = body["limited_user_quotas"] as? [String: Any]

        let creditsPercent = percentRemaining(premium) ?? fromMonthly(monthly?["completions"], limited?["completions"])
        let entitlement = JSON.number(premium?["entitlement"]) ?? JSON.number(monthly?["completions"])
        let remaining = JSON.number(premium?["remaining"]) ?? JSON.number(limited?["completions"])
        let chatPercent = percentRemaining(snapshots?["chat"] as? [String: Any]) ?? fromMonthly(monthly?["chat"], limited?["chat"])
        guard creditsPercent != nil || chatPercent != nil else {
            throw AgentError.parse("Copilot usage response does not contain usable quota data.")
        }

        let reset = UsageFormat.parseDate(body["quota_reset_date"])
        var windows: [UsageWindow] = []
        if let creditsPercent {
            var note: String?
            if let remaining {
                note = entitlement.map { "\(UsageFormat.amount(remaining)) / \(UsageFormat.amount($0)) credits" }
                    ?? "\(UsageFormat.amount(remaining)) credits"
            }
            windows.append(UsageWindow(label: "AI Credits", percentRemaining: creditsPercent, resetsAt: reset, note: note))
        }
        if let chatPercent {
            windows.append(UsageWindow(label: "Chat", percentRemaining: chatPercent, resetsAt: reset))
        }
        return AgentReport(agent: .copilot, id: id, account: label, plan: formatPlan(JSON.string(body["copilot_plan"])),
                           headline: creditsPercent ?? chatPercent, groups: [UsageGroup(windows: windows)], fetchedAt: now)
    }
}
