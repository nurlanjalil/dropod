import AppKit
import QuartzCore

/// The one Dropod window: a tab bar on top, the active tab's content below, and a small
/// capsule it collapses into. Each tab is a `ShelfController`.
final class DropodWindow: NSObject, NSWindowDelegate {

    let panel: ShelfPanel
    /// Liquid Glass on macOS 26, frosted blur before that.
    private let backdrop: NSView
    private let root = RootView()
    private let tabBar = TabBar()
    private let capsule = CapsuleView()
    private let undoToast = UndoToast()
    /// Shows clips and text cards in full, beside the window.
    let peek = PeekController()

    private(set) var tabs: [ShelfController] = []
    private(set) var active: ShelfController?
    private(set) var isCollapsed = false
    /// Shown on screen (expanded or collapsed), as opposed to hidden.
    private(set) var isOnScreen = false
    /// Whether the capsule grows to the left when a chip unfolds (it grows towards the middle
    /// of the screen). Decided while it's at rest, so unfolding and folding mirror each other.
    private var capsuleGrowsLeft = false

    override init() {
        let size = NSSize(width: ShelfController.width, height: TabBar.height + ShelfController.height(for: 0))
        root.frame = NSRect(origin: .zero, size: size)
        panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: size))
        backdrop = Backdrop.make(around: root, radius: ShelfView.cornerRadius)
        super.init()
        panel.host = self
        panel.delegate = self
        panel.contentView = backdrop
        tabBar.host = self
        capsule.host = self
        capsule.isHidden = true
        undoToast.isHidden = true
        undoToast.onUndo = { [weak self] in self?.undoClose() }
        root.addSubview(tabBar)
        root.addSubview(capsule)
        root.addSubview(undoToast)
        root.onLayout = { [weak self] in self?.layoutRoot() }
    }

    // MARK: Tabs

    func add(_ shelf: ShelfController, activate: Bool) {
        shelf.host = self
        tabs.append(shelf)
        if activate || active == nil { self.activate(shelf) } else { refreshChrome() }
    }

    /// A new, empty tab in the next unused colour, made active.
    @discardableResult
    func newTab() -> ShelfController {
        let shelf = ShelfController()
        let used = Set(tabs.map(\.color))
        shelf.color = ShelfColor.newTabOrder.first { !used.contains($0) } ?? ShelfColor.newTabOrder[tabs.count % ShelfColor.newTabOrder.count]
        add(shelf, activate: true)
        return shelf
    }

    /// Shows a tab's content, crossfading from the previous one.
    func activate(_ shelf: ShelfController) {
        guard tabs.contains(where: { $0 === shelf }) else { return }
        let previous = active
        active = shelf
        if previous !== shelf {
            peek.close()
            let incoming = shelf.view
            incoming.frame = contentFrame(in: root.bounds)
            root.addSubview(incoming, positioned: .below, relativeTo: capsule)
            incoming.isHidden = isCollapsed
            let animated = isOnScreen && !isCollapsed && !Motion.reduced
            if let outgoing = previous?.view {
                if animated {
                    incoming.alphaValue = 0
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.18
                        incoming.animator().alphaValue = 1
                        outgoing.animator().alphaValue = 0
                    }, completionHandler: { [weak self] in
                        if self?.active?.view !== outgoing { outgoing.removeFromSuperview() }
                        outgoing.alphaValue = 1
                    })
                } else {
                    outgoing.removeFromSuperview()
                }
            }
            incoming.alphaValue = animated ? incoming.alphaValue : 1
        }
        Backdrop.tint(backdrop, with: shelf.color.color)
        refreshChrome()
        updateFrame(animated: isOnScreen)
        ShelfManager.shared.setNeedsSave()
    }

    /// Closes a tab. Screenshots and Clipboard can't be closed this way (only `force` removes
    /// them, when their feature is off and they're empty). A tab with something in it can be
    /// brought back with Undo for a few seconds.
    func closeTab(_ shelf: ShelfController, undoable: Bool = true, force: Bool = false) {
        guard force || !shelf.isSystem else { return }
        guard let index = tabs.firstIndex(where: { $0 === shelf }) else { return }
        finishPendingUndo()
        if peek.isShowing, active === shelf { peek.close() }
        tabs.remove(at: index)
        shelf.host = nil
        if active === shelf {
            active = nil
            shelf.view.removeFromSuperview()
            if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)]) }
        }
        if undoable && (!shelf.items.isEmpty || shelf.name != nil) {
            offerUndo(for: shelf, at: index)
        } else if tabs.isEmpty {
            hide()
        }
        refreshChrome()
        updateFrame(animated: isOnScreen)
        ShelfManager.shared.setNeedsSave()
    }

    // MARK: Undo closing a tab

    private struct ClosedTab {
        let shelf: ShelfController
        let index: Int
        let timer: Timer
    }

    private var closed: ClosedTab?
    /// Catches ⌘Z while Undo is offered, even if a text field has the keyboard.
    private var undoKeyMonitor: Any?

    /// While Undo is offered for the last tab, the window shrinks to just the Undo bar.
    private var showsOnlyUndo: Bool { tabs.isEmpty && closed != nil }

    private func offerUndo(for shelf: ShelfController, at index: Int) {
        let timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.finishPendingUndo() }
        closed = ClosedTab(shelf: shelf, index: index, timer: timer)
        undoToast.show("Closed \u{2018}\(shelf.displayTitle)\u{2019}")
        root.needsLayout = true
        // You just closed a tab here, so take the keyboard: ⌘Z must reach Dropod, not the app behind.
        if isOnScreen { panel.makeKey() }
        if undoKeyMonitor == nil {
            undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "z", self?.closed != nil else { return event }
                self?.undoClose()
                return nil
            }
        }
    }

    private func stopUndoKeys() {
        if let undoKeyMonitor { NSEvent.removeMonitor(undoKeyMonitor) }
        undoKeyMonitor = nil
    }

    /// ⌘Z or the Undo button: the tab comes back where it was, with everything in it.
    func undoClose() {
        guard let closed else { return }
        closed.timer.invalidate()
        self.closed = nil
        stopUndoKeys()
        undoToast.hide()
        tabs.insert(closed.shelf, at: min(closed.index, tabs.count))
        closed.shelf.host = self
        if isCollapsed { setCollapsed(false) }
        activate(closed.shelf)
        if !isOnScreen { show() }
        ShelfManager.shared.setNeedsSave()
    }

    /// The Undo time is over: the tab is gone for good (and the window, if it was the last).
    private func finishPendingUndo() {
        guard let closed else { return }
        closed.timer.invalidate()
        self.closed = nil
        stopUndoKeys()
        undoToast.hide()
        if tabs.isEmpty { hide() }
        root.needsLayout = true
    }

    func isShowing(_ shelf: ShelfController) -> Bool { isOnScreen && !isCollapsed && shelf === active }

    func tabContentChanged(_ shelf: ShelfController) {
        refreshChrome()
        if shelf === active { updateFrame(animated: isOnScreen) }
    }

    func tabAppearanceChanged(_ shelf: ShelfController) {
        if shelf === active { Backdrop.tint(backdrop, with: shelf.color.color) }
        refreshChrome()
    }

    func beginRename(_ shelf: ShelfController) {
        guard !shelf.isSystem else { return }
        if isCollapsed { setCollapsed(false) }
        activate(shelf)
        tabBar.beginRename(shelf)
    }

    private func refreshChrome() {
        tabBar.reload()
        capsule.reload()
        if isCollapsed { updateFrame(animated: isOnScreen) }
    }

    // MARK: Arrivals

    /// Something new arrived in a tab. While the window is collapsed or hidden it counts as
    /// unseen (a badge on the capsule), and on the capsule the tab's chip unfolds to say what
    /// came in. With the window open you can already see it, so nothing is counted.
    func announce(_ shelf: ShelfController, _ message: String) {
        guard !(isOnScreen && !isCollapsed) else { return }
        shelf.unseen += 1
        capsule.reload()
        if isOnScreen && isCollapsed { capsule.unfold(shelf, message: message) }
    }

    /// Opening Dropod counts as seeing everything that arrived.
    private func markAllSeen() {
        tabs.forEach { $0.unseen = 0 }
        capsule.foldNow()
        capsule.reload()
    }

    /// A chip's label came out or went back: the capsule changes width with it.
    func capsuleResized() {
        guard isCollapsed else { return }
        updateFrame(animated: isOnScreen)
    }

    // MARK: Showing, hiding, collapsing

    func show() {
        guard !tabs.isEmpty else { return }
        guard !isOnScreen else { return panel.orderFrontRegardless() }
        isOnScreen = true
        if !isCollapsed { markAllSeen() }
        updateFrame(animated: false)
        Motion.present(panel)
        ShelfManager.shared.setNeedsSave()
    }

    func hide() {
        guard isOnScreen else { return }
        peek.close()
        isOnScreen = false
        Motion.dismiss(panel)
        ShelfManager.shared.setNeedsSave()
    }

    /// Shrinks into the capsule (or grows back), keeping the top-left corner in place.
    func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard collapsed != isCollapsed else { return }
        if collapsed { peek.close() }
        isCollapsed = collapsed
        if !collapsed { markAllSeen() }
        capsule.reload()
        let incoming: [NSView] = collapsed ? [capsule] : [tabBar] + [active?.view].compactMap { $0 }
        let outgoing: [NSView] = collapsed ? [tabBar] + [active?.view].compactMap { $0 } : [capsule]
        let fade = animated && isOnScreen
        incoming.forEach {
            $0.isHidden = false
            $0.alphaValue = fade ? 0 : 1
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade ? 0.18 : 0
            incoming.forEach { $0.animator().alphaValue = 1 }
            outgoing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard self?.isCollapsed == collapsed else { return }
            outgoing.forEach {
                $0.isHidden = true
                $0.alphaValue = 1
            }
        })
        if collapsed { panel.makeFirstResponder(nil) }
        updateFrame(animated: fade)
        ShelfManager.shared.setNeedsSave()
    }

    // MARK: Geometry

    var topLeft: NSPoint { NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }

    /// The window's size when expanded on the active tab.
    var expandedSize: NSSize {
        let content = active?.contentSize ?? NSSize(width: ShelfController.width, height: ShelfController.height(for: 0))
        return NSSize(width: content.width, height: TabBar.height + content.height)
    }

    func move(topLeft point: NSPoint, animated: Bool) {
        var frame = panel.frame
        frame.origin = NSPoint(x: point.x, y: point.y - frame.height)
        setFrame(onScreen(frame), animated: animated)
    }

    /// The capsule's size: as wide as its chips (and any label that's out).
    var collapsedSize: NSSize { NSSize(width: capsule.preferredWidth, height: CapsuleView.height) }

    /// Grows or shrinks downwards and to the right, keeping the top-left corner in place.
    /// The capsule, once collapsed, grows sideways towards the middle of the screen instead.
    func updateFrame(animated: Bool) {
        let size = showsOnlyUndo ? NSSize(width: 250, height: 44) : isCollapsed ? collapsedSize : expandedSize
        var frame = panel.frame
        let resizingCapsule = isCollapsed && !showsOnlyUndo && frame.height == size.height
        if resizingCapsule, frame.width <= capsule.restWidth + 0.5, let visible = panel.screen?.visibleFrame {
            capsuleGrowsLeft = frame.midX > visible.midX
        }
        if resizingCapsule && capsuleGrowsLeft { frame.origin.x = frame.maxX - size.width }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        setFrame(onScreen(frame), animated: animated, duration: resizingCapsule ? 0.42 : 0.25)
    }

    /// The size the window should end up at; a resize animation that finishes after a newer
    /// size was set applies this one instead of leaving its own.
    private var targetFrame: NSRect?

    private func setFrame(_ frame: NSRect, animated: Bool, duration: TimeInterval = 0.25) {
        targetFrame = frame
        guard frame != panel.frame else { return }
        guard animated, !Motion.reduced else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            if peek.isShowing { peek.position(beside: panel) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = Motion.easeOut
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self, panel] in
            if let target = self?.targetFrame, panel.frame != target { panel.setFrame(target, display: true) }
            panel.invalidateShadow()
            // Keep Peek lined up with the window's new top edge.
            if let self, self.peek.isShowing { self.peek.position(beside: panel) }
        })
    }

    /// The frame moved just enough to sit fully inside the screen it is on.
    private func onScreen(_ rect: NSRect) -> NSRect {
        var frame = rect
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        return frame
    }

    private func contentFrame(in bounds: NSRect) -> NSRect {
        NSRect(x: 0, y: TabBar.height, width: bounds.width, height: max(0, bounds.height - TabBar.height))
    }

    private func layoutRoot() {
        tabBar.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: TabBar.height)
        active?.view.frame = contentFrame(in: root.bounds)
        capsule.frame = root.bounds
        if showsOnlyUndo {
            undoToast.frame = root.bounds
        } else {
            let width = min(undoToast.preferredWidth, root.bounds.width - 24)
            let y = isCollapsed ? (root.bounds.height - 28) / 2 : root.bounds.height - 40
            undoToast.frame = NSRect(x: (root.bounds.width - width) / 2, y: y, width: width, height: 28)
        }
    }

    func windowDidMove(_ notification: Notification) { ShelfManager.shared.setNeedsSave() }

    func windowDidResignKey(_ notification: Notification) { ShelfManager.shared.clipboardSessionInterrupted() }
}

