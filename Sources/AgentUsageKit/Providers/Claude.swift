// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Claude Code's subscription limits, from the OAuth usage endpoint, with the
/// token Claude Code itself stores after `claude` login.
public enum ClaudeProvider {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let keychainService = "Claude Code-credentials"
    static let credentialsFile = ".claude/.credentials.json"

    struct Credentials {
        enum Source { case file(URL), keychain(account: String?) }
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Double?
        var rateLimitTier: String?
        var subscriptionType: String?
        var source: Source
        /// The whole stored document, so a refreshed token is written back
        /// without losing anything else in it.
        var raw: [String: Any]
    }

    public static func fetch(_ env: UsageEnvironment) async -> AgentReport {
        do {
            var credentials = try await readCredentials(env)
            let now = env.now().timeIntervalSince1970 * 1000
            if let expiresAt = credentials.expiresAt, now >= expiresAt - 60_000 {
                try? await refresh(&credentials, env)
            }
            var (data, response) = try await env.fetch(usageRequest(credentials.accessToken))
            if response.statusCode == 401, credentials.refreshToken != nil {
                if (try? await refresh(&credentials, env)) != nil {
                    (data, response) = try await env.fetch(usageRequest(credentials.accessToken))
                }
            }
            return try parse(data: data, status: response.statusCode, credentials: credentials, now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .claude, error: error)
        } catch {
            return AgentReport(agent: .claude, error: .network(error.localizedDescription))
        }
    }

    // MARK: Credentials

