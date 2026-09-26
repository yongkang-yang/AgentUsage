// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Antigravity's model quotas, asked of its running language server over the
/// local Connect API it serves to the editor. Antigravity has to be open.
public enum AntigravityProvider {
    static let service = "/exa.language_server_pb.LanguageServerService/"
    /// The CLI's server once accepted any token; agy 1.2 and later reject it.
    static let cliDummyToken = "cli-dummy-token"
    static let cliUnsupported = AgentError(
        "CLI Unsupported",
        "The agy CLI (1.2 and later) only answers requests carrying its own CSRF token, which it keeps to itself. Open the Antigravity app to see its quotas here.")

    struct ProcessInfo: Equatable {
        let pid: Int
        let csrfToken: String
        let extensionPort: Int?
    }

    public static func fetch(_ env: UsageEnvironment, localTransport: @escaping UsageEnvironment.Transport = LocalServer.transport) async -> AgentReport {
        do {
            let process = try await detectProcess(env)
            let ports = try await listeningPorts(pid: process.pid, env)
            let client = Client(transport: localTransport, csrfToken: process.csrfToken)
            guard let port = await client.workingPort(ports) else {
                if client.sawCSRFRejection && process.csrfToken == cliDummyToken {
                    throw cliUnsupported
                }
                throw AgentError("Port Error", "Antigravity port detection failed: no working API port found")
            }
            client.httpsPort = port
            client.httpPort = process.extensionPort ?? port

            if let status = try? await client.call("GetUserStatus") {
                let summary = try? await client.call("RetrieveUserQuotaSummary")
                if let report = try? parseUserStatus(status, quotaSummary: summary, now: env.now()) {
                    return report
                }
                if let report = try? parseModelConfigs(status, now: env.now()) { return report }
            }
            return try parseModelConfigs(try await client.call("GetCommandModelConfigs"), now: env.now())
        } catch let error as AgentError {
            return AgentReport(agent: .antigravity, error: error)
        } catch {
            return AgentReport(agent: .antigravity, error: .network(error.localizedDescription))
        }
    }

    // MARK: Finding the server

    static func detectProcess(_ env: UsageEnvironment) async throws -> ProcessInfo {
        guard let output = try? await env.run("/bin/ps", ["-ax", "-o", "pid=,command="], false) else {
            throw AgentError.network("ps command failed")
        }
        let (info, sawAntigravity) = parseProcesses(output)
        if let info { return info }
        if sawAntigravity {
            throw AgentError("CSRF Missing", "Antigravity CSRF token not found. Restart Antigravity and retry.")
        }
        throw AgentError("Not Running", "Antigravity language server not detected. Launch Antigravity and retry.")
    }

    static func executable(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let quoted = firstMatch(#"^["']([^"']+)["']"#, in: trimmed) { return quoted }
        return String(trimmed.split(separator: " ", maxSplits: 1).first ?? "")
    }

    static func isAgy(_ command: String) -> Bool {
        let name = executable(command).lowercased().split(separator: "/").last.map(String.init) ?? ""
        return name == "agy"
    }

    /// The app's server carries `--app_data_dir …antigravity…` or lives under
    /// `/antigravity/`; the CLI's is the bare `agy` binary or lives under
    /// `/antigravity-cli/`. Only executables are matched, never arguments, so a
    /// helper the CLI spawns isn't mistaken for the server.
    static func parseProcesses(_ output: String) -> (ProcessInfo?, Bool) {
        var sawAntigravity = false
        var app: ProcessInfo?, cli: ProcessInfo?
        for line in output.split(separator: "\n") {
            guard let pidText = firstMatch(#"^\s*(\d+)\s+"#, in: String(line)), let pid = Int(pidText) else { continue }
            let command = String(line.drop(while: { $0 == " " }).dropFirst(pidText.count)).trimmingCharacters(in: .whitespaces)
            let lower = command.lowercased()
            guard lower.contains("language_server") || isAgy(command) else { continue }
            let isApp = (lower.contains("--app_data_dir") && lower.contains("antigravity")) || lower.contains("/antigravity/")
            let isCLI = isAgy(command) || executable(command).lowercased().contains("/antigravity-cli/")
            guard isApp || isCLI else { continue }
            sawAntigravity = true

            var token = firstMatch(#"(?i)--csrf_token[=\s]+(\S+)"#, in: command)
            if token == nil {
                // The app always passes a real token; only the CLI accepts a dummy.
                guard isCLI else { continue }
                token = cliDummyToken
            }
            let port = firstMatch(#"(?i)--extension_server_port[=\s]+(\S+)"#, in: command).flatMap(Int.init)
            let info = ProcessInfo(pid: pid, csrfToken: token!, extensionPort: port)
            if isApp, app == nil { app = info } else if !isApp, cli == nil { cli = info }
        }
        return (app ?? cli, sawAntigravity)
    }

    static func listeningPorts(pid: Int, _ env: UsageEnvironment) async throws -> [Int] {
        guard let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw AgentError("Port Error", "Antigravity port detection failed: lsof not available")
        }
        guard let output = try? await env.run(lsof, ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)], false) else {
            throw AgentError("Port Error", "Antigravity port detection failed: could not inspect listening ports")
        }
        let ports = parsePorts(output)
        guard !ports.isEmpty else { throw AgentError("Port Error", "Antigravity port detection failed: no listening ports found") }
        return ports
    }

    static func parsePorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        let ports = matches.compactMap { Range($0.range(at: 1), in: output).flatMap { Int(output[$0]) } }
        return Array(Set(ports)).sorted()
    }