/// The window's content: lays out its children whenever it changes size.
final class RootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Tab bar

/// Tabs as colour chips, plus ＋ (new tab), ⌄ (collapse) and ⋯ (actions).
/// Dragging anywhere on it, names included, moves the window.
final class TabBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 44

    weak var host: DropodWindow?

    private let scroll = NSScrollView()
    private let strip = WindowDragView()
    private let fadeMask = CAGradientLayer()
    private var chips: [TabChip] = []
    /// Screenshots and Clipboard: fixed icons at the left, always in view.
    private var fixedChips: [TabChip] { chips.filter { $0.shelf.isSystem } }
    /// Your own tabs, in the scrolling row.
    private var scrollingChips: [TabChip] { chips.filter { !$0.shelf.isSystem } }
    private let divider = NSBox()
    private let addButton = AddTabButton(symbol: "plus", tip: "New Tab")
    private let collapseButton = ToolbarButton(symbol: "chevron.down", tip: "Collapse")
    private let menuButton = ToolbarButton(symbol: "ellipsis", tip: "Actions")
    private let renameField = NSTextField()
    private weak var renaming: ShelfController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        scroll.wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]

        addButton.onDrop = { [weak self] pasteboard in
            guard let host = self?.host else { return false }
            let shelf = host.newTab()
            if shelf.receive(pasteboard) { return true }
            host.closeTab(shelf, undoable: false)
            return false
        }
        addButton.target = self
        addButton.action = #selector(addTab)
        collapseButton.target = self
        collapseButton.action = #selector(collapse)
        menuButton.target = self
        menuButton.action = #selector(showMenu)

        renameField.font = .systemFont(ofSize: 12, weight: .semibold)
        renameField.alignment = .center
        renameField.focusRingType = .none
        renameField.bezelStyle = .roundedBezel
        renameField.delegate = self
        renameField.isHidden = true
        divider.boxType = .separator

        [divider, scroll, addButton, collapseButton, menuButton, renameField].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func layout() {
        super.layout()
        let side: CGFloat = 26
        let y = (Self.height - side) / 2 + 2
        menuButton.frame = NSRect(x: bounds.width - 8 - side, y: y, width: side, height: side)
        collapseButton.frame = menuButton.frame.offsetBy(dx: -side, dy: 0)
        addButton.frame = collapseButton.frame.offsetBy(dx: -side, dy: 0)

        var x: CGFloat = 8
        for chip in fixedChips {
            chip.frame = NSRect(x: x, y: y - 1, width: 28, height: 28)
            x += 32
        }
        divider.isHidden = fixedChips.isEmpty || scrollingChips.isEmpty
        if !divider.isHidden {
            divider.frame = NSRect(x: x + 1, y: y + 5, width: 1, height: 16)
            x += 8
        } else if !fixedChips.isEmpty {
            x += 2
        }
        scroll.frame = NSRect(x: fixedChips.isEmpty ? 6 : x, y: y - 1, width: max(0, addButton.frame.minX - 2 - (fixedChips.isEmpty ? 6 : x)), height: 28)
        layoutChips()
        if let renaming, let chip = chips.first(where: { $0.shelf === renaming }) {
            let rect = convert(chip.bounds, from: chip)
            renameField.frame = NSRect(x: max(6, rect.minX), y: rect.midY - 11,
                                       width: max(rect.width, 120), height: 22)
        }
    }

    private func layoutChips() {
        let chips = scrollingChips
        // No tab may be wider than the space for tabs (minus the faded edges), or it could
        // never be scrolled fully into view. Long names get shorter instead.
        let limit = max(60, scroll.contentSize.width - 20)
        chips.forEach { $0.maxWidth = limit }
        let overflows = chips.reduce(0) { $0 + $1.preferredWidth + 4 } - 4 > scroll.contentSize.width
        // When the tabs don't fit, leave room at both ends so the fade never covers a whole tab.
        let inset: CGFloat = overflows ? 10 : 0
        var x = inset
        for chip in chips {
            chip.frame = NSRect(x: x, y: 0, width: chip.preferredWidth, height: 28)
            x += chip.preferredWidth + 4
        }
        let contentWidth = max(x - 4 + inset, 0)
        strip.frame = NSRect(x: 0, y: 0, width: max(contentWidth, scroll.contentSize.width), height: 28)
        if revealActive {
            revealActive = false
            scrollActiveIntoView()
        }
        // Faded edges only when the tabs don't fit.
        if overflows {
            fadeMask.frame = scroll.bounds
            let edge = NSNumber(value: Double(12 / max(scroll.bounds.width, 1)))
            fadeMask.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
            scroll.layer?.mask = fadeMask
        } else {
            scroll.layer?.mask = nil
        }
    }

    /// Set when the active tab changes or the bar resizes, so the next layout scrolls it into view.
    private var revealActive = true

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        revealActive = true
    }

    /// Scrolls the tab row just enough for the active tab to be fully visible.
    private func scrollActiveIntoView() {
        guard let active = scrollingChips.first(where: { $0.isActive }) else { return }
        let clip = scroll.contentView
        let width = clip.bounds.width
        var x = clip.bounds.origin.x
        if active.frame.minX - 10 < x {
            x = active.frame.minX - 10
        } else if active.frame.maxX + 10 > x + width {
            x = active.frame.maxX + 10 - width
        }
        x = min(max(0, x), max(0, strip.frame.width - width))
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Matches the chips to the window's tabs, reusing existing chips.
    func reload() {
        guard let host else { return }
        let next = host.tabs.map { shelf -> TabChip in
            if let chip = chips.first(where: { $0.shelf === shelf }) { return chip }
            let chip = TabChip(shelf: shelf)
            chip.bar = self
            if shelf.isSystem { addSubview(chip) } else { strip.addSubview(chip) }
            return chip
        }
        // Screenshots first, then Clipboard, then your tabs in their order.
        .sorted { rank($0.shelf) < rank($1.shelf) }
        chips.filter { chip in !next.contains { $0 === chip } }.forEach { $0.removeFromSuperview() }
        chips = next
        // A letter only where two of your tabs share a colour; otherwise the colour says enough.
        let colorCounts = Dictionary(grouping: chips.filter { !$0.shelf.isSystem }, by: { $0.shelf.color }).mapValues(\.count)
        chips.forEach {
            $0.isActive = $0.shelf === host.active
            $0.showsLetter = (colorCounts[$0.shelf.color] ?? 0) > 1
            $0.refresh()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        revealActive = true
        needsLayout = true
    }

    private func rank(_ shelf: ShelfController) -> Int {
        if shelf.isScreenshots { return 0 }
        if shelf.isClipboard { return 1 }
        return 2 + (host?.tabs.firstIndex { $0 === shelf } ?? 0)
    }

    func activate(_ shelf: ShelfController) { host?.activate(shelf) }

    func menu(for shelf: ShelfController) -> NSMenu { shelf.menu(for: [], wholeShelf: true) }

    @objc private func addTab() {
        guard let host else { return }
        host.newTab()
        host.show()
    }

    @objc private func collapse() { host?.setCollapsed(true) }

    @objc private func showMenu() {
        guard let shelf = host?.active else { return }
        let below = NSPoint(x: 0, y: menuButton.isFlipped ? menuButton.bounds.maxY + 6 : -6)
        shelf.menu(for: shelf.items, wholeShelf: true).popUp(positioning: nil, at: below, in: menuButton)
    }

    // MARK: Renaming

    func beginRename(_ shelf: ShelfController) {
        renaming = shelf
        renameField.stringValue = shelf.name ?? ""
        renameField.placeholderString = shelf.defaultTitle
        renameField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeKey()
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard !renameField.isHidden else { return }
        renameField.isHidden = true
        if commit { renaming?.rename(to: renameField.stringValue) }
        renaming = nil
        window?.makeFirstResponder(nil)
    }

    /// ↩ or clicking away saves the name.
    func controlTextDidEndEditing(_ notification: Notification) { endRename(commit: true) }

    /// Esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename(commit: false)
        return true
    }
}

