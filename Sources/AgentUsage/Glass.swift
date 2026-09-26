// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Liquid Glass where the system has it, a material or quiet fill where it
/// does not. The package deploys to macOS 14, so every glass call sits behind
/// the availability check here rather than scattered through the views.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false,
                                fallback: Material? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else if let fallback {
            background(fallback, in: shape)
        } else {
            background(Color.primary.opacity(0.07), in: shape)
        }
    }

    /// A content card: continuous corners, no glass.
    func card(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// Lets neighbouring glass shapes blend into each other instead of stacking
/// as separate panes.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A round glass button holding one symbol.
struct GlassIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
            }
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .contentShape(Circle())
                .glassSurface(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A capsule glass button with a label.
struct GlassPillButton: View {
    let title: String
    var symbol: String?
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .medium))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// Inner corners are concentric with the panel's: each radius is the outer
/// one minus the padding between them, so the curves run parallel.
enum Metrics {
    static let panelWidth: CGFloat = 400
    static let panelHeight: CGFloat = 580
    static let panelRadius: CGFloat = 26
    static let panelPadding: CGFloat = 14
    static let cardRadius: CGFloat = panelRadius - panelPadding
    static let cardPadding: CGFloat = 14
    static let iconButton: CGFloat = 28
    static let rowHeight: CGFloat = 30
    static let rowInset: CGFloat = 6
    static let rowRadius: CGFloat = cardRadius - rowInset
}

extension NSWindow {
    /// Rounds a borderless window, shadow included. Masking the frame view's
    /// layer rounds the material, but the window server still casts the
    /// shadow from the window's own corner radius, which leaves square
    /// corners showing on a light desktop. Only the private
    /// `_setCornerRadius:` changes that; it is looked up at runtime, so if a
    /// future macOS drops it the content stays rounded and only the shadow
    /// goes back to the stock shape.
    func roundCorners(_ radius: CGFloat) {
        guard let frame = contentView?.superview ?? contentView else { return }
        frame.wantsLayer = true
        frame.layer?.cornerRadius = radius
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true
        let selector = NSSelectorFromString("_setCornerRadius:")
        if responds(to: selector) {
            typealias Setter = @convention(c) (NSWindow, Selector, CGFloat) -> Void
            unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, radius)
        }
        invalidateShadow()
    }
}
