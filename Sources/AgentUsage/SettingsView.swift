// SPDX-License-Identifier: GPL-3.0-or-later
import AgentUsageKit
import AppKit
import ServiceManagement
import SwiftUI

/// A preferences window with toolbar tabs, like the system's own apps.
@MainActor
func makeSettingsWindow(store: UsageStore) -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(settingsTab("Agents", symbol: "square.stack.3d.up", AgentsSettingsView(store: store)))
    tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", GeneralSettingsView(store: store)))

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
}

private func settingsTab<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = .preferredContentSize
    controller.title = label
    let item = NSTabViewItem(viewController: controller)
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    return item
}

private struct AgentsSettingsView: View {
    @ObservedObject var store: UsageStore
    @AppStorage(UsageStore.Keys.codexHomes) private var codexHomes = ""
    @AppStorage(UsageStore.Keys.opencodeWorkspace) private var workspace = ""
    @State private var copilotToken = Keychain.read(UsageStore.Keys.copilotToken)
    @State private var cookie = Keychain.read(UsageStore.Keys.opencodeCookie)
    @State private var cursorCookie = Keychain.read(UsageStore.Keys.cursorCookie)

    var body: some View {
        Form {
            section(.claude, "Read from Claude Code's own login (the keychain, or ~/.claude/.credentials.json). Run `claude` to sign in. An expired token is refreshed and written back where Claude Code keeps it.") {
                EmptyView()
            }
            section(.codex, "Every login in ~/.codex: the active auth.json and any saved under accounts/. Run `codex login` to sign in.") {
                TextField("More Codex homes", text: $codexHomes, prompt: Text("~/work-codex, one per line or comma"), axis: .vertical)
                    .lineLimit(1...3)
            }
            section(.copilot, "Found through the GitHub CLI (`gh auth login`), then GITHUB_TOKEN or GH_TOKEN in your login shell. Each distinct token is shown as its own account.") {
                SecureField("Extra token (optional)", text: $copilotToken)
                    .onChange(of: copilotToken) { _, value in Keychain.write(value, for: UsageStore.Keys.copilotToken) }
            }
            section(.cursor, "Read with the login Cursor.app keeps on this Mac. Without Cursor.app, paste the Cookie header of a logged-in cursor.com request (DevTools → Network → any /api request → Request Headers → Cookie).") {
                SecureField("Cookie header (optional)", text: $cursorCookie)
                    .onChange(of: cursorCookie) { _, value in Keychain.write(value, for: UsageStore.Keys.cursorCookie) }
            }
            section(.opencodeGo, "OpenCode Go has no API: the app reads your workspace's Go page. The workspace ID is in the dashboard URL (wrk_…); the auth cookie is the `auth` cookie of a logged-in opencode.ai session (DevTools → Application → Cookies).") {
                TextField("Workspace ID", text: $workspace, prompt: Text("wrk_…"))
                SecureField("Auth cookie", text: $cookie)
                    .onChange(of: cookie) { _, value in Keychain.write(value, for: UsageStore.Keys.opencodeCookie) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
        .onDisappear { store.refreshAll() }
    }

    private func section<Content: View>(_ agent: AgentKind, _ footer: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.enabled.contains(agent) },
                set: { on in if on { store.enabled.insert(agent) } else { store.enabled.remove(agent) } }
            )) {
                HStack(spacing: 8) {
                    AgentIcon(agent: agent, size: 16)
                    Text(agent.name)
                }
            }
            if store.enabled.contains(agent) {
                content()
            }
        } footer: {
            Text(.init(footer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Agent Usage at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } footer: {
                Text("Opening the panel also refreshes it when the numbers are more than two minutes old.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show or hide the panel") {
                    ShortcutRecorder(AppDelegate.togglePanelCommand)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Works in every app. Hover the menu bar icon, or right-click it, for every agent's number at a glance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 340)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
