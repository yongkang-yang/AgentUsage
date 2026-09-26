// SPDX-License-Identifier: GPL-3.0-or-later
import AgentUsageKit
import AppKit
import SwiftUI

struct PanelActions {
    var openSettings: () -> Void
}

/// The drop-down panel: one card per agent account.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    if store.enabled.isEmpty {
                        Text("No agents are switched on. Choose some in Settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .card()
                    }
                    ForEach(store.visibleReports) { report in
                        AgentCard(report: report, isRefreshing: store.loading.contains(report.agent))
                    }
                    ForEach(store.pendingAgents, id: \.self) { agent in
                        PendingCard(agent: agent)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(Metrics.panelPadding)
        .frame(width: Metrics.panelWidth, height: Metrics.panelHeight)
        .glassSurface(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous), fallback: .regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Usage").font(.system(size: 13, weight: .semibold))
                Text(store.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Loading…")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GlassGroup {
                HStack(spacing: 6) {
                    GlassIconButton(symbol: "arrow.clockwise", help: "Refresh All (⌘R)", spinning: store.isLoading) {
                        store.refreshAll()
                    }
                    GlassIconButton(symbol: "gearshape", help: "Settings (⌘,)", action: actions.openSettings)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Green, then amber below half, red below a fifth: the extension's colours.
func usageColor(_ percent: Int) -> Color {
    percent >= 50 ? Color(red: 0.19, green: 0.82, blue: 0.35)
        : percent >= 20 ? Color(red: 1, green: 0.62, blue: 0.04) : Color(red: 1, green: 0.27, blue: 0.23)
}

struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Self.image(agent, dark: colorScheme == .dark) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "cpu").frame(width: size, height: size)
        }
    }

    static func image(_ agent: AgentKind, dark: Bool) -> NSImage? {
        let base = Bundle.main.resourceURL?.appendingPathComponent("AgentIcons")
        let names = dark ? ["\(agent.iconName)@dark", agent.iconName] : [agent.iconName]
        for name in names {
            if let url = base?.appendingPathComponent("\(name).svg"), let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

private struct AgentCard: View {
    let report: AgentReport
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentIcon(agent: report.agent)
                Text(report.agent.name).font(.system(size: 13, weight: .semibold))
                if let account = report.account {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let plan = report.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 4)
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                if let headline = report.headline {
                    Text("\(headline)%")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(usageColor(headline))
                        .help("Remaining on the tightest limit")
                } else if let error = report.error {
                    Text(error.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            if let error = report.error {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(report.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                    }
                    ForEach(group.windows) { window in
                        WindowRow(window: window)
                    }
                }
            }

            ForEach(report.details, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.label).font(.system(size: 11))
                if let note = window.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(caption)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(usageColor(window.percentRemaining))
                        .frame(width: max(4, proxy.size.width * CGFloat(window.percentRemaining) / 100))
                        .opacity(window.percentRemaining == 0 ? 0 : 1)
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var text = "\(window.percentRemaining)% left"
        if let resets = UsageFormat.resetsIn(window.resetsAt) {
            text += resets == "now" ? " · resets now" : " · resets in \(resets)"
        }
        return text
    }
}

private struct PendingCard: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: agent)
            Text(agent.name).font(.system(size: 13, weight: .semibold))
            Spacer()
            ProgressView().controlSize(.mini)
        }
        .padding(Metrics.cardPadding)
        .card()
    }
}
