import AppKit

/// The front door: the shortcut, shakes while dragging, and saving and restoring the
/// Dropod window and its tabs.
final class ShelfManager {
    static let shared = ShelfManager()

    let window = DropodWindow()
    var tabs: [ShelfController] { window.tabs }

    /// Counts drops anywhere in Dropod, so a shake can tell whether its drag dropped something.
    private(set) var dropCount = 0
    func noteDrop() { dropCount += 1 }

    /// One shortcut does the obvious thing: while dragging, open the window beside the
    /// pointer; otherwise make a first tab, bring the window back, or collapse and expand it.
    func shortcutPressed() {
        if DragWatcher.shared.isDragging {
            // Dragging something out of Dropod: the window is already here.
            guard !DragWatcher.shared.startedInDropod else { return }
            DragWatcher.shared.markOpened()
            openWhileDragging(at: NSEvent.mouseLocation)
        } else if tabs.isEmpty {
            newTab(near: NSEvent.mouseLocation)
        } else if !window.isOnScreen {
            window.setCollapsed(false, animated: false)
            window.show()
        } else {
            window.setCollapsed(!window.isCollapsed)
        }
    }

    /// A new empty tab. When the window isn't on screen yet, it appears centred on `point`.
    func newTab(near point: NSPoint) {
        let wasOnScreen = window.isOnScreen
        window.newTab()
        window.setCollapsed(false, animated: wasOnScreen)
        if !wasOnScreen {
            let size = window.expandedSize
            window.move(topLeft: NSPoint(x: point.x - size.width / 2, y: point.y + size.height / 2), animated: false)
        }
        window.show()
    }

    /// Opens a tab and brings the window forward, expanded.
    func show(_ shelf: ShelfController) {
        window.activate(shelf)
        window.setCollapsed(false, animated: window.isOnScreen)
        window.show()
        window.panel.orderFrontRegardless()
    }

    func toggleVisibility() {
        if window.isOnScreen { window.hide() } else { window.show() }
    }

    /// Closes every unpinned tab. Pinned ones stay; close those with their own ✕.
    func closeUnpinned() {
        tabs.filter { !$0.isPinned }.forEach { $0.close() }
    }

    // MARK: Screenshots

    /// A new screenshot: copied to the clipboard and/or added to the Screenshots tab.
    /// Stays quiet: the capsule pulses or a toast appears; the window never pops up over your work.
    func screenshotTaken(_ url: URL) {
        if Settings.screenshotsToClipboard { ScreenshotWatcher.copyToClipboard(url) }
        guard Settings.screenshotsToTab else { return }

        let wasEmpty = tabs.isEmpty
        let tab = tabs.first { $0.isScreenshots } ?? makeScreenshotsTab()
        tab.add([ShelfItem(url: url)])

        if !window.isOnScreen {
            window.setCollapsed(true, animated: false)
            if wasEmpty, let visible = NSScreen.main?.visibleFrame {
                // First time: a capsule in the top-right corner, out of the way.
                window.move(topLeft: NSPoint(x: visible.maxX - window.collapsedSize.width - 16, y: visible.maxY - 12),
                            animated: false)
            }
            window.show()
        }
        if window.isCollapsed {
            window.announce(tab, Settings.screenshotsToClipboard ? "Screenshot copied" : "Screenshot saved")
        } else if window.active !== tab {
            window.active?.view.flash(Settings.screenshotsToClipboard ? "Screenshot copied · added to Screenshots"
                                                                      : "Screenshot added to Screenshots")
        }
    }

    // MARK: Clipboard

    var clipboardTab: ShelfController? { tabs.first { $0.isClipboard } }

    /// Copied text goes into the Clipboard tab, quietly: the window doesn't change.
    func textCopied(_ text: String, from app: NSRunningApplication?, cut: Bool = false) {
        guard Settings.clipboardHistory else { return }
        // Text copied from Dropod's own clips is already there.
        if let source = app?.bundleIdentifier, source == Bundle.main.bundleIdentifier,
           clipboardTab?.items.contains(where: { $0.text == text }) == true {
            return
        }
        let tab = clipboardTab ?? makeClipboardTab()
        tab.addClip(text, from: app, cut: cut)
        removeExpiredClips()
        window.announce(tab, TextCard.title(for: text))
    }

