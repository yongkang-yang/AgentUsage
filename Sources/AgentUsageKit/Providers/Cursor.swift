// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Cursor's plan usage from cursor.com's dashboard API, signed in with the
/// session Cursor.app keeps, or a Cookie header pasted in Settings.
public enum CursorProvider {
    static let baseURL = URL(string: "https://cursor.com")!
    static let stateDatabase = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    struct Credential {
        let cookieHeader: String
        let userID: String?
    }

    public static func fetch(_ env: UsageEnvironment, manualCookie: String) async -> AgentReport {
        do {
            guard let credential = try await credential(env, manualCookie: manualCookie) else {
                throw AgentError.notConfigured("Sign in to Cursor.app, or paste a cursor.com Cookie header in Settings.")
            }
            async let summary = get("/api/usage-summary", credential, env)
            async let me = try? get("/api/auth/me", credential, env)
            let (summaryData, meData) = try await (summary, me)
            let user = meData.flatMap(JSON.object)
            var requests: [String: Any]?
            if let userID = JSON.string(user?["sub"]) ?? credential.userID {
                requests = (try? await get("/api/usage", credential, env, query: [URLQueryItem(name: "user", value: userID)]))
                    .flatMap(JSON.object)
            }
            guard let summaryBody = JSON.object(summaryData) else { throw AgentError.parse("Missing usage summary") }
            return parse(summary: summaryBody, user: user, requests: requests, now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .cursor, error: error)
        } catch {
            return AgentReport(agent: .cursor, error: .network(error.localizedDescription))
        }
    }

    // MARK: Credentials

    static func credential(_ env: UsageEnvironment, manualCookie: String) async throws -> Credential? {
        let manual = manualCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return Credential(cookieHeader: manual, userID: nil) }
        let database = env.home.appendingPathComponent(stateDatabase).path
        guard FileManager.default.fileExists(atPath: database),
              let token = try? await env.run("/usr/bin/sqlite3",
                                             ["-readonly", database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"],
                                             false)
        else { return nil }
        return session(fromAccessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), now: env.now())
    }

    /// Cursor.app's access token becomes the dashboard's session cookie:
    /// `WorkosCursorSessionToken=<user>%3A%3A<token>`. A token that expires
    /// within a minute is treated as missing.
    static func session(fromAccessToken token: String, now: Date) -> Credential? {
        guard let payload = decodeJWTPayload(token), let expiry = JSON.number(payload["exp"]),
              expiry - now.timeIntervalSince1970 > 60,
              let userID = JSON.string(payload["sub"])?.split(separator: "|").last.map(String.init),
              userID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        else { return nil }
        return Credential(cookieHeader: "WorkosCursorSessionToken=\(userID)%3A%3A\(token)", userID: userID)
    }

    static func get(_ path: String, _ credential: Credential, _ env: UsageEnvironment, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        let (data, response) = try await env.fetch(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw AgentError.expired("Cursor session expired or invalid. Open Cursor and sign in again, or paste a new Cookie header in Settings.")
        }
        guard (200..<300).contains(response.statusCode) else { throw AgentError.http(response.statusCode) }
        return data
    }

    // MARK: Parsing

    static func plan(_ membership: String?) -> String {
        guard let membership, !membership.isEmpty else { return "Unknown" }
        return membership.prefix(1).uppercased() + membership.dropFirst()
    }

    static func parse(summary: [String: Any], user: [String: Any]?, requests: [String: Any]?, now: Date) -> AgentReport {
        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let planUsage = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]
        let reset = UsageFormat.parseDate(summary["billingCycleEnd"])

        func percent(_ value: Any?) -> Double? { JSON.number(value).map { max(0, min(100, $0)) } }
        func ratio(_ usage: [String: Any]?) -> Double? {
            guard let used = JSON.number(usage?["used"]), let limit = JSON.number(usage?["limit"]), limit > 0 else { return nil }
            return max(0, min(100, used / limit * 100))
        }
        let autoUsed = percent(planUsage?["autoPercentUsed"])
        let apiUsed = percent(planUsage?["apiPercentUsed"])
        let totalUsed = percent(planUsage?["totalPercentUsed"]) ?? ratio(planUsage) ?? apiUsed ?? autoUsed
            ?? ratio(overall) ?? ratio(pooled) ?? 0

        // Older plans count requests instead of spend.
        let legacy = requests?["gpt-4"] as? [String: Any]
        var legacyWindow: UsageWindow?
        if let used = JSON.number(legacy?["numRequestsTotal"]) ?? JSON.number(legacy?["numRequests"]),
           let limit = JSON.number(legacy?["maxRequestUsage"]), limit > 0 {
            legacyWindow = UsageWindow(label: "Requests", percentRemaining: UsageFormat.clampPercent(100 - used / limit * 100),
                                       resetsAt: reset, note: "\(Int(used)) / \(Int(limit))")
        }

        var windows: [UsageWindow] = []
        let headline: Int
        if let legacyWindow {
            windows.append(legacyWindow)
            headline = legacyWindow.percentRemaining
        } else {
            let money = [planUsage, overall, pooled].first { JSON.number($0?["limit"]).map { $0 > 0 } ?? false } ?? nil
            let note = money.flatMap { usage -> String? in
                guard let used = JSON.number(usage["used"]), let limit = JSON.number(usage["limit"]) else { return nil }
                return String(format: "$%.2f / $%.2f", used / 100, limit / 100)
            }
            windows.append(UsageWindow(label: "Total", percentRemaining: UsageFormat.clampPercent(100 - totalUsed), resetsAt: reset, note: note))
            if let autoUsed { windows.append(UsageWindow(label: "Auto", percentRemaining: UsageFormat.clampPercent(100 - autoUsed), resetsAt: reset)) }
            if let apiUsed { windows.append(UsageWindow(label: "API", percentRemaining: UsageFormat.clampPercent(100 - apiUsed), resetsAt: reset)) }
            // Auto and API are separate pools; the tighter one is what runs out first.
            let pools = [autoUsed, apiUsed].compactMap { $0 }.map { UsageFormat.clampPercent(100 - $0) }
            headline = pools.min() ?? UsageFormat.clampPercent(100 - totalUsed)
        }

        var details: [String] = []
        let onDemand = individual?["onDemand"] as? [String: Any]
        let teamOnDemand = team?["onDemand"] as? [String: Any]
        let personal = (JSON.number(onDemand?["used"]) ?? 0) / 100
        if let limit = JSON.number(onDemand?["limit"]), limit > 0 {
            details.append(String(format: "On-demand: $%.2f / $%.2f", personal, limit / 100))
        } else if let limit = JSON.number(teamOnDemand?["limit"]), limit > 0 {
            let used = (JSON.number(teamOnDemand?["used"]) ?? 0) / 100
            details.append(String(format: "Team on-demand: $%.2f / $%.2f", used, limit / 100)
                           + (personal > 0 ? String(format: " (yours $%.2f)", personal) : ""))
        } else if personal > 0 {
            details.append(String(format: "On-demand: $%.2f", personal))
        }
        if let email = JSON.string(user?["email"]) { details.append("Account: \(email)") }

        return AgentReport(agent: .cursor, plan: plan(JSON.string(summary["membershipType"])), headline: headline,
                           groups: [UsageGroup(windows: windows)], details: details, fetchedAt: now)
    }
}