    // MARK: Talking to it

    final class Client: @unchecked Sendable {
        let transport: UsageEnvironment.Transport
        let csrfToken: String
        var httpsPort = 0
        var httpPort = 0
        /// A port answered, but refused the CSRF token.
        var sawCSRFRejection = false

        init(transport: @escaping UsageEnvironment.Transport, csrfToken: String) {
            self.transport = transport
            self.csrfToken = csrfToken
        }

        static let metadata: [String: Any] = ["metadata": ["ideName": "antigravity", "extensionName": "antigravity",
                                                           "ideVersion": "unknown", "locale": "en"]]
        static let unleash: [String: Any] = ["context": ["properties": [
            "devMode": "false", "extensionVersion": "unknown", "hasAnthropicModelAccess": "true", "ide": "antigravity",
            "ideVersion": "unknown", "installationId": "native-agent-usage", "language": "UNSPECIFIED", "os": "macos",
            "requestedModelId": "MODEL_UNSPECIFIED"]]]

        func send(_ scheme: String, port: Int, method: String, body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "\(scheme)://127.0.0.1:\(port)\(service)\(method)")!, timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401, String(decoding: data, as: UTF8.self).contains("CSRF") { sawCSRFRejection = true }
                throw AgentError("API Error", "Antigravity API error: HTTP \(status): \(String(decoding: data, as: UTF8.self))")
            }
            guard let object = JSON.object(data) else { throw AgentError.parse("Invalid JSON from local Antigravity API") }
            return object
        }

        func workingPort(_ ports: [Int]) async -> Int? {
            for port in ports {
                if (try? await send("https", port: port, method: "GetUnleashData", body: Self.unleash)) != nil { return port }
                if (try? await send("http", port: port, method: "GetUnleashData", body: Self.unleash)) != nil { return port }
            }
            return nil
        }

        /// HTTPS on the working port first, then plain HTTP on the extension
        /// server port and the working port.
        func call(_ method: String) async throws -> [String: Any] {
            var lastError: Error = AgentError.network("Antigravity request failed")
            do {
                return try await send("https", port: httpsPort, method: method, body: Self.metadata)
            } catch {
                lastError = error
            }
            for port in [httpPort, httpsPort].reduce(into: [Int](), { if !$0.contains($1) { $0.append($1) } }) {
                do {
                    return try await send("http", port: port, method: method, body: Self.metadata)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    // MARK: Parsing

    struct ModelQuota {
        let label: String
        let modelID: String
        let percentLeft: Int
        let resetsAt: Date?
    }

    static func codeError(_ code: Any?) -> String? {
        guard let code else { return nil }
        if let number = code as? NSNumber { return number.intValue == 0 ? nil : "\(number)" }
        if let text = code as? String { return ["ok", "success", "0"].contains(text.lowercased()) ? nil : text }
        return "Unknown code"
    }

    static func quota(_ config: [String: Any]) -> ModelQuota? {
        guard let info = config["quotaInfo"] as? [String: Any] else { return nil }
        let label = JSON.string(config["label"]) ?? "Unknown model"
        let id = JSON.string((config["modelOrAlias"] as? [String: Any])?["model"]) ?? JSON.string(config["label"]) ?? "unknown"
        let fraction = JSON.number(info["remainingFraction"])
        return ModelQuota(label: label, modelID: id, percentLeft: fraction.map { UsageFormat.clampPercent($0 * 100) } ?? 0,
                          resetsAt: UsageFormat.parseDate(info["resetTime"]))
    }

    /// Gemini Pro, then Gemini Flash, then a Claude model, then the most used of the rest.
    static func displayOrder(_ models: [ModelQuota]) -> [ModelQuota] {
        var ordered: [ModelQuota] = []
        func add(_ model: ModelQuota?) {
            if let model, !ordered.contains(where: { $0.modelID == model.modelID }) { ordered.append(model) }
        }
        func has(_ model: ModelQuota, _ words: String...) -> Bool { words.allSatisfy(model.label.lowercased().contains) }
        add(models.first { has($0, "gemini", "pro", "high") } ?? models.first { has($0, "gemini", "pro") })
        add(models.first { has($0, "gemini", "flash") })
        add(models.first { has($0, "claude", "opus") }
            ?? models.first { has($0, "claude", "sonnet") && !$0.label.lowercased().contains("thinking") }
            ?? models.first { has($0, "claude") })
        for model in models.sorted(by: { $0.percentLeft < $1.percentLeft }) { add(model) }
        return ordered
    }

    static func modelReport(_ models: [ModelQuota], email: String?, plan: String?, groups quotaGroups: [UsageGroup],
                            now: Date) -> AgentReport {
        let ordered = displayOrder(models)
        let modelWindows = ordered.map { UsageWindow(label: $0.label, percentRemaining: $0.percentLeft, resetsAt: $0.resetsAt) }
        let groups = quotaGroups.isEmpty ? [UsageGroup(windows: modelWindows)] : quotaGroups
        let headline = quotaGroups.isEmpty ? ordered.first?.percentLeft : effectivePercent(quotaGroups)
        return AgentReport(agent: .antigravity, plan: plan, headline: headline, groups: groups,
                           details: email.map { ["Account: \($0)"] } ?? [], fetchedAt: now)
    }

    /// Third-party pools (Claude, GPT) are separate add-ons; their limits
    /// don't drag the headline below the first-party Gemini experience.
    static func effectivePercent(_ groups: [UsageGroup]) -> Int {
        let thirdParty = ["claude", "gpt", "openai", "anthropic"]
        let firstParty = groups.filter { group in !thirdParty.contains { (group.title ?? "").lowercased().contains($0) } }
        let percents = (firstParty.isEmpty ? groups : firstParty).flatMap(\.windows).map(\.percentRemaining)
        return percents.min() ?? 100
    }

    static func quotaGroups(_ summary: [String: Any]?) -> [UsageGroup] {
        let groups = (summary?["response"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        return groups.compactMap { group in
            let windows = (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> UsageWindow? in
                guard let fraction = JSON.number(bucket["remainingFraction"]) else { return nil }
                return UsageWindow(label: JSON.string(bucket["displayName"]) ?? "Limit",
                                   percentRemaining: UsageFormat.clampPercent(fraction * 100),
                                   resetsAt: UsageFormat.parseDate(bucket["resetTime"]),
                                   note: JSON.string(bucket["description"]))
            }
            guard !windows.isEmpty else { return nil }
            // Descriptions carry the "Claude"/"GPT" markers some groups need.
            let title = [JSON.string(group["displayName"]) ?? "Unknown group", JSON.string(group["description"])]
            return UsageGroup(title: title[0], windows: windows).withMarker(title[1])
        }
    }

    static func parseUserStatus(_ body: [String: Any], quotaSummary: [String: Any]?, now: Date) throws -> AgentReport {
        if let message = codeError(body["code"]) { throw AgentError("API Error", message) }
        guard let status = body["userStatus"] as? [String: Any] else { throw AgentError.parse("Missing userStatus") }
        let configs = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        let models = configs.compactMap(quota)
        let groups = quotaGroups(quotaSummary)
        guard !models.isEmpty || !groups.isEmpty else { throw AgentError.parse("No quota models available") }
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let plan = ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
            .lazy.compactMap { JSON.string(planInfo?[$0]) }.first
        return modelReport(models, email: JSON.string(status["email"]), plan: plan, groups: groups, now: now)
    }

    static func parseModelConfigs(_ body: [String: Any], now: Date) throws -> AgentReport {
        if let message = codeError(body["code"]) { throw AgentError("API Error", message) }
        let models = (body["clientModelConfigs"] as? [[String: Any]] ?? []).compactMap(quota)
        guard !models.isEmpty else { throw AgentError.parse("No quota models available") }
        return modelReport(models, email: nil, plan: nil, groups: [], now: now)
    }
}

extension UsageGroup {
    /// Keeps a group's description in its title when it names a third-party
    /// model family the title doesn't, so the headline rule can see it.
    func withMarker(_ description: String?) -> UsageGroup {
        guard let description, let title,
              ["claude", "gpt", "openai", "anthropic"].contains(where: { description.lowercased().contains($0) && !title.lowercased().contains($0) })
        else { return self }
        return UsageGroup(title: "\(title) (\(description))", windows: windows)
    }
}

/// URLSession for the language server on 127.0.0.1, which serves HTTPS with
/// a self-signed certificate. Trust is relaxed for that host only.
public enum LocalServer {
    final class TrustLocalhost: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    static let session = URLSession(configuration: .ephemeral, delegate: TrustLocalhost(), delegateQueue: nil)

    public static let transport: UsageEnvironment.Transport = { try await session.data(for: $0) }
}