    private func makeClipboardTab() -> ShelfController {
        let tab = ShelfController()
        tab.isClipboard = true
        tab.rename(to: "Clipboard")
        tab.color = .orange
        tab.isPinned = true
        window.add(tab, activate: tabs.isEmpty)
        return tab
    }

    /// Clips older than the chosen time, or beyond the newest ones allowed, leave the tab.
    /// Pinned clips always stay.
    func removeExpiredClips() {
        guard let tab = clipboardTab else { return }
        let retention = Settings.clipRetention
        var expired = tab.items.filter { !$0.isPinned && retention > 0 && Date().timeIntervalSince($0.addedAt) > retention }
        let kept = tab.items.filter { item in !item.isPinned && !expired.contains { $0 === item } }
        if kept.count > Settings.clipLimit { expired += kept.suffix(kept.count - Settings.clipLimit) }  // the oldest
        if !expired.isEmpty { tab.remove(expired) }
    }

    /// Removes every clip that isn't pinned, after asking.
    func clearClips() {
        guard let tab = clipboardTab else { return }
        let clips = tab.items.filter { !$0.isPinned }
        guard !clips.isEmpty else { return }
        let pinned = tab.items.count - clips.count
        let detail = pinned == 0 ? "This can't be undone."
            : "Pinned clips (\(pinned)) stay. This can't be undone."
        guard confirm("Clear \(clips.count == 1 ? "1 clip" : "\(clips.count) clips")?", detail, button: "Clear Clips")
        else { return }
        tab.remove(clips)
        removeUnusedSystemTabs()
    }

    /// Empties the Screenshots tab, after asking. The files stay in the screenshots folder.
    func clearScreenshots() {
        guard let tab = tabs.first(where: { $0.isScreenshots }), !tab.items.isEmpty else { return }
        let count = tab.items.count
        guard confirm("Clear \(count == 1 ? "1 screenshot" : "\(count) screenshots") from the tab?",
                      "The files stay in your screenshots folder.", button: "Clear")
        else { return }
        tab.remove(tab.items)
        removeUnusedSystemTabs()
    }

    /// Screenshots and Clipboard only go away when their feature is off and they're empty.
    func removeUnusedSystemTabs() {
        if let clips = clipboardTab, !Settings.clipboardHistory, clips.items.isEmpty {
            window.closeTab(clips, undoable: false, force: true)
        }
        if let shots = tabs.first(where: { $0.isScreenshots }), !Settings.screenshotsToTab, shots.items.isEmpty {
            window.closeTab(shots, undoable: false, force: true)
        }
    }

    private func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// How things were before ⌃⌘V, to put back after a clip is chosen with ↩.
    private struct ClipboardSession {
        let app: NSRunningApplication?
        let topLeft: NSPoint
        let wasOnScreen: Bool
        let wasCollapsed: Bool
        weak var previous: ShelfController?
    }

    private var clipSession: ClipboardSession?

    /// ⌃⌘V: Dropod on the Clipboard tab, search field ready.
    func openClipboard() {
        let front = NSWorkspace.shared.frontmostApplication
        if clipSession == nil {
            clipSession = ClipboardSession(app: front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front,
                                           topLeft: window.topLeft, wasOnScreen: window.isOnScreen,
                                           wasCollapsed: window.isCollapsed, previous: window.active)
        }
        let tab = clipboardTab ?? makeClipboardTab()
        let wasOnScreen = window.isOnScreen
        window.activate(tab)
        window.setCollapsed(false, animated: wasOnScreen)
        if !wasOnScreen {
            let size = window.expandedSize
            let point = NSEvent.mouseLocation
            window.move(topLeft: NSPoint(x: point.x - size.width / 2, y: point.y + size.height / 2), animated: false)
        }
        window.show()
        window.panel.makeKey()
        tab.view.focusSearch()
    }

    /// After ↩ (or Esc): the window goes back to how it was, and the app you were in comes
    /// back to the front so ⌘V pastes straight away.
    func endClipboard() {
        guard let session = clipSession else {
            window.setCollapsed(true)
            return
        }
        clipSession = nil
        if !session.wasOnScreen {
            window.hide()
        } else {
            if let previous = session.previous { window.activate(previous) }
            window.setCollapsed(session.wasCollapsed)
            window.move(topLeft: session.topLeft, animated: true)
        }
        session.app?.activate()
    }

