// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// OpenCode Go's rolling, weekly and monthly usage, read from the Solid.js
/// hydration data on the workspace's Go page. There is no API, so this needs
/// the workspace ID and the browser session's `auth` cookie.
public enum OpenCodeGoProvider {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static func pageURL(workspaceID: String) -> URL? {
        let id = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = id.hasPrefix("wrk_") ? id : "wrk_\(id)"
        return URL(string: "https://opencode.ai/workspace/\(full)/go")
    }

    public static func fetch(_ env: UsageEnvironment, workspaceID: String, authCookie: String) async -> AgentReport {
        let cookie = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.trimmingCharacters(in: .whitespaces).isEmpty, !cookie.isEmpty,
              let url = pageURL(workspaceID: workspaceID) else {
            return AgentReport(agent: .opencodeGo, error: .notConfigured("Add your OpenCode workspace ID and auth cookie in Settings."))
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("auth=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await env.fetch(request)
            let expired = AgentError("Auth Expired", "opencode.ai didn't accept the auth cookie and sent the request to its login page. In a browser where the workspace's Go page opens, copy the value of the `auth` cookie for opencode.ai (not auth.opencode.ai), and check that the workspace ID is the one in that page's URL.")
            if response.statusCode == 401 || response.statusCode == 403 { throw expired }
            // A rejected session is redirected through /auth/authorize to /console/login.
            if let path = response.url?.path, path.contains("/login") || path.hasPrefix("/auth") { throw expired }
            guard (200..<300).contains(response.statusCode) else { throw AgentError.http(response.statusCode) }
            return try parse(String(decoding: data, as: UTF8.self), now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .opencodeGo, error: error)
        } catch {
            return AgentReport(agent: .opencodeGo, error: .network(error.localizedDescription))
        }
    }

    struct Quota: Equatable {
        let status: String
        let resetInSec: Int
        let usagePercent: Int
    }

    static func quota(_ name: String, in text: String) -> Quota? {
        guard let body = firstMatch(#"\#(name):\$R\[\d+\]=\{([^}]+)\}"#, in: text) else { return nil }
        return Quota(status: firstMatch(#"status:"([^"]+)""#, in: body) ?? "unknown",
                     resetInSec: Int(firstMatch(#"resetInSec:(\d+)"#, in: body) ?? "") ?? 0,
                     usagePercent: Int(firstMatch(#"usagePercent:(\d+)"#, in: body) ?? "") ?? 0)
    }

    /// The hydration script assigns the billing and usage objects to `$R`
    /// slots; their fields are matched directly rather than by slot number,
    /// which changes between deployments.
    static func parse(_ html: String, now: Date = Date()) throws -> AgentReport {
        guard let script = firstMatch(#"(<script>self\.\$R=[\s\S]*?</script>)"#, in: html) else {
            throw AgentError.parse("Could not find usage data in the OpenCode Go page. The page format may have changed.")
        }
        let rolling = quota("rollingUsage", in: script)
        let weekly = quota("weeklyUsage", in: script)
        let monthly = quota("monthlyUsage", in: script)
        guard rolling != nil || weekly != nil || monthly != nil else {
            throw AgentError.parse("Could not find usage data in the OpenCode Go page. The page format may have changed.")
        }

        func window(_ label: String, _ quota: Quota) -> UsageWindow {
            UsageWindow(label: label, percentRemaining: 100 - quota.usagePercent,
                        resetsAt: quota.resetInSec > 0 ? now.addingTimeInterval(TimeInterval(quota.resetInSec)) : nil)
        }
        var windows: [UsageWindow] = []
        if let rolling { windows.append(window("Rolling (2h)", rolling)) }
        if let weekly { windows.append(window("Weekly", weekly)) }
        if let monthly { windows.append(window("Monthly", monthly)) }

        // The plan appears in the billing object as subscriptionPlan:"…" or null.
        var plan = "Go"
        if let value = firstMatch(#"customerID:"cus_[^"]*"[^}]*?subscriptionPlan:([^,}]+)"#, in: script)?
            .trimmingCharacters(in: .whitespaces), value != "null" {
            plan = value.replacingOccurrences(of: "\"", with: "")
        }
        // Monthly is the extension's headline; fall back to the others.
        let headline = monthly.map { 100 - $0.usagePercent } ?? windows.map(\.percentRemaining).min()
        return AgentReport(agent: .opencodeGo, plan: plan, headline: headline, groups: [UsageGroup(windows: windows)], fetchedAt: now)
    }
}
