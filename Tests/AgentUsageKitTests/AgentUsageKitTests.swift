// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import AgentUsageKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

final class ClaudeTests: XCTestCase {
    private let credentials = ClaudeProvider.Credentials(accessToken: "t", refreshToken: nil, expiresAt: nil,
                                                         rateLimitTier: "default_claude_max_20x", subscriptionType: nil,
                                                         source: .keychain(account: nil), raw: [:])

    func testParsesWindowsModelsAndExtraUsage() throws {
        let body = json([
            "five_hour": ["utilization": 27.4, "resets_at": "2027-01-15T10:00:00Z"],
            "seven_day": ["utilization": 60],
            "seven_day_opus": ["utilization": 10],
            "limits": [["kind": "weekly_scoped", "percent": 95, "scope": ["model": ["display_name": "Fable"]]],
                       ["kind": "weekly_scoped", "percent": 50, "is_active": false, "scope": ["model": ["id": "x"]]]],
            "extra_usage": ["is_enabled": true, "monthly_limit": 2000, "used_credits": 150, "currency": "usd"],
        ])
        let report = try ClaudeProvider.parse(data: body, status: 200, credentials: credentials, now: now)
        XCTAssertEqual(report.plan, "Max")
        XCTAssertEqual(report.headline, 73)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["5-hour", "Weekly", "Weekly · Opus", "Weekly · Fable"])
        XCTAssertEqual(report.groups[0].windows.map(\.percentRemaining), [73, 40, 90, 5])
        XCTAssertEqual(report.details, ["Extra usage: USD 1.50 / 20.00"])
    }

    func testClassifiesErrors() {
        XCTAssertThrowsError(try ClaudeProvider.parse(data: Data(), status: 401, credentials: credentials, now: now)) {
            XCTAssertEqual(($0 as? AgentError)?.label, "Token Expired")
        }
        XCTAssertThrowsError(try ClaudeProvider.parse(data: Data("needs user:profile".utf8), status: 403, credentials: credentials, now: now)) {
            XCTAssertEqual(($0 as? AgentError)?.label, "Missing Scope")
        }
        XCTAssertThrowsError(try ClaudeProvider.parse(data: json([:]), status: 200, credentials: credentials, now: now))
    }

    func testReadsHexEncodedKeychainValuesAndRequiresProfileScope() throws {
        let stored = json(["claudeAiOauth": ["accessToken": "Bearer abc", "scopes": ["user:profile"]]])
        let hex = stored.map { String(format: "%02x", $0) }.joined()
        let parsed = try XCTUnwrap(ClaudeProvider.parseStored(Data(hex.utf8)))
        XCTAssertEqual(try ClaudeProvider.extract(parsed, source: .keychain(account: nil)).accessToken, "abc")
        let noScope = ["claudeAiOauth": ["accessToken": "abc", "scopes": ["user:inference"]]]
        XCTAssertThrowsError(try ClaudeProvider.extract(noScope, source: .keychain(account: nil)))
    }
}

final class CodexTests: XCTestCase {
    private let account = CodexProvider.Account(id: "a", label: "Me", token: "t", accountID: nil, userID: nil)

    func testParsesWindowsAndPicksTheBindingOne() throws {
        let body = json([
            "plan_type": "prolite",
            "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000, "reset_after_seconds": 3600],
                           "secondary_window": ["used_percent": 70, "limit_window_seconds": 604800]],
            "code_review_rate_limit": ["primary_window": ["used_percent": 5, "limit_window_seconds": 604800]],
            "additional_rate_limits": [["limit_name": "GPT-5 Codex Spark",
                                        "rate_limit": ["primary_window": ["used_percent": 50, "limit_window_seconds": 18000]]]],
            "credits": ["has_credits": true, "balance": "12.5"],
        ])
        let report = try CodexProvider.parse(body, account: account, label: nil, resetCredits: (2, []), now: now)
        XCTAssertEqual(report.plan, "Pro 5x")
        XCTAssertEqual(report.headline, 30)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["5-hour", "Weekly", "Code Review"])
        XCTAssertEqual(report.groups[0].windows[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(report.groups[1].title, "GPT-5 Codex Spark")
        XCTAssertEqual(report.details, ["Credits: 12.5", "Rate-limit reset credits: 2"])
    }

    func testSingleLongWindowIsWeekly() throws {
        let body = json(["rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": 604800]]])
        let report = try CodexProvider.parse(body, account: account, label: nil, resetCredits: nil, now: now)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["Weekly"])
        XCTAssertEqual(report.plan, "Unknown")
    }

    func testDiscoversActiveAndSavedAccounts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let accounts = home.appendingPathComponent("accounts")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let claims = Data(#"{"name":"Johan","https://api.openai.com/auth":{"user_id":"u1"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        try json(["tokens": ["access_token": "active", "account_id": "acc1", "id_token": "h.\(claims).s"]])
            .write(to: home.appendingPathComponent("auth.json"))
        let stem = Data("u2::acc2".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try json(["tokens": ["access_token": "saved"]]).write(to: accounts.appendingPathComponent("\(stem).auth.json"))
        let found = CodexProvider.discoverAccounts(in: home, prefix: "codex")
        XCTAssertEqual(found.map(\.label), ["Johan", "u2"])
        XCTAssertEqual(found.map(\.accountID), ["acc1", "acc2"])
        XCTAssertEqual(CodexProvider.parseHomes("~/work, /tmp/x\n~/work", home: URL(fileURLWithPath: "/Users/me")).map(\.path),
                       ["/Users/me/work", "/tmp/x"])
    }
}

