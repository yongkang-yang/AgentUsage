// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// OpenCode Go's rolling (5-hour), weekly and monthly usage, from the
/// console API the Go page itself calls. One report per workspace, each
/// signed in with the console's session cookie.
public enum OpenCodeGoProvider {
    static let apiURL = URL(string: "https://opencode.ai/console/api")!
    static let sessionCookie = "__Host-console_session"

    public static func fetch(_ env: UsageEnvironment, workspaceIDs: String, cookie: String) async -> [AgentReport] {
        let workspaces = parseWorkspaces(workspaceIDs)
        let header = cookieHeader(cookie)
        guard !workspaces.isEmpty, let header else {
            return [AgentReport(agent: .opencodeGo, error: .notConfigured(
                "Add your OpenCode workspace IDs and the console session cookie in Settings."))]
        }
        let names = await workspaceNames(env, cookie: header)
        let labelled = workspaces.count > 1
        var reports: [AgentReport] = []
        for workspace in workspaces {
            let label = labelled ? (names[workspace] ?? String(workspace.suffix(6))) : nil
            reports.append(await fetch(env, workspace: workspace, cookie: header, label: label))
        }
        return reports
    }

    /// Workspace IDs, one per line or comma; a bare ID gets its `wrk_` prefix.
    static func parseWorkspaces(_ value: String) -> [String] {
        var result: [String] = []
        for entry in value.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }) {
            let id = entry.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            let full = id.hasPrefix("wrk_") ? id : "wrk_\(id)"
            if !result.contains(full) { result.append(full) }
        }
        return result
    }

    /// The session cookie's bare value, or a whole Cookie header copied from
    /// a request.
    static func cookieHeader(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.contains("=") ? trimmed : "\(sessionCookie)=\(trimmed)"
    }

    static func request(_ path: String, cookie: String, workspace: String? = nil) -> URLRequest {
        var request = URLRequest(url: apiURL.appendingPathComponent(path), timeoutInterval: 15)
        // The header carries the session; stored cookies must not replace it.
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspace { request.setValue(workspace, forHTTPHeaderField: "x-org-id") }
        return request
    }

    static let expired = AgentError("Auth Expired",
        "OpenCode's console didn't accept the session cookie. In a browser signed in to opencode.ai, copy the value of the __Host-console_session cookie (DevTools → Application → Cookies → https://opencode.ai) into Settings.")

    static func fetch(_ env: UsageEnvironment, workspace: String, cookie: String, label: String?) async -> AgentReport {
        do {
            let (data, response) = try await env.fetch(request("go/status", cookie: cookie, workspace: workspace))
            if response.statusCode == 401 { throw expired }
            if response.statusCode == 403 || response.statusCode == 404 {
                throw AgentError("No Access", "This session can't see workspace \(workspace). Check the ID in Settings.")
            }
            guard (200..<300).contains(response.statusCode) else { throw AgentError.http(response.statusCode) }
            guard let body = JSON.object(data) else { throw AgentError.parse("Invalid OpenCode Go response.") }
            return try parse(body, id: "opencode-go-\(workspace)", label: label, now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .opencodeGo, id: "opencode-go-\(workspace)", account: label, error: error)
        } catch {
            return AgentReport(agent: .opencodeGo, id: "opencode-go-\(workspace)", account: label,
                               error: .network(error.localizedDescription))
        }
    }

    /// Workspace names from the account's organisations, best effort: any
    /// object in the response carrying a `wrk_` id and a name.
    static func workspaceNames(_ env: UsageEnvironment, cookie: String) async -> [String: String] {
        guard let (data, response) = try? await env.fetch(request("orgs", cookie: cookie)), response.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var names: [String: String] = [:]
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let id = JSON.string(object["id"]), id.hasPrefix("wrk_"), let name = JSON.string(object["name"]) {
                    names[id] = name
                }
                object.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        return names
    }

    static let products = ["go": "Go", "go-plus": "Go Plus"]

    /// Amounts arrive as micro-cents in strings (they're BigInts in the console).
    static func microCents(_ value: Any?) -> Double? { JSON.number(value) }

    static func parse(_ body: [String: Any], id: String = "opencode-go", label: String? = nil, now: Date = Date()) throws -> AgentReport {
        let plan = JSON.string(body["product"]).map { products[$0] ?? $0 }
        guard let access = body["access"] as? [String: Any], let meters = access["meters"] as? [String: Any] else {
            throw AgentError("No Subscription", "This workspace has no active OpenCode Go subscription.")
        }
        let endsAt = UsageFormat.parseDate(access["endsAt"])
        func window(_ label: String, _ key: String, reset: Date?) -> UsageWindow? {
            guard let meter = meters[key] as? [String: Any], let limit = microCents(meter["limitMicroCents"]),
                  let used = microCents(meter["usedMicroCents"]) else { return nil }
            let percentUsed = limit > 0 ? used / limit * 100 : 0
            return UsageWindow(label: label, percentRemaining: UsageFormat.clampPercent(100 - percentUsed), resetsAt: reset,
                               note: String(format: "$%.2f / $%.2f", used / 1e8, limit / 1e8))
        }
        let fiveHour = meters["fiveHour"] as? [String: Any]
        let week = meters["week"] as? [String: Any]
        let windows = [
            window("Rolling (5h)", "fiveHour", reset: UsageFormat.parseDate(fiveHour?["resetsAt"])),
            window("Weekly", "week", reset: UsageFormat.parseDate(week?["resetsAt"])),
            window("Monthly", "month", reset: endsAt),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw AgentError.parse("OpenCode Go reported no usage meters.") }

        var details: [String] = []
        if let endsAt {
            let cancelling = access["cancelAtPeriodEnd"] as? Bool ?? body["cancelAtPeriodEnd"] as? Bool ?? false
            details.append("\(cancelling ? "Ends" : "Renews") \(endsAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return AgentReport(agent: .opencodeGo, id: id, account: label, plan: plan,
                           headline: windows.map(\.percentRemaining).min(), groups: [UsageGroup(windows: windows)],
                           details: details, fetchedAt: now)
    }
}