    static func readCredentials(_ env: UsageEnvironment) async throws -> Credentials {
        if let data = env.readFile(credentialsFile), let parsed = parseStored(data),
           JSON.string((parsed["claudeAiOauth"] as? [String: Any])?["accessToken"]) != nil {
            return try extract(parsed, source: .file(env.home.appendingPathComponent(credentialsFile)))
        }
        // Claude Code keeps its login in the keychain on macOS. Reading it
        // through `security` (as the Raycast extension did) keeps the
        // keychain's access list pointing at that tool, not at this app.
        if let stored = try? await env.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], false),
           let parsed = parseStored(Data(stored.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
           JSON.string((parsed["claudeAiOauth"] as? [String: Any])?["accessToken"]) != nil {
            let attributes = try? await env.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-g"], true)
            let account = attributes.flatMap { firstMatch(#""acct"<blob>="([^"\n]*)""#, in: $0) }
            return try extract(parsed, source: .keychain(account: account))
        }
        throw AgentError.notConfigured("Claude CLI not configured. Run 'claude' to authenticate.")
    }

    /// JSON, or JSON written out as hex (as `security -w` prints values with newlines).
    static func parseStored(_ data: Data) -> [String: Any]? {
        if let object = JSON.object(data) { return object }
        var hex = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return JSON.object(bytes)
    }

    static func extract(_ parsed: [String: Any], source: Credentials.Source) throws -> Credentials {
        let oauth = parsed["claudeAiOauth"] as? [String: Any] ?? [:]
        var token = JSON.string(oauth["accessToken"]) ?? ""
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !token.isEmpty else { throw AgentError.notConfigured("Claude OAuth token missing. Run 'claude' to authenticate.") }
        let scopes = oauth["scopes"] as? [String] ?? []
        guard scopes.contains("user:profile") else {
            throw AgentError("Missing Scope", "Claude OAuth token missing 'user:profile' scope. Run 'claude setup-token'.")
        }
        return Credentials(
            accessToken: token,
            refreshToken: JSON.string(oauth["refreshToken"]),
            expiresAt: JSON.number(oauth["expiresAt"]),
            rateLimitTier: JSON.string(oauth["rateLimitTier"]) ?? JSON.string(oauth["rate_limit_tier"]),
            subscriptionType: JSON.string(oauth["subscriptionType"]) ?? JSON.string(oauth["subscription_type"]),
            source: source,
            raw: parsed)
    }

    /// Refreshes the access token and writes it back where Claude Code keeps
    /// it, so both stay in step.
    static func refresh(_ credentials: inout Credentials, _ env: UsageEnvironment) async throws {
        guard let refreshToken = credentials.refreshToken else { throw AgentError.expired("No refresh token.") }
        var request = URLRequest(url: refreshURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: refreshToken),
                           URLQueryItem(name: "client_id", value: clientID)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await env.fetch(request)
        guard response.statusCode == 200, let body = JSON.object(data), let access = JSON.string(body["access_token"]),
              let expiresIn = JSON.number(body["expires_in"]) else { throw AgentError.expired("Refresh failed.") }

        var oauth = credentials.raw["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = access
        oauth["refreshToken"] = JSON.string(body["refresh_token"]) ?? refreshToken
        oauth["expiresAt"] = Int(env.now().timeIntervalSince1970 * 1000 + expiresIn * 1000)
        credentials.raw["claudeAiOauth"] = oauth
        credentials.accessToken = access
        credentials.refreshToken = oauth["refreshToken"] as? String
        credentials.expiresAt = JSON.number(oauth["expiresAt"])

        switch credentials.source {
        case let .file(url):
            if let data = try? JSONSerialization.data(withJSONObject: credentials.raw, options: [.prettyPrinted, .sortedKeys]) {
                try? (data + Data("\n".utf8)).write(to: url, options: .atomic)
            }
        case let .keychain(account?):
            // Minified: `security -w` hex-encodes values with newlines, which
            // Claude Code can't read back.
            if let data = try? JSONSerialization.data(withJSONObject: credentials.raw) {
                _ = try? await env.run("/usr/bin/security",
                                       ["add-generic-password", "-U", "-a", account, "-s", keychainService,
                                        "-w", String(decoding: data, as: UTF8.self)], false)
            }
        case .keychain(nil):
            break
        }
    }

    static func usageRequest(_ token: String) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    // MARK: Parsing

    static func plan(tier: String?, subscription: String?) -> String {
        for value in [subscription, tier] {
            let lower = (value ?? "").lowercased()
            if lower.contains("max") { return "Max" }
            if lower.contains("pro") { return "Pro" }
            if lower.contains("team") { return "Team" }
            if lower.contains("enterprise") { return "Enterprise" }
        }
        return "Claude"
    }

    static func parse(data: Data, status: Int, credentials: Credentials, now: Date) throws -> AgentReport {
        if status == 401 { throw AgentError.expired("Claude token expired or invalid. Run 'claude' to re-authenticate.") }
        if status == 403 {
            if String(decoding: data, as: UTF8.self).contains("user:profile") {
                throw AgentError("Missing Scope", "Claude OAuth token does not include 'user:profile'. Run 'claude setup-token'.")
            }
            throw AgentError.expired("Claude usage endpoint rejected the token. Run 'claude' to refresh login.")
        }
        guard (200..<300).contains(status) else { throw AgentError.http(status) }
        guard let body = JSON.object(data), let fiveHour = body["five_hour"] as? [String: Any],
              let fiveUsed = JSON.number(fiveHour["utilization"]) else {
            throw AgentError.parse("Missing five_hour usage in Claude response.")
        }

        func window(_ label: String, used: Double, reset: Any?) -> UsageWindow {
            UsageWindow(label: label, percentRemaining: UsageFormat.clampPercent(100 - used), resetsAt: UsageFormat.parseDate(reset))
        }
        var windows = [window("5-hour", used: fiveUsed, reset: fiveHour["resets_at"])]
        if let week = body["seven_day"] as? [String: Any], let used = JSON.number(week["utilization"]) {
            windows.append(window("Weekly", used: used, reset: week["resets_at"]))
        }

        // Model-scoped weekly windows: seven_day_<model> keys, then the
        // structured `limits` array, which wins for the same model.
        var models: [String: UsageWindow] = [:]
        var order: [String] = []
        let skip: Set<String> = ["five_hour", "seven_day", "extra_usage", "limits", "spend", "member_dashboard_available"]
        for key in body.keys.sorted() where key.hasPrefix("seven_day_") && !skip.contains(key) {
            guard let value = body[key] as? [String: Any], let used = JSON.number(value["utilization"]) else { continue }
            let model = String(key.dropFirst("seven_day_".count))
            if !order.contains(model) { order.append(model) }
            models[model] = window("Weekly · \(modelLabel(model))", used: used, reset: value["resets_at"])
        }
        for limit in body["limits"] as? [[String: Any]] ?? [] {
            guard limit["kind"] as? String == "weekly_scoped", limit["is_active"] as? Bool != false,
                  let percent = JSON.number(limit["percent"]) else { continue }
            let scope = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
            guard let name = JSON.string(scope?["display_name"]) ?? JSON.string(scope?["id"]) else { continue }
            let model = name.lowercased()
            if !order.contains(model) { order.append(model) }
            models[model] = window("Weekly · \(modelLabel(model))", used: percent, reset: limit["resets_at"])
        }
        windows += order.compactMap { models[$0] }

        var details: [String] = []
        if let extra = body["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let limit = JSON.number(extra["monthly_limit"]), let used = JSON.number(extra["used_credits"]) {
            let currency = (JSON.string(extra["currency"]) ?? "USD").uppercased()
            details.append(String(format: "Extra usage: %@ %.2f / %.2f", currency, used / 100, limit / 100))
        }

        return AgentReport(agent: .claude, plan: plan(tier: credentials.rateLimitTier, subscription: credentials.subscriptionType),
                           headline: windows[0].percentRemaining, groups: [UsageGroup(windows: windows)],
                           details: details, fetchedAt: now)
    }

    static func modelLabel(_ model: String) -> String {
        model.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: group), in: text) else { return nil }
    return String(text[range])
}