final class CopilotTests: XCTestCase {
    func testParsesSnapshots() throws {
        let body = json(["copilot_plan": "individual_pro", "quota_reset_date": "2027-02-01",
                         "quota_snapshots": ["premium_interactions": ["entitlement": 300, "remaining": 120],
                                             "chat": ["percent_remaining": 100]]])
        let report = try CopilotProvider.parse(body)
        XCTAssertEqual(report.plan, "Individual Pro")
        XCTAssertEqual(report.headline, 40)
        XCTAssertEqual(report.groups[0].windows.map(\.note), ["120 / 300 credits", nil])
        XCTAssertNotNil(report.groups[0].windows[0].resetsAt)
    }

    func testFallsBackToMonthlyQuotas() throws {
        let body = json(["monthly_quotas": ["chat": 50, "completions": 2000], "limited_user_quotas": ["chat": 25, "completions": 500]])
        let report = try CopilotProvider.parse(body)
        XCTAssertEqual(report.groups[0].windows.map(\.percentRemaining), [25, 50])
        XCTAssertThrowsError(try CopilotProvider.parse(json(["copilot_plan": "free"])))
    }

    func testReadsMarkedShellOutput() {
        let output = "motd\n__GITHUB_TOKEN_START__ghp_1__GITHUB_TOKEN_END__\n__GH_TOKEN_START____GH_TOKEN_END__\n"
        XCTAssertEqual(CopilotProvider.marked(output, CopilotProvider.markers.github), "ghp_1")
        XCTAssertNil(CopilotProvider.marked(output, CopilotProvider.markers.gh))
    }
}

final class OpenCodeGoTests: XCTestCase {
    /// The shape the console's /api/go/status returns (its GoStatus schema).
    private let status: [String: Any] = [
        "product": "go-plus", "useBalance": false, "cancelAtPeriodEnd": false,
        "access": ["startsAt": "2026-09-13T00:00:00.000Z", "endsAt": "2026-10-13T00:00:00.000Z", "cancelAtPeriodEnd": false,
                   "meters": ["fiveHour": ["resetsAt": "2027-01-15T12:00:00.000Z", "limitMicroCents": "4800000000", "usedMicroCents": "0"],
                              "week": ["startsAt": "2027-01-11T00:00:00.000Z", "resetsAt": "2027-01-18T00:00:00.000Z",
                                       "limitMicroCents": "12000000000", "usedMicroCents": "840000000"],
                              "month": ["limitMicroCents": "24000000000", "usedMicroCents": "22560000000"]]],
    ]