/// Empty space that moves the window when dragged.
final class WindowDragView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// One tab: colour dot, name, 📌 and count. Click to open it, drag to move the window,
/// double-click to rename, right-click for its menu. While dragging items, it is a drop
/// target, and holding over it for a moment opens it.
final class TabChip: NSView {
    let shelf: ShelfController
    weak var bar: TabBar?

    var isActive = false {
        didSet { if oldValue != isActive { refresh() } }
    }

    /// Another of your tabs has the same colour: the circle shows a letter instead of a dot.
    var showsLetter = false

    private let dot = DotView()
    /// Screenshots and Clipboard show an icon instead of the dot and pin.
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let count = NSTextField(labelWithString: "")
    /// The letter in an inactive tab's circle.
    private let initial = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbol: "xmark", tip: "Close Tab")
    private var hovering = false {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }
    private var isTargeted = false {
        didSet {
            guard oldValue != isTargeted else { return }
            needsDisplay = true
            Motion.setTransform(layer ?? CALayer(), isTargeted ? Motion.scale(1.08, around: layer ?? CALayer()) : CATransform3DIdentity,
                                animated: true)
        }
    }
    private var mouseDownEvent: NSEvent?
    private var springTimer: Timer?

    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The widest this tab may be; set by the tab bar from the space it has.
    var maxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if oldValue != maxWidth { needsLayout = true } }
    }

    /// Everything in the tab except its name.
    private var chromeWidth: CGFloat {
        10 + (symbol.isHidden ? 8 : 14) + 6 + (pin.isHidden ? 0 : 12) + countWidth + 10
    }

    /// The active tab shows more of its name than the others, within the tab's maximum width.
    private var maxLabelWidth: CGFloat { max(24, min(isActive ? 120 : 72, maxWidth - chromeWidth)) }

    init(shelf: ShelfController) {
        self.shelf = shelf
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Self.font
        label.lineBreakMode = .byTruncatingMiddle
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        count.font = .systemFont(ofSize: 10, weight: .bold)
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        initial.font = .systemFont(ofSize: 12, weight: .bold)
        initial.textColor = .white
        initial.alignment = .center
        [dot, symbol, label, pin, count, initial, closeButton].forEach(addSubview)
        registerForDraggedTypes(Importer.types)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicking a tab gives the window the keyboard, so ⌘W, Space and the arrows work next.
    override var needsPanelToBecomeKey: Bool { true }

    private var symbolName: String? {
        if shelf.isClipboard { return "list.clipboard" }
        if shelf.isScreenshots { return "photo.on.rectangle" }
        return nil
    }

    /// Screenshots and Clipboard: just their icon, in a circle.
    private var iconOnly: Bool { symbolName != nil }

    /// Your own tabs, when not active: a small glass circle with a colour dot (or a letter,
    /// when colours clash), so many fit and none is half hidden. Only the active tab shows its name.
    private var isCircle: Bool { !iconOnly && !isActive }

    /// The first letter or digit of the name, for the circle.
    private var initialText: String {
        shelf.displayTitle.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    func refresh() {
        dot.color = shelf.color.color
        if let symbolName {
            symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            symbol.contentTintColor = isActive ? shelf.color.color : .secondaryLabelColor
        }
        symbol.isHidden = symbolName == nil
        dot.isHidden = iconOnly || (isCircle && showsLetter)
        label.isHidden = iconOnly || isCircle
        count.isHidden = iconOnly || isCircle
        initial.isHidden = !(isCircle && showsLetter)
        initial.stringValue = initialText
        initial.textColor = shelf.color.color
        label.stringValue = shelf.displayTitle
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        // Screenshots and Clipboard are always pinned; their icon says enough.
        pin.isHidden = !shelf.isPinned || symbolName != nil || isCircle
        pin.contentTintColor = label.textColor
        count.stringValue = isActive && shelf.name != nil && shelf.items.count > 1 ? "\(shelf.items.count)" : ""
        count.textColor = .tertiaryLabelColor
        if shelf.isClipboard {
            toolTip = "Clipboard · " + (shelf.items.count == 1 ? "1 clip" : "\(shelf.items.count) clips")
        } else if shelf.isScreenshots {
            toolTip = "Screenshots · \(shelf.items.count)"
        } else {
            let count = shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items"
            toolTip = shelf.displayTitle + (shelf.name != nil ? " · \(count)" : "") + (shelf.isPinned ? " · Pinned" : "")
        }
        needsDisplay = true
        needsLayout = true
    }

    private var labelWidth: CGFloat {
        min(ceil((label.stringValue as NSString).size(withAttributes: [.font: Self.font]).width) + 4, maxLabelWidth)
    }

    private var countWidth: CGFloat {
        count.stringValue.isEmpty ? 0 : ceil((count.stringValue as NSString).size(withAttributes: [.font: count.font as Any]).width) + 4
    }

    var preferredWidth: CGFloat {
        if iconOnly || isCircle { return 28 }
        return chromeWidth + labelWidth
    }

    override func layout() {
        super.layout()
        if isCircle {
            dot.frame = NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)
            initial.frame = NSRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
            closeButton.isHidden = true
            return
        }
        var x: CGFloat = 10
        dot.frame = NSRect(x: x, y: bounds.midY - 4, width: 8, height: 8)
        symbol.frame = iconOnly ? NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
                                : NSRect(x: x - 1, y: bounds.midY - 7, width: 15, height: 14)
        x += symbol.isHidden ? 14 : 20
        // On hover the ✕ takes the end of the tab and the name gets shorter, so the tab
        // never changes width (and the ✕ never ends up out of view).
        // Only the active tab can be closed from here, so a click can't close a tab by accident.
        let showsClose = hovering && !shelf.isSystem && isActive
        let room = bounds.width - x - 10 - (pin.isHidden ? 0 : 12) - (showsClose ? 0 : countWidth) - (showsClose ? 16 : 0)
        let width = max(0, min(labelWidth, room))
        label.frame = NSRect(x: x, y: bounds.midY - 8, width: width, height: 16)
        x += width
        count.isHidden = iconOnly || showsClose
        pin.frame = NSRect(x: x, y: bounds.midY - 5, width: 10, height: 10)
        if !pin.isHidden { x += 12 }
        count.frame = NSRect(x: x, y: bounds.midY - 7, width: countWidth, height: 14)
        closeButton.frame = NSRect(x: bounds.width - 21, y: bounds.midY - 5, width: 10, height: 10)
        // Screenshots and Clipboard can't be closed.
        closeButton.isHidden = !showsClose
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = shelf.color.color
        if isCircle {
            // A small sheet of glass, like the chips and the search field; tinted with the
            // tab's colour while something is held over it.
            let fill = isTargeted ? color.withAlphaComponent(0.35)
                : NSColor.white.withAlphaComponent(dark ? (hovering ? 0.14 : 0.08) : (hovering ? 0.55 : 0.4))
            fill.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(dark ? 0.12 : 0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        if isTargeted {
            color.withAlphaComponent(0.4).setFill()
            path.fill()
        } else if isActive {
            color.withAlphaComponent(dark ? 0.32 : 0.24).setFill()
            path.fill()
            color.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSColor.white.withAlphaComponent(dark ? 0.08 : 0.4).setFill()
            path.fill()
        }
    }

    // MARK: Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Clicks on the label and dot belong to the chip; only the ✕ keeps its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && !shelf.isSystem {
            mouseDownEvent = nil
            bar?.host?.beginRename(shelf)
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { bar?.activate(shelf) }
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: shelf) }

    @objc private func closeTab() { shelf.close() }

    // MARK: Dropping on a tab

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        if let source = info.draggingSource as? DragSourceView, source.shelf === shelf { return [] }
        guard shelf.acceptsDrops(from: info.draggingPasteboard) else { return [] }
        isTargeted = true
        if !isActive {
            springTimer?.invalidate()
            springTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.bar?.activate(self.shelf)
            }
            RunLoop.main.add(springTimer!, forMode: .common)
        }
        return .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { isTargeted ? .copy : [] }

    override func draggingExited(_ info: NSDraggingInfo?) { endTargeting() }
    override func draggingEnded(_ info: NSDraggingInfo) { endTargeting() }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        endTargeting()
        let accepted = shelf.receive(info.draggingPasteboard)
        if accepted { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        return accepted
    }

    private func endTargeting() {
        springTimer?.invalidate()
        springTimer = nil
        isTargeted = false
    }
}

