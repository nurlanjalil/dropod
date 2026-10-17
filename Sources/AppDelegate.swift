import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var shortcutTaken = false
    private var clipboardHotKey: HotKey?
    private var clipboardShortcutTaken = false
    private let recorder = ShortcutRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        // Bring back last time's shelves, then tidy storage around what they still use.
        let inUse = ShelfManager.shared.restore()
        DropStore.clearUnused(keeping: inUse)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerShortcut()

        let watcher = DragWatcher.shared
        watcher.onOpenRequest = { point in ShelfManager.shared.openWhileDragging(at: point) }
        watcher.onDragEnded = { ShelfManager.shared.dragEnded() }
        watcher.start()

        ScreenshotWatcher.shared.onScreenshot = { url in ShelfManager.shared.screenshotTaken(url) }
        updateScreenshotWatching()
        ClipboardWatcher.shared.onText = { text, app, cut in ShelfManager.shared.textCopied(text, from: app, cut: cut) }
        if Settings.clipboardHistory { ClipboardWatcher.shared.start() }
        ShelfManager.shared.startExpiryChecks()
        LoginItem.setUpIfNeeded()

        if !Settings.welcomed {
            Settings.welcomed = true
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfManager.shared.saveNow()
    }

    /// Watches for screenshots only while something wants them.
    private func updateScreenshotWatching() {
        if Settings.screenshotsToClipboard || Settings.screenshotsToTab {
            if ScreenshotWatcher.shared.folder == nil { ScreenshotWatcher.shared.start() }
        } else {
            ScreenshotWatcher.shared.stop()
        }
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        shortcutTaken = false
        if let shortcut = Settings.shortcut {
            hotKey = HotKey(shortcut) { ShelfManager.shared.shortcutPressed() }
            shortcutTaken = hotKey == nil
        }
        clipboardHotKey = nil
        clipboardShortcutTaken = false
        if let shortcut = Settings.clipboardShortcut {
            clipboardHotKey = HotKey(shortcut) { ShelfManager.shared.openClipboard() }
            clipboardShortcutTaken = clipboardHotKey == nil
        }
    }

    private func changeShortcut() {
        // Release the current shortcuts so they can be pressed in the recorder.
        hotKey = nil
        clipboardHotKey = nil
        recorder.record(current: Settings.shortcut) { [weak self] result in
            switch result {
            case .set(let shortcut): Settings.shortcut = shortcut
            case .off: Settings.shortcut = nil
            case .reset: Settings.shortcut = .default
            case .cancelled: break
            }
            self?.registerShortcut()
        }
    }

    private func changeClipboardShortcut() {
        hotKey = nil
        clipboardHotKey = nil
        recorder.record(current: Settings.clipboardShortcut, default: .clipboard, title: "Clipboard Shortcut") { [weak self] result in
            switch result {
            case .set(let shortcut): Settings.clipboardShortcut = shortcut
            case .off: Settings.clipboardShortcut = nil
            case .reset: Settings.clipboardShortcut = .clipboard
            case .cancelled: break
            }
            self?.registerShortcut()
        }
    }

    private static func shortcutTitle(_ label: String, _ shortcut: Shortcut?, taken: Bool) -> String {
        guard let shortcut else { return "\(label): Off…" }
        return taken ? "\(label) \(shortcut.display) Is Used by Another App…" : "\(label): \(shortcut.display)…"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = ShelfManager.shared

        let window = manager.window
        menu.addItem(ActionItem("New Tab", symbol: "plus.rectangle.on.rectangle") {
            manager.newTab(near: Self.screenCenter)
        })
        if !manager.tabs.isEmpty {
            menu.addItem(ActionItem(window.isOnScreen ? "Hide Dropod" : "Show Dropod",
                                    symbol: window.isOnScreen ? "eye.slash" : "eye") { manager.toggleVisibility() })
            if window.isOnScreen {
                menu.addItem(ActionItem(window.isCollapsed ? "Expand" : "Collapse",
                                        symbol: window.isCollapsed ? "chevron.up" : "chevron.down") {
                    window.setCollapsed(!window.isCollapsed)
                })
            }
            let anyPinned = manager.tabs.contains { $0.isPinned }
            if manager.tabs.contains(where: { !$0.isPinned }) {
                menu.addItem(ActionItem(anyPinned ? "Close Unpinned Tabs" : "Close All Tabs",
                                        symbol: "xmark.rectangle") { manager.closeUnpinned() })
            }

            // Every tab by name: click to open it.
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Tabs"))
            for shelf in manager.tabs {
                let item = ActionItem(shelf.displayTitle) { manager.show(shelf) }
                item.image = colorDot(shelf.color.color)
                if shelf.isPinned {
                    item.badge = NSMenuItemBadge(string: "Pinned")
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Open Dropod While Dragging"))
        let shake = ActionItem("Shake the Pointer") { Settings.shakeToOpen.toggle() }
        shake.state = Settings.shakeToOpen ? .on : .off
        menu.addItem(shake)
        let shift = ActionItem("Press ⇧ Shift") { Settings.shiftToOpen.toggle() }
        shift.state = Settings.shiftToOpen ? .on : .off
        menu.addItem(shift)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Screenshots"))
        let toClipboard = ActionItem("Copy to Clipboard") { [weak self] in
            Settings.screenshotsToClipboard.toggle()
            self?.updateScreenshotWatching()
        }
        toClipboard.state = Settings.screenshotsToClipboard ? .on : .off
        menu.addItem(toClipboard)
        let toTab = ActionItem("Add to Screenshots Tab") { [weak self] in
            Settings.screenshotsToTab.toggle()
            self?.updateScreenshotWatching()
            manager.removeUnusedSystemTabs()
        }
        toTab.state = Settings.screenshotsToTab ? .on : .off
        menu.addItem(toTab)
        // How long screenshots stay in the tab (the files themselves are never touched).
        let keep = NSMenuItem(title: "Keep in Tab", action: nil, keyEquivalent: "")
        keep.submenu = NSMenu()
        let durations: [(String, TimeInterval)] = [("1 Hour", 3_600), ("1 Day", 86_400), ("3 Days", 259_200),
                                                   ("1 Week", 604_800), ("Forever", 0)]
        for (title, seconds) in durations {
            let option = ActionItem(title) {
                Settings.screenshotRetention = seconds
                ShelfManager.shared.removeExpiredScreenshots()
            }
            option.state = Settings.screenshotRetention == seconds ? .on : .off
            keep.submenu?.addItem(option)
        }
        menu.addItem(keep)
        if let shots = manager.tabs.first(where: { $0.isScreenshots }), !shots.items.isEmpty {
            menu.addItem(ActionItem("Clear Screenshots…", symbol: "trash") { manager.clearScreenshots() })
        }
        let instant = ActionItem("Instant (No Floating Thumbnail)") {
            Settings.instantScreenshots.toggle()
            ScreenshotWatcher.setInstant(Settings.instantScreenshots)
        }
        instant.state = Settings.instantScreenshots ? .on : .off
        menu.addItem(instant)
        if let folder = ScreenshotWatcher.shared.folder {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shown = folder.path.hasPrefix(home) ? "~" + folder.path.dropFirst(home.count) : folder.path
            let watching = NSMenuItem(title: "Watching \(shown)", action: nil, keyEquivalent: "")
            watching.isEnabled = false
            menu.addItem(watching)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Clipboard"))
        let history = ActionItem("Keep Copied Text") {
            Settings.clipboardHistory.toggle()
            if Settings.clipboardHistory { ClipboardWatcher.shared.start() } else { ClipboardWatcher.shared.stop() }
            manager.removeUnusedSystemTabs()
        }
        history.state = Settings.clipboardHistory ? .on : .off
        menu.addItem(history)
        let keepClips = NSMenuItem(title: "Keep Clips", action: nil, keyEquivalent: "")
        keepClips.submenu = NSMenu()
        let clipDurations: [(String, TimeInterval)] = [("1 Day", 86_400), ("1 Week", 604_800), ("1 Month", 2_592_000),
                                                       ("Until the Limit", 0)]
        for (title, seconds) in clipDurations {
            let option = ActionItem(title) {
                Settings.clipRetention = seconds
                ShelfManager.shared.removeExpiredClips()
            }
            option.state = Settings.clipRetention == seconds ? .on : .off
            keepClips.submenu?.addItem(option)
        }
        keepClips.submenu?.addItem(.separator())
        for limit in [100, 200, 500] {
            let option = ActionItem("At Most \(limit) Clips") {
                Settings.clipLimit = limit
                ShelfManager.shared.removeExpiredClips()
            }
            option.state = Settings.clipLimit == limit ? .on : .off
            keepClips.submenu?.addItem(option)
        }
        menu.addItem(keepClips)
        if let clips = manager.clipboardTab, clips.items.contains(where: { !$0.isPinned }) {
            menu.addItem(ActionItem("Clear Clips…", symbol: "trash") { manager.clearClips() })
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem(Self.shortcutTitle("Shortcut", Settings.shortcut, taken: shortcutTaken),
                                symbol: shortcutTaken ? "exclamationmark.triangle" : "keyboard") { [weak self] in
            self?.changeShortcut()
        })
        menu.addItem(ActionItem(Self.shortcutTitle("Clipboard Shortcut", Settings.clipboardShortcut, taken: clipboardShortcutTaken),
                                symbol: clipboardShortcutTaken ? "exclamationmark.triangle" : "list.clipboard") { [weak self] in
            self?.changeClipboardShortcut()
        })
        let removeItem = ActionItem("Remove Items After Dragging Out") {
            Settings.removeAfterDragOut.toggle()
        }
        removeItem.state = Settings.removeAfterDragOut ? .on : .off
        menu.addItem(removeItem)

        menu.addItem(.separator())
        if !LoginItem.isInstalled {
            let login = NSMenuItem(title: "Open at Login (Install to Applications First)", action: nil, keyEquivalent: "")
            login.isEnabled = false
            menu.addItem(login)
        } else if LoginItem.needsApproval {
            menu.addItem(ActionItem("Open at Login: Allow in System Settings…", symbol: "exclamationmark.triangle") {
                LoginItem.openSystemSettings()
            })
        } else {
            let login = ActionItem("Open at Login") { LoginItem.toggle() }
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(withTitle: "Quit Dropod", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private static var screenCenter: NSPoint {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Welcome

    private func showWelcome() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Dropod is ready"
        let key = Settings.shortcut?.display ?? Shortcut.default.display
        alert.informativeText = """
            Dropod lives in the menu bar, behind the tray icon.

            While dragging something, shake the pointer (or press \(key)) and Dropod \
            appears right beside it with a fresh tab. Drop files on it, and drag them out \
            whenever you need them.

            Press \(key) any other time to collapse or expand the Dropod window.

            You can change the shortcut from the menu bar icon.
            """
        alert.addButton(withTitle: "Open Dropod")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            ShelfManager.shared.newTab(near: Self.screenCenter)
        }
    }
}