    func testParsesMeters() throws {
        let report = try OpenCodeGoProvider.parse(status, now: now)
        XCTAssertEqual(report.plan, "Go Plus")
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["Rolling (5h)", "Weekly", "Monthly"])
        XCTAssertEqual(report.groups[0].windows.map(\.percentRemaining), [100, 93, 6])
        XCTAssertEqual(report.groups[0].windows.map(\.note), ["$0.00 / $48.00", "$8.40 / $120.00", "$225.60 / $240.00"])
        XCTAssertEqual(report.headline, 6)
        XCTAssertEqual(report.groups[0].windows[2].resetsAt, UsageFormat.parseDate("2026-10-13T00:00:00.000Z"))
    }

    func testNoSubscriptionAndInputs() {
        XCTAssertThrowsError(try OpenCodeGoProvider.parse(["product": "go"])) {
            XCTAssertEqual(($0 as? AgentError)?.label, "No Subscription")
        }
        XCTAssertEqual(OpenCodeGoProvider.parseWorkspaces(" wrk_A\nB, wrk_A "), ["wrk_A", "wrk_B"])
        XCTAssertEqual(OpenCodeGoProvider.cookieHeader(" st_1 "), "__Host-console_session=st_1")
        XCTAssertEqual(OpenCodeGoProvider.cookieHeader("a=1; b=2"), "a=1; b=2")
        XCTAssertNil(OpenCodeGoProvider.cookieHeader(" "))
    }
}

/// Ported from the extension's cursor/parser.test.ts.
final class CursorTests: XCTestCase {
    func testEnterpriseOverallWhenPlanIsAbsent() {
        let report = CursorProvider.parse(summary: ["billingCycleEnd": "2026-05-01T00:00:00.000Z", "membershipType": "enterprise",
                                                    "individualUsage": ["overall": ["used": 7384, "limit": 10000]],
                                                    "teamUsage": ["pooled": ["used": 12_725_135, "limit": 28_122_000]]],
                                          user: ["email": "user@example.com", "sub": "auth0|user"], requests: nil, now: now)
        XCTAssertEqual(report.plan, "Enterprise")
        XCTAssertEqual(report.headline, 26)
        XCTAssertEqual(report.groups[0].windows.map(\.note), ["$73.84 / $100.00"])
        XCTAssertEqual(report.details, ["Account: user@example.com"])
    }

    func testLegacyRequestsReplaceAutoAndAPI() {
        let report = CursorProvider.parse(summary: ["individualUsage": ["plan": ["used": 700, "limit": 10000, "autoPercentUsed": 11, "apiPercentUsed": 22]]],
                                          user: nil, requests: ["gpt-4": ["numRequests": 200, "numRequestsTotal": 240, "maxRequestUsage": 500]], now: now)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["Requests"])
        XCTAssertEqual(report.headline, 52)
    }

    func testPlanTotalAndSeparatePools() {
        let report = CursorProvider.parse(summary: ["membershipType": "pro",
                                                    "individualUsage": ["plan": ["used": 1800, "limit": 10000, "autoPercentUsed": 10, "apiPercentUsed": 50]]],
                                          user: nil, requests: nil, now: now)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["Total", "Auto", "API"])
        XCTAssertEqual(report.groups[0].windows.map(\.percentRemaining), [82, 90, 50])
        XCTAssertEqual(report.headline, 50)
    }

    func testTeamOnDemand() {
        let report = CursorProvider.parse(summary: ["individualUsage": ["onDemand": ["used": 4471]],
                                                    "teamUsage": ["onDemand": ["used": 1_311_125, "limit": 2_000_000]]],
                                          user: nil, requests: nil, now: now)
        XCTAssertEqual(report.details, ["Team on-demand: $13111.25 / $20000.00 (yours $44.71)"])
    }

    func testSessionCookieFromAppToken() {
        func token(_ payload: String) -> String {
            "h." + Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        }
        let valid = token(#"{"sub":"auth0|user_01ABC","exp":\#(Int(now.timeIntervalSince1970) + 3600)}"#)
        XCTAssertEqual(CursorProvider.session(fromAccessToken: valid, now: now)?.cookieHeader,
                       "WorkosCursorSessionToken=user_01ABC%3A%3A\(valid)")
        let expiring = token(#"{"sub":"auth0|user_01ABC","exp":\#(Int(now.timeIntervalSince1970) + 30)}"#)
        XCTAssertNil(CursorProvider.session(fromAccessToken: expiring, now: now))
    }
}

final class FormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(UsageFormat.resetsIn(now.addingTimeInterval(3 * 86400 + 4 * 3600 + 60), now: now), "3d 4h")
        XCTAssertEqual(UsageFormat.resetsIn(now.addingTimeInterval(2 * 3600), now: now), "2h")
        XCTAssertEqual(UsageFormat.resetsIn(now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(UsageFormat.parseDate("1800000000000"), now)
        XCTAssertNotNil(UsageFormat.parseDate("2027-01-15T10:00:00.123Z"))
    }
}