/// A tab bar button: a small icon centred in a round 26 pt target, lit softly on hover.
class ToolbarButton: IconButton {
    convenience init(symbol: String, tip: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        // Keep the symbol at its own size instead of stretching it to the button.
        imageScaling = .scaleNone
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = tip
        setButtonType(.momentaryChange)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 13
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    func setHighlighted(_ on: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(dark ? 0.12 : 0.45).cgColor : nil
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
}

/// ＋: a click makes an empty tab; dropping on it makes a tab with what was dropped.
final class AddTabButton: ToolbarButton {
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Importer.types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard Importer.canImport(info.draggingPasteboard) else { return [] }
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        contentTintColor = .controlAccentColor
        return .copy
    }

    override func draggingExited(_ info: NSDraggingInfo?) { resetHighlight() }
    override func draggingEnded(_ info: NSDraggingInfo) { resetHighlight() }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        resetHighlight()
        return onDrop?(info.draggingPasteboard) ?? false
    }

    private func resetHighlight() { setHighlighted(false) }
}

/// "Closed 'To upload' · Undo": a dark capsule with a clickable Undo, shown for a few seconds.
final class UndoToast: NSView {
    var onUndo: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Undo", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
            .foregroundColor: NSColor.systemYellow,
        ])
        button.target = self
        button.action = #selector(undo)
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var preferredWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width) + 76
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        button.frame = NSRect(x: bounds.width - 54, y: (bounds.height - 18) / 2, width: 44, height: 18)
        label.frame = NSRect(x: 14, y: (bounds.height - 15) / 2, width: max(0, button.frame.minX - 18), height: 15)
    }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
        alphaValue = 0
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        })
    }

    @objc private func undo() { onUndo?() }
}
