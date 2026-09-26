// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Codex's ChatGPT-plan rate limits, for every login found in a Codex home:
/// the active `auth.json` and any saved under `accounts/`.
public enum CodexProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let userSettingsURL = URL(string: "https://chatgpt.com/backend-api/wham/settings/user")!
    static let profileURL = URL(string: "https://chatgpt.com/backend-api/calpico/chatgpt/profile")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let unauthorized = "Authorization token expired or invalid. Run 'codex login' to refresh credentials."

    static let planNames = ["plus": "Plus", "pro": "Pro 20x", "prolite": "Pro 5x", "team": "Team", "business": "Business",
                            "enterprise": "Enterprise", "free": "Free", "edu": "Edu"]

    public struct Account: Equatable, Sendable {
        public let id: String
        public let label: String
        public let token: String
        public let accountID: String?
        public let userID: String?
    }

    /// `additionalHomes` are extra Codex home directories, one per line or comma.
    public static func fetch(_ env: UsageEnvironment, additionalHomes: String = "") async -> [AgentReport] {
        var homes = [env.home.appendingPathComponent(".codex")]
        homes += parseHomes(additionalHomes, home: env.home)
        var accounts: [Account] = []
        var seen: Set<String> = []
        for (index, home) in homes.enumerated() {
            for account in discoverAccounts(in: home, prefix: index == 0 ? "codex" : "codex-home\(index)") {
                let keys = dedupeKeys(account)
                if keys.contains(where: seen.contains) { continue }
                seen.formUnion(keys)
                accounts.append(account)
            }
        }
        guard !accounts.isEmpty else {
            return [AgentReport(agent: .codex, error: .notConfigured("Codex login not found. Run 'codex login'."))]
        }
        let labelled = accounts.count > 1
        return await withTaskGroup(of: (Int, AgentReport).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask { (index, await fetch(account, env, labelled: labelled)) }
            }
            var reports: [(Int, AgentReport)] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Accounts

    static func parseHomes(_ value: String, home: URL) -> [URL] {
        var result: [URL] = []
        for entry in value.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let path = trimmed == "~" ? home.path : trimmed.hasPrefix("~/") ? home.path + trimmed.dropFirst(1) : trimmed
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    static func dedupeKeys(_ account: Account) -> [String] {
        var keys = ["token:\(account.token)"]
        if let user = account.userID, let id = account.accountID { keys.insert("user-account:\(user):\(id)", at: 0) }
        return keys
    }

    struct Login {
        var token: String?
        var accountID: String?
        var userID: String?
        var displayName: String?
    }

    static func readLogin(_ url: URL) -> Login {
        guard let data = FileManager.default.contents(atPath: url.path), let body = JSON.object(data) else { return Login() }
        let tokens = body["tokens"] as? [String: Any]
        var login = Login(token: JSON.string(tokens?["access_token"]),
                          accountID: JSON.string(tokens?["account_id"]) ?? JSON.string(tokens?["accountId"]))
        if let idToken = JSON.string(tokens?["id_token"]), let claims = decodeJWTPayload(idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            login.userID = JSON.string(auth?["user_id"]) ?? JSON.string(auth?["chatgpt_user_id"])
            login.displayName = JSON.string(claims["name"]) ?? JSON.string(claims["email"])
        }
        return login
    }

    static func discoverAccounts(in home: URL, prefix: String) -> [Account] {
        var accounts: [Account] = []
        let active = readLogin(home.appendingPathComponent("auth.json"))
        if let token = active.token {
            accounts.append(Account(id: "\(prefix)-active", label: active.displayName ?? "Active", token: token,
                                    accountID: active.accountID, userID: active.userID))
        }
        let directory = home.appendingPathComponent("accounts")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".auth.json") }.sorted()
        for file in files {
            let login = readLogin(directory.appendingPathComponent(file))
            let stem = String(file.dropLast(".auth.json".count))
            // Saved accounts are named base64url("<user>::<account>").auth.json.
            var storedUser: String?, storedAccount: String?
            if let decoded = base64URLDecode(stem).map({ String(decoding: $0, as: UTF8.self) }),
               let separator = decoded.range(of: "::") {
                storedUser = String(decoded[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                storedAccount = String(decoded[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard let token = login.token, let accountID = login.accountID ?? storedAccount, !accountID.isEmpty else { continue }
            let userID = login.userID ?? storedUser
            let fallback = stem.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            accounts.append(Account(id: "\(prefix)-\(stem)", label: login.displayName ?? userID ?? (fallback.isEmpty ? accountID : fallback),
                                    token: token, accountID: accountID, userID: userID))
        }
        return accounts
    }

    // MARK: Fetching

    static func request(_ url: URL, _ account: Account, timeout: TimeInterval, extra: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(account.token.hasPrefix("Bearer ") ? account.token : "Bearer \(account.token)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let id = account.accountID, !id.isEmpty { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-ID") }
        for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func fetch(_ account: Account, _ env: UsageEnvironment, labelled: Bool) async -> AgentReport {
        let label = labelled ? account.label : nil
        do {
            let (data, response) = try await env.fetch(request(usageURL, account, timeout: 10))
            if response.statusCode == 401 { throw AgentError.expired(unauthorized) }
            guard (200..<300).contains(response.statusCode) else { throw AgentError.http(response.statusCode) }
            async let credits = resetCredits(account, env)
            async let name = displayName(account, env)
            let (resetCredits, displayName) = await (credits, name)
            return try parse(data, account: account, label: labelled ? (displayName ?? account.label) : nil,
                             resetCredits: resetCredits, now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .codex, id: account.id, account: label, error: error)
        } catch {
            return AgentReport(agent: .codex, id: account.id, account: label, error: .network(error.localizedDescription))
        }
    }

    /// Available reset credits, or nil when the endpoint has nothing usable.
    static func resetCredits(_ account: Account, _ env: UsageEnvironment) async -> (count: Int, expiries: [Date])? {
        let request = request(resetCreditsURL, account, timeout: 4, extra: ["OpenAI-Beta": "codex-1", "originator": "Codex Desktop"])
        guard let (data, response) = try? await env.fetch(request), response.statusCode == 200,
              let body = JSON.object(data), let count = JSON.number(body["available_count"]), count >= 0 else { return nil }
        let now = env.now()
        let expiries = (body["credits"] as? [[String: Any]] ?? [])
            .filter { $0["status"] as? String == "available" }
            .compactMap { UsageFormat.parseDate($0["expires_at"]) }
            .filter { $0 > now }.sorted()
        return (Int(count), expiries)
    }

    static func displayName(_ account: Account, _ env: UsageEnvironment) async -> String? {
        guard let (data, response) = try? await env.fetch(request(userSettingsURL, account, timeout: 2.5)),
              response.statusCode == 200, let userID = JSON.string(JSON.object(data)?["user_id"]) else { return nil }
        let url = profileURL.appendingPathComponent(userID)
        guard let (profile, profileResponse) = try? await env.fetch(request(url, account, timeout: 2.5)),
              profileResponse.statusCode == 200 else { return nil }
        return JSON.string(JSON.object(profile)?["display_name"])
    }

    // MARK: Parsing

    struct RateWindow {
        let usedPercent: Double
        let windowSeconds: Double
        let resetAfter: Double?
        let resetAt: Double?
    }

    static func rateWindow(_ value: Any?) -> RateWindow? {
        guard let window = value as? [String: Any], let used = JSON.number(window["used_percent"]),
              let seconds = JSON.number(window["limit_window_seconds"]), seconds > 0 else { return nil }
        return RateWindow(usedPercent: used, windowSeconds: seconds, resetAfter: JSON.number(window["reset_after_seconds"]),
                          resetAt: JSON.number(window["reset_at"]))
    }

    static func usageWindow(_ label: String, _ window: RateWindow, now: Date) -> UsageWindow {
        let reset: Date? = window.resetAfter.map { now.addingTimeInterval(max(0, $0.rounded(.down))) }
            ?? window.resetAt.flatMap { UsageFormat.parseDate($0) }
        return UsageWindow(label: label, percentRemaining: UsageFormat.clampPercent(100 - window.usedPercent), resetsAt: reset)
    }

    /// A single window a day or shorter is the 5-hour one; anything longer is weekly.
    static func pick(_ primary: RateWindow?, _ secondary: RateWindow?, weekly: Bool) -> RateWindow? {
        if let a = primary, let b = secondary {
            return weekly ? (a.windowSeconds > b.windowSeconds ? a : b) : (a.windowSeconds <= b.windowSeconds ? a : b)
        }
        guard let only = primary ?? secondary else { return nil }
        let isShort = only.windowSeconds <= 86_400
        return weekly ? (isShort ? nil : only) : (isShort ? only : nil)
    }

    static func windowName(_ seconds: Double) -> String {
        seconds <= 86_400 ? "\(Int((seconds / 3600).rounded()))-hour" : "Weekly"
    }

    static func parse(_ data: Data, account: Account, label: String?, resetCredits: (count: Int, expiries: [Date])?,
                      now: Date) throws -> AgentReport {
        guard let body = JSON.object(data) else { throw AgentError.parse("Invalid API response format") }
        let rateLimit = body["rate_limit"] as? [String: Any]
        let primary = rateWindow(rateLimit?["primary_window"]), secondary = rateWindow(rateLimit?["secondary_window"])
        guard primary != nil || secondary != nil else { throw AgentError.parse("Missing rate limit data in API response") }

        var windows: [UsageWindow] = []
        if let short = pick(primary, secondary, weekly: false) { windows.append(usageWindow(windowName(short.windowSeconds), short, now: now)) }
        if let long = pick(primary, secondary, weekly: true) { windows.append(usageWindow("Weekly", long, now: now)) }
        if let review = rateWindow((body["code_review_rate_limit"] as? [String: Any])?["primary_window"]) {
            windows.append(usageWindow("Code Review", review, now: now))
        }
        // The binding constraint: the worst of the windows above. Credits stay
        // informational; subscription plans report a zero balance while fully usable.
        let headline = windows.map(\.percentRemaining).min() ?? 0

        var groups = [UsageGroup(windows: windows)]
        for extra in body["additional_rate_limits"] as? [[String: Any]] ?? [] {
            guard let name = JSON.string(extra["limit_name"]) else { continue }
            let limit = extra["rate_limit"] as? [String: Any]
            let extraWindows = [rateWindow(limit?["primary_window"]), rateWindow(limit?["secondary_window"])]
                .compactMap { $0 }.map { usageWindow(windowName($0.windowSeconds), $0, now: now) }
            if !extraWindows.isEmpty { groups.append(UsageGroup(title: name, windows: extraWindows)) }
        }

        var details: [String] = []
        let credits = body["credits"] as? [String: Any]
        if credits?["unlimited"] as? Bool == true {
            details.append("Credits: unlimited")
        } else if credits?["has_credits"] as? Bool == true {
            details.append("Credits: \(JSON.string(credits?["balance"]) ?? "0")")
        }
        if let resetCredits, resetCredits.count > 0 {
            var line = "Rate-limit reset credits: \(resetCredits.count)"
            if let next = resetCredits.expiries.first {
                line += " (next expires \(next.formatted(date: .abbreviated, time: .omitted)))"
            }
            details.append(line)
        }

        let planKey = JSON.string(body["plan_type"])?.lowercased()
        let plan = planKey.map { planNames[$0] ?? JSON.string(body["plan_type"])! } ?? "Unknown"
        return AgentReport(agent: .codex, id: account.id, account: label, plan: plan, headline: headline,
                           groups: groups, details: details, fetchedAt: now)
    }
}
