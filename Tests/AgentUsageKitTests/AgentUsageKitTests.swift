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
    /// The extension's fixture: a Solid.js hydration script from the Go page.
    private let html = #"""
    <!DOCTYPE html>
    <html><body>
    <script>self.$R=self.$R||[];
    _$HY.r["billing.get[\"wrk_FAKE123456789\"]""]=$R[13]=$R[2]($R[14]={p:0,s:0,f:0});
    _$HY.r["lite.subscription.get[\"wrk_FAKE123456789\"]""]=$R[17]=$R[2]($R[18]={p:0,s:0,f:0});
    ($R[24]=(r,d)=>{r.s(d),r.p.s=1,r.p.v=d})($R[18],$R[27]={mine:!0,useBalance:!1,rollingUsage:$R[28]={status:"ok",resetInSec:7302,usagePercent:13},weeklyUsage:$R[29]={status:"ok",resetInSec:406676,usagePercent:32},monthlyUsage:$R[30]={status:"ok",resetInSec:1188832,usagePercent:89}});
    $R[24]($R[20],$R[27]);
    $R[24]($R[14],$R[31]={customerID:"cus_FAKECUSTOMER123",paymentMethodID:"pm_FAKEPAYMENT123",paymentMethodType:"card",paymentMethodLast4:"4242",balance:123456789,reload:!1,reloadAmount:10,reloadAmountMin:10,reloadTrigger:5,reloadTriggerMin:5,monthlyLimit:50,monthlyUsage:50000000,timeMonthlyUsageUpdated:$R[32]=new Date("2026-01-01T00:00:00.000Z"),reloadError:null,timeReloadError:null,subscription:null,subscriptionID:null,subscriptionPlan:null,timeSubscriptionBooked:null,timeSubscriptionSelected:null,lite:$R[33]={},liteSubscriptionID:"sub_FAKESUBSCRIPTION123"});
    $R[24]($R[16],$R[31]);
    </script></body></html>
    """#

    func testParsesHydrationData() throws {
        let report = try OpenCodeGoProvider.parse(html, now: now)
        XCTAssertEqual(report.plan, "Go")
        XCTAssertEqual(report.headline, 11)
        XCTAssertEqual(report.groups[0].windows.map(\.label), ["Rolling (2h)", "Weekly", "Monthly"])
        XCTAssertEqual(report.groups[0].windows.map(\.percentRemaining), [87, 68, 11])
        XCTAssertEqual(report.groups[0].windows[0].resetsAt, now.addingTimeInterval(7302))
    }

    func testMissingDataIsAnError() {
        XCTAssertThrowsError(try OpenCodeGoProvider.parse("<html><body>No data here</body></html>"))
        XCTAssertThrowsError(try OpenCodeGoProvider.parse(""))
        XCTAssertEqual(OpenCodeGoProvider.pageURL(workspaceID: " abc ")?.absoluteString, "https://opencode.ai/workspace/wrk_abc/go")
    }
}

final class AntigravityTests: XCTestCase {
    func testFindsTheAppServerAndItsToken() {
        let ps = """
          101 /usr/bin/git status --cwd /Users/me/.antigravity-cli/scratch
          202 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token abc-123 --extension_server_port 51234 --app_data_dir antigravity
          303 /Users/me/.antigravity-cli/bin/language_server --random
        """
        let (info, saw) = AntigravityProvider.parseProcesses(ps)
        XCTAssertTrue(saw)
        XCTAssertEqual(info, .init(pid: 202, csrfToken: "abc-123", extensionPort: 51234))
    }

    func testCLIFallbackAndMissingToken() {
        let (cli, _) = AntigravityProvider.parseProcesses("  9 /opt/homebrew/bin/agy serve")
        XCTAssertEqual(cli?.csrfToken, "cli-dummy-token")
        let (none, saw) = AntigravityProvider.parseProcesses("  9 /Applications/Antigravity.app/x/antigravity/language_server --app_data_dir antigravity")
        XCTAssertNil(none)
        XCTAssertTrue(saw)
    }

    func testParsesPorts() {
        let lsof = "language 202 me 12u IPv4 0x1 0t0 TCP 127.0.0.1:51235 (LISTEN)\nlanguage 202 me 13u IPv4 0x1 0t0 TCP 127.0.0.1:51234 (LISTEN)\n"
        XCTAssertEqual(AntigravityProvider.parsePorts(lsof), [51234, 51235])
    }

    func testUserStatusWithQuotaGroupsKeepsThirdPartyOutOfTheHeadline() throws {
        let status: [String: Any] = ["userStatus": [
            "email": "me@example.com",
            "planStatus": ["planInfo": ["planName": "Pro"]],
            "cascadeModelConfigData": ["clientModelConfigs": [
                ["label": "Gemini 3 Pro (High)", "modelOrAlias": ["model": "g3p"], "quotaInfo": ["remainingFraction": 0.8]],
                ["label": "Claude Opus 4.5", "modelOrAlias": ["model": "opus"], "quotaInfo": ["remainingFraction": 0]],
            ]]]]
        let summary: [String: Any] = ["response": ["groups": [
            ["displayName": "Gemini", "buckets": [["displayName": "5 hours", "remainingFraction": 0.6]]],
            ["displayName": "Other models", "description": "Claude and GPT", "buckets": [["displayName": "Weekly", "remainingFraction": 0]]],
        ]]]
        let report = try AntigravityProvider.parseUserStatus(status, quotaSummary: summary, now: now)
        XCTAssertEqual(report.plan, "Pro")
        XCTAssertEqual(report.headline, 60)
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertEqual(report.details, ["Account: me@example.com"])

        let modelsOnly = try AntigravityProvider.parseUserStatus(status, quotaSummary: nil, now: now)
        XCTAssertEqual(modelsOnly.headline, 80)
        XCTAssertEqual(modelsOnly.groups[0].windows.map(\.label), ["Gemini 3 Pro (High)", "Claude Opus 4.5"])
        XCTAssertThrowsError(try AntigravityProvider.parseModelConfigs(["code": 5], now: now))
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
