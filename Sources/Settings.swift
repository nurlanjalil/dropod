import AppKit

/// User preferences, kept in UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: ["removeAfterDragOut": true, "shakeToOpen": true, "shiftToOpen": false,
                                     "screenshotsToClipboard": true, "screenshotsToTab": true,
                                     "instantScreenshots": false, "screenshotRetention": 86_400.0,
                                     "clipboardHistory": true, "clipRetention": 604_800.0, "clipLimit": 200])
    }

    /// Copied text is kept in the Clipboard tab.
    static var clipboardHistory: Bool {
        get { defaults.bool(forKey: "clipboardHistory") }
        set { defaults.set(newValue, forKey: "clipboardHistory") }
    }

    /// How long clips are kept, in seconds; 0 keeps them until the limit is reached.
    static var clipRetention: TimeInterval {
        get { defaults.double(forKey: "clipRetention") }
        set { defaults.set(newValue, forKey: "clipRetention") }
    }

    /// The most clips kept (pinned clips don't count).
    static var clipLimit: Int {
        get { defaults.integer(forKey: "clipLimit") }
        set { defaults.set(newValue, forKey: "clipLimit") }
    }

    /// How long screenshots stay in the Screenshots tab, in seconds; 0 keeps them forever.
    static var screenshotRetention: TimeInterval {
        get { defaults.double(forKey: "screenshotRetention") }
        set { defaults.set(newValue, forKey: "screenshotRetention") }
    }

    /// New screenshots are copied to the clipboard.
    static var screenshotsToClipboard: Bool {
        get { defaults.bool(forKey: "screenshotsToClipboard") }
        set { defaults.set(newValue, forKey: "screenshotsToClipboard") }
    }

    /// New screenshots are added to the Screenshots tab.
    static var screenshotsToTab: Bool {
        get { defaults.bool(forKey: "screenshotsToTab") }
        set { defaults.set(newValue, forKey: "screenshotsToTab") }
    }

    /// macOS's floating thumbnail is turned off, so screenshots are saved instantly.
    static var instantScreenshots: Bool {
        get { defaults.bool(forKey: "instantScreenshots") }
        set { defaults.set(newValue, forKey: "instantScreenshots") }
    }

    /// Shaking the pointer while dragging opens a shelf.
    static var shakeToOpen: Bool {
        get { defaults.bool(forKey: "shakeToOpen") }
        set { defaults.set(newValue, forKey: "shakeToOpen") }
    }

    /// Pressing ⇧ while dragging opens a shelf.
    static var shiftToOpen: Bool {
        get { defaults.bool(forKey: "shiftToOpen") }
        set { defaults.set(newValue, forKey: "shiftToOpen") }
    }

    /// Items leave the shelf once they are dragged out somewhere.
    static var removeAfterDragOut: Bool {
        get { defaults.bool(forKey: "removeAfterDragOut") }
        set { defaults.set(newValue, forKey: "removeAfterDragOut") }
    }

    /// Open at Login was switched on automatically once (the first run from /Applications).
    static var loginItemSetUp: Bool {
        get { defaults.bool(forKey: "loginItemSetUp") }
        set { defaults.set(newValue, forKey: "loginItemSetUp") }
    }

    /// Whether the first-run welcome has been shown.
    static var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }

    /// The global shortcut, or nil when the user turned it off.
    static var shortcut: Shortcut? {
        get { savedShortcut("shortcut", default: .default) }
        set { saveShortcut(newValue, as: "shortcut") }
    }

    /// The shortcut that opens the Clipboard tab, or nil when turned off.
    static var clipboardShortcut: Shortcut? {
        get { savedShortcut("clipboardShortcut", default: .clipboard) }
        set { saveShortcut(newValue, as: "clipboardShortcut") }
    }

    private static func savedShortcut(_ key: String, default fallback: Shortcut) -> Shortcut? {
        if defaults.bool(forKey: key + "Off") { return nil }
        guard let saved = defaults.dictionary(forKey: key),
              let keyCode = saved["keyCode"] as? Int,
              let modifiers = saved["modifiers"] as? UInt,
              let name = saved["key"] as? String
        else { return fallback }
        return Shortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), key: name)
    }

    private static func saveShortcut(_ shortcut: Shortcut?, as key: String) {
        defaults.set(shortcut == nil, forKey: key + "Off")
        if let shortcut {
            defaults.set(["keyCode": shortcut.keyCode,
                          "modifiers": shortcut.modifiers.rawValue,
                          "key": shortcut.key], forKey: key)
        }
    }
}
