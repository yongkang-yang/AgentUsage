// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus modifiers, as recorded in Settings.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    /// How the key itself reads, e.g. "Space" or "D".
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// What an NSMenuItem needs to show the shortcut beside its title; nil
    /// for keys a menu can't draw from a plain character.
    var menuKeyEquivalent: String? {
        guard key.count == 1, let character = key.first, character.isLetter || character.isNumber else { return nil }
        return key.lowercased()
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// nil when the key can't be a global shortcut: it needs ⌘, ⌥ or ⌃, unless it's a function key.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let key = Self.functionKeys[code] ?? Self.namedKeys[code]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
        guard let key, !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: flags.rawValue, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// The system-wide shortcuts, one per command. Carbon hot keys work from any
/// app without the Accessibility permission a global key monitor would need.
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    @Published private(set) var shortcuts: [String: HotKeyShortcut] = [:]
    /// Commands whose shortcut the system refused, usually because another
    /// app (Raycast, say) holds it.
    @Published private(set) var failed: Set<String> = []

    private var actions: [String: () -> Void] = [:]
    private var order: [String] = []
    private var refs: [String: EventHotKeyRef] = [:]
    private var isHandlerInstalled = false
    private var isSuspended = false
    private static let signature = OSType(0x4147_5553)  // "AGUS"

    private func storageKey(_ name: String) -> String { "hotKey.\(name)" }

    /// Declares a command. A stored choice wins over `standard`, including a
    /// stored "none", so removing a default shortcut sticks.
    func register(_ name: String, standard: HotKeyShortcut? = nil, action: @escaping () -> Void) {
        installHandler()
        actions[name] = action
        if !order.contains(name) { order.append(name) }
        if let data = UserDefaults.standard.data(forKey: storageKey(name)) {
            shortcuts[name] = (try? JSONDecoder().decode(HotKeyShortcut?.self, from: data)) ?? nil
        } else {
            shortcuts[name] = standard
        }
        apply(name)
    }

    /// nil turns the shortcut off.
    func set(_ shortcut: HotKeyShortcut?, for name: String) {
        shortcuts[name] = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: storageKey(name))
        }
        apply(name)
    }

    /// While a new shortcut is being recorded, none may fire.
    func suspend() {
        isSuspended = true
        for name in order { unregister(name) }
    }

    func resume() {
        isSuspended = false
        for name in order { apply(name) }
    }

    private func apply(_ name: String) {
        unregister(name)
        failed.remove(name)
        guard !isSuspended, let shortcut = shortcuts[name], let index = order.firstIndex(of: name) else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[name] = ref
        } else {
            failed.insert(name)
        }
    }

    private func unregister(_ name: String) {
        if let ref = refs.removeValue(forKey: name) {
            UnregisterEventHotKey(ref)
        }
    }

    fileprivate func fire(id: UInt32) {
        let index = Int(id) - 1
        guard order.indices.contains(index) else { return }
        actions[order[index]]?()
    }

    private func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A button that shows a command's shortcut, and records a new one when clicked.
struct ShortcutRecorder: View {
    let name: String
    @ObservedObject private var center = HotKeyCenter.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "Type a shortcut…" : center.shortcuts[name]?.display ?? "Record Shortcut")
                        .monospacedDigit()
                        .frame(minWidth: 120)
                }
                if center.shortcuts[name] != nil, !isRecording {
                    Button {
                        center.set(nil, for: name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Shortcut")
                }
            }
            if center.failed.contains(name) {
                Text("Another app is using this shortcut.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
            } else if let shortcut = HotKeyShortcut(event: event) {
                center.set(shortcut, for: name)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        center.resume()
    }
}