    /// Clicking elsewhere ends a ⌃⌘V visit without putting anything back.
    func clipboardSessionInterrupted() { clipSession = nil }

    /// Takes screenshots older than the chosen time off the Screenshots tab.
    /// Only the tab changes; the files stay in the screenshots folder.
    func removeExpiredScreenshots() {
        let retention = Settings.screenshotRetention
        guard retention > 0, let tab = tabs.first(where: { $0.isScreenshots }) else { return }
        let expired = tab.items.filter { Date().timeIntervalSince($0.addedAt) > retention }
        if !expired.isEmpty { tab.remove(expired) }
    }

    private var expiryTimer: Timer?

    /// Checks for expired screenshots and clips now and every few minutes.
    func startExpiryChecks() {
        removeExpiredScreenshots()
        removeExpiredClips()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.removeExpiredScreenshots()
            self?.removeExpiredClips()
        }
    }

    private func makeScreenshotsTab() -> ShelfController {
        let tab = ShelfController()
        tab.isScreenshots = true
        tab.rename(to: "Screenshots")
        tab.color = .green
        tab.isPinned = true
        window.add(tab, activate: tabs.isEmpty)
        return tab
    }

    // MARK: Shaking while dragging

    /// How things were before a shake, to put back if the drag drops nothing.
    private struct DragSession {
        let topLeft: NSPoint
        let wasOnScreen: Bool
        let wasCollapsed: Bool
        weak var previous: ShelfController?
        let dropCount: Int
        let fresh: ShelfController
    }

    private var session: DragSession?

    /// The window opens beside the pointer, expanded, on a fresh tab for this drag.
    func openWhileDragging(at point: NSPoint) {
        guard session == nil else { return }
        session = DragSession(topLeft: window.topLeft, wasOnScreen: window.isOnScreen,
                              wasCollapsed: window.isCollapsed, previous: window.active,
                              dropCount: dropCount, fresh: window.newTab())
        session?.fresh.autoCloseIfEmpty = true
        window.setCollapsed(false, animated: window.isOnScreen)

        // Just to the right of the pointer, or to the left near the screen's right edge.
        let size = window.expandedSize
        let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let gap: CGFloat = 28
        let x = point.x + gap + size.width <= visible.maxX - 8 ? point.x + gap : point.x - gap - size.width
        window.move(topLeft: NSPoint(x: x, y: point.y + size.height / 2), animated: window.isOnScreen)
        window.show()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// After the drag: an unused fresh tab goes away, and if nothing was dropped anywhere,
    /// the window goes back to where and how it was.
    func dragEnded() {
        // Give a drop a moment to land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard let session else { return }
            self.session = nil
            let fresh = session.fresh
            fresh.autoCloseIfEmpty = false
            if fresh.items.isEmpty && !fresh.receivedDrop { window.closeTab(fresh, undoable: false) }
            guard dropCount == session.dropCount else { return }

            if !session.wasOnScreen {
                window.hide()
            } else {
                if let previous = session.previous { window.activate(previous) }
                window.setCollapsed(session.wasCollapsed)
                window.move(topLeft: session.topLeft, animated: true)
            }
        }
    }

    // MARK: Saving

    /// ~/Library/Application Support/Dropod/shelves.json
    private static let stateURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dropod/shelves.json")
    }()

    private var restoring = false
    private var pendingSave: DispatchWorkItem?

    /// Saves shortly after the last change, so a burst of changes is written once.
    func setNeedsSave() {
        guard !restoring else { return }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
    }

    /// Tabs with items, and pinned or named tabs even when empty, plus where the window is.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let kept = tabs.filter { !$0.items.isEmpty || $0.isPinned || $0.name != nil }
        let state = SavedState(x: window.topLeft.x, y: window.topLeft.y, collapsed: window.isCollapsed,
                               active: kept.firstIndex { $0 === window.active },
                               tabs: kept.map(SavedShelf.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    /// Brings back the window and its tabs from last time. Older versions saved separate
    /// shelves; those become tabs. Returns every file path referred to, so storage cleanup keeps them.
    @discardableResult
    func restore() -> Set<String> {
        guard let data = try? Data(contentsOf: Self.stateURL) else { return [] }
        let state: SavedState
        if let current = try? JSONDecoder().decode(SavedState.self, from: data) {
            state = current
        } else if let shelves = try? JSONDecoder().decode([SavedShelf].self, from: data) {
            state = SavedState(x: shelves.first?.x ?? 0, y: shelves.first?.y ?? 0, collapsed: false,
                               active: 0, tabs: shelves)
        } else {
            return []
        }

        restoring = true
        defer { restoring = false }
        var referenced = Set<String>()
        var restored: [Int: ShelfController] = [:]
        for (index, entry) in state.tabs.enumerated() {
            entry.items.compactMap(\.path).forEach { referenced.insert($0) }
            let items = entry.items.compactMap { $0.restore() }
            guard !items.isEmpty || entry.pinned || entry.name != nil else { continue }

            let shelf = ShelfController(id: entry.id)
            shelf.color = ShelfColor(rawValue: entry.color) ?? .blue
            shelf.rename(to: entry.name ?? "")
            shelf.isPinned = entry.pinned
            shelf.isScreenshots = entry.screenshots ?? false
            shelf.isClipboard = entry.clipboard ?? false
            shelf.add(items)
            shelf.isExpanded = entry.expanded
            window.add(shelf, activate: false)
            restored[index] = shelf
        }
        guard !tabs.isEmpty else { return referenced }

        if let active = state.active.flatMap({ restored[$0] }) { window.activate(active) }
        window.setCollapsed(state.collapsed, animated: false)
        window.move(topLeft: NSPoint(x: state.x, y: state.y), animated: false)
        window.show()
        return referenced
    }
}

/// The window as written to shelves.json.
private struct SavedState: Codable {
    /// Top-left corner on screen.
    var x: Double
    var y: Double
    var collapsed: Bool
    var active: Int?
    var tabs: [SavedShelf]
}

/// A tab as written to shelves.json. Older versions saved each shelf with its own position.
private struct SavedShelf: Codable {
    var id: UUID
    var name: String?
    var color: String
    var pinned: Bool
    var expanded: Bool
    /// The tab new screenshots go to.
    var screenshots: Bool?
    /// The tab copied text is kept in.
    var clipboard: Bool?
    var x: Double?
    var y: Double?
    var items: [SavedItem]

    init(_ shelf: ShelfController) {
        id = shelf.id
        name = shelf.name
        color = shelf.color.rawValue
        pinned = shelf.isPinned
        expanded = shelf.isExpanded
        screenshots = shelf.isScreenshots ? true : nil
        clipboard = shelf.isClipboard ? true : nil
        items = shelf.items.map(SavedItem.init)
    }
}

private struct SavedItem: Codable {
    /// The file; nil for a text card.
    var path: String?
    /// A text card's text.
    var note: String?
    /// A pinned clip.
    var pinned: Bool?
    /// The app a clip was copied from.
    var source: String?
    /// The clip was cut at 100,000 characters.
    var cut: Bool?
    /// Set for dropped links, so dragging out still gives a browser the page.
    var link: String?
    /// Set for dropped text, which is re-read from its file.
    var isText: Bool?
    /// When it was added; older saves don't have it.
    var added: Date?

    init(_ item: ShelfItem) {
        path = item.url?.path
        added = item.addedAt
        pinned = item.isPinned ? true : nil
        source = item.sourceApp
        cut = item.wasCut ? true : nil
        switch item.content {
        case .file: break
        case .note(let text): note = text
        case .text: isText = true
        case .link(let url): link = url.absoluteString
        }
    }

    /// The item again, or nil if its file is gone.
    func restore() -> ShelfItem? {
        if let note {
            let item = ShelfItem(note: note, addedAt: added ?? Date(), sourceApp: source)
            item.isPinned = pinned ?? false
            item.wasCut = cut ?? false
            return item
        }
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Older saves: fall back to when the file was created.
        let addedAt = added ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        if let link, let linkURL = URL(string: link) {
            return ShelfItem(url: url, content: .link(linkURL), addedAt: addedAt)
        }
        if isText == true, let text = try? String(contentsOf: url, encoding: .utf8) {
            return ShelfItem(url: url, content: .text(text), addedAt: addedAt)
        }
        return ShelfItem(url: url, addedAt: addedAt)
    }
}
