// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// A short message near the bottom of the screen, like the one Raycast shows
/// after a command: it never takes focus and ignores the mouse.
final class HUD {
    static let shared = HUD()

    enum Style {
        case success, failure, progress

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            case .progress: ""
            }
        }
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// A progress message stays until the next message replaces it or `hide()`.
    func show(_ text: String, style: Style = .success) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDView(text: text, style: style))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 96))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard style != .progress else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == .failure ? 4 : 1.6), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct HUDView: View {
    let text: String
    let style: HUD.Style

    var body: some View {
        HStack(spacing: 8) {
            if style == .progress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: style.symbol)
                    .foregroundStyle(style == .failure ? Color.orange : Color.green)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule(), fallback: .regularMaterial)
        .padding(12)
    }
}
