// SPDX-License-Identifier: GPL-3.0-or-later
import AgentUsageKit
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private var panel: DropPanel!
    private var outsideClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    static let togglePanelCommand = "togglePanel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Agent Usage")?
                .withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel = DropPanel(rootView: PanelView(store: store, actions: PanelActions(openSettings: { [weak self] in
            self?.openSettings(nil)
        })))
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        HotKeyCenter.shared.register(Self.togglePanelCommand) { [weak self] in self?.togglePanel() }
        store.refreshAll()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    /// The tightest limit across every agent, beside the icon, so a glance
    /// says whether anything is about to run out.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let lowest = store.lowestHeadline
        if store.showsPercentInMenuBar, let lowest {
            button.attributedTitle = NSAttributedString(
                string: " \(lowest)%",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        } else {
            button.title = ""
        }
        let lines = store.visibleReports.map { report in
            "\(report.title): \(report.headline.map { "\($0)%" } ?? report.error?.label ?? "—")"
        }
        button.toolTip = lines.isEmpty ? "Agent Usage" : lines.joined(separator: "\n")
    }

    // MARK: Panel

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible && NSApp.isActive {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? iconFrame
        let size = panel.frame.size
        let x = min(max(iconFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: iconFrame.minY - 6 - size.height))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        store.refreshIfStale()

        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
        }
    }

    private func closePanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": store.refreshAll()
        case ",": openSettings(nil)
        case "w": closePanel()
        default: return false
        }
        return true
    }

    // MARK: Menus

    /// Right-click: every agent's number at a glance, as the Raycast menu bar showed it.
    private func showContextMenu() {
        let menu = NSMenu()
        for report in store.visibleReports {
            let value = report.headline.map { "\($0)%" } ?? report.error?.label ?? ""
            let item = NSMenuItem(title: "\(report.title)  \(value)", action: #selector(openPanelFromMenu), keyEquivalent: "")
            item.target = self
            if let image = AgentIcon.image(report.agent, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            }
            var tip = report.groups.flatMap(\.windows).map { "\($0.label): \($0.percentRemaining)%" }
            if let error = report.error { tip = [error.message] }
            item.toolTip = tip.joined(separator: "\n")
            menu.addItem(item)
        }
        if !store.visibleReports.isEmpty { menu.addItem(.separator()) }
        let updated = store.isLoading ? "—" : store.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "—"
        let refresh = NSMenuItem(title: "Refresh All (Updated \(updated))", action: #selector(refreshAll), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Agent Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanelFromMenu() { showPanel() }
    @objc private func refreshAll() { store.refreshAll() }

    @objc func openSettings(_ sender: Any?) {
        closePanel()
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow(store: store)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Accessory apps have no visible menu bar, but the main menu still routes
    /// key equivalents; without it ⌘C, ⌘V and ⌘A don't work in text fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Agent Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

/// A borderless, transparent panel that drops down from the menu bar icon;
/// its shadow follows the glass view's rounded alpha.
final class DropPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }

    init<Content: View>(rootView: Content) {
        let size = NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        contentView = NSHostingView(rootView: rootView)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
