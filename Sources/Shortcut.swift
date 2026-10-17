import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, such as ⇧⌘Space.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// What is printed on the key, such as "Space" or "D".
    var key: String

    static let `default` = Shortcut(keyCode: kVK_Space, modifiers: [.command, .shift], key: "Space")
    /// Opens the Clipboard tab. (⇧⌘V and ⌥⌘V are avoided: apps use them for pasting styles
    /// and Finder for moving files.)
    static let clipboard = Shortcut(keyCode: kVK_ANSI_V, modifiers: [.control, .command], key: "V")

    var display: String { Shortcut.symbols(modifiers) + key }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// Modifier symbols in the order macOS menus use.
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
}

extension Shortcut {
    /// A shortcut from a key press. Requires ⌘, ⌥ or ⌃, so typing is never hijacked.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.subtracting(.shift).isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: flags, key: Shortcut.keyName(event))
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// A small window that records a new shortcut.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    enum Result { case set(Shortcut), off, reset, cancelled }

    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((Result) -> Void)?
    private var current: Shortcut?
    private let keysLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    func record(current: Shortcut?, default fallback: Shortcut = .default, title: String = "Dropod Shortcut",
                completion: @escaping (Result) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        self.current = current
        self.completion = completion

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let prompt = NSTextField(labelWithString: "Press the new shortcut")
        prompt.font = .systemFont(ofSize: 13, weight: .medium)
        keysLabel.font = .systemFont(ofSize: 30, weight: .medium)
        keysLabel.stringValue = current?.display ?? "Off"
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "Use ⌘, ⌥ or ⌃ with a key. Esc cancels."

        let turnOff = NSButton(title: "Turn Off", target: self, action: #selector(turnOff))
        let reset = NSButton(title: "Use \(fallback.display)", target: self, action: #selector(useDefault))
        let buttons = NSStackView(views: [turnOff, reset])
        buttons.spacing = 8

        let stack = NSStackView(views: [prompt, keysLabel, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.setCustomSpacing(16, after: hintLabel)
        panel.contentView = stack

        self.panel = panel
        NSApp.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let held = Shortcut.symbols(event.modifierFlags)
            keysLabel.stringValue = held.isEmpty ? (current?.display ?? "Off") : held
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            finish(.cancelled)
            return nil
        }
        guard let shortcut = Shortcut(event: event) else {
            hintLabel.stringValue = "Include ⌘, ⌥ or ⌃ in the shortcut."
            hintLabel.textColor = .systemRed
            NSSound.beep()
            return nil
        }
        finish(.set(shortcut))
        return nil
    }

    @objc private func turnOff() { finish(.off) }
    @objc private func useDefault() { finish(.reset) }

    func windowWillClose(_ notification: Notification) { finish(.cancelled) }

    private func finish(_ result: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let completion = self.completion
        self.completion = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        hintLabel.textColor = .secondaryLabelColor
        completion?(result)
    }
}
