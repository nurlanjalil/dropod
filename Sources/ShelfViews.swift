import AppKit
import Quartz

/// A borderless floating panel that never takes focus from the app you are working in.
/// Once clicked it becomes key, so its shelf can take keyboard commands and Quick Look.
class ShelfPanel: NSPanel {
    /// Bumped every time the panel is shown, so a fade-out that finishes late
    /// doesn't hide a panel that was shown again in the meantime.
    var visibilityToken = 0
    weak var host: DropodWindow?
    private var shelf: ShelfController? { host?.active }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }

    /// ⌘C ⌘V ⌘X ⌘A in text (clip search, renaming, Peek). Dropod is a menu bar app without
    /// an Edit menu, which is what normally provides them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSText,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let action = Self.editActions[event.charactersIgnoringModifiers ?? ""],
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let editActions: [String: Selector] = [
        "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
        "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
    ]

    override func keyDown(with event: NSEvent) {
        // ⌘Z brings back the tab that was just closed.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "z" {
            host?.undoClose()
            return
        }
        if shelf?.handleKey(event) != true { super.keyDown(with: event) }
    }

    // Quick Look looks up the responder chain for whoever supplies its items.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { shelf != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = shelf
        panel.delegate = shelf
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// The shelf's backdrop. On macOS 26 it is real Liquid Glass (NSGlassEffectView,
/// looked up at runtime because the installed SDK predates it); earlier systems
/// get a frosted blur with rounded corners.
enum Backdrop {
    static func make(around content: NSView, radius: CGFloat) -> NSView {
        let frame = content.frame
        content.autoresizingMask = [.width, .height]
        let backdrop: NSView
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            backdrop = glassClass.init(frame: frame)
            backdrop.setValue(radius, forKey: "cornerRadius")
            content.frame = backdrop.bounds
            backdrop.setValue(content, forKey: "contentView")
        } else {
            let blur = NSVisualEffectView(frame: frame)
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = roundedMask(radius: radius)
            content.frame = blur.bounds
            blur.addSubview(content)
            backdrop = blur
        }
        backdrop.wantsLayer = true
        // Clip to the same rounded shape. Without it, macOS works out the window's shadow from
        // a full rectangle once the window becomes key, which shows as square dark corners.
        backdrop.layer?.cornerRadius = radius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        return backdrop
    }

    /// A gentle colour wash through the glass.
    static func tint(_ backdrop: NSView, with color: NSColor) {
        guard backdrop.responds(to: NSSelectorFromString("setTintColor:")) else { return }
        backdrop.setValue(color.withAlphaComponent(0.1), forKey: "tintColor")
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A tab's content, below the tab bar: the thumbnail pile (plus a list once there are two
/// or more items) or, when expanded, the grid.
final class ShelfView: NSView {
    static let cornerRadius: CGFloat = 22
    static let topInset: CGFloat = 2
    static let pileHeight: CGFloat = 124
    static let rowHeight: CGFloat = 40
    static let maxVisibleRows = 5

    weak var shelf: ShelfController? {
        didSet {
            pile.shelf = shelf
            grid.shelf = shelf
            clipboard.shelf = shelf
        }
    }

    /// The tab's colour: badge, selection and drop highlight.
    var tint: NSColor = .systemBlue {
        didSet {
            pile.tint = tint
            dropOverlay.tint = tint
            rows.forEach { $0.needsDisplay = true }
            grid.refreshColors()
        }
    }

    private let pile = PileView()
    private let gridButton = IconButton(symbol: "square.grid.3x3", tip: "Show as Grid")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [ItemRowView] = []
    private var rowsAnimating = false
    private let grid = GridView()
    private let dropOverlay = DropOverlay()
    private let toast = ToastView()
    /// The Clipboard tab's search and clips, shown instead of the pile.
    private let clipboard = ClipboardView()
    private var isClipboard: Bool { shelf?.isClipboard ?? false }
    private var showsGrid = false
    private var isHovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        gridButton.target = self
        gridButton.action = #selector(showGrid)
        gridButton.alphaValue = 0

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        grid.isHidden = true
        clipboard.isHidden = true

        [pile, gridButton, scroll, grid, clipboard, dropOverlay, toast].forEach(addSubview)
        registerForDraggedTypes(Importer.types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        pile.frame = NSRect(x: 10, y: Self.topInset, width: width - 20, height: Self.pileHeight)
        gridButton.frame = NSRect(x: pile.frame.minX + 9, y: pile.frame.minY + 9, width: 14, height: 14)
        let listTop = pile.frame.maxY + 6
        scroll.frame = NSRect(x: 6, y: listTop, width: width - 12, height: max(0, bounds.height - listTop - 8))
        if !rowsAnimating { layoutRows(animated: false) }

        grid.frame = NSRect(x: 8, y: Self.topInset, width: width - 16, height: max(0, bounds.height - Self.topInset - 6))
        dropOverlay.frame = grid.frame.insetBy(dx: 2, dy: 0).divided(atDistance: GridView.barHeight, from: .maxYEdge).remainder

        clipboard.frame = NSRect(x: 6, y: Self.topInset, width: width - 12, height: max(0, bounds.height - Self.topInset - 6))

        let toastWidth = min(toast.preferredWidth, width - 24)
        toast.frame = NSRect(x: (width - toastWidth) / 2, y: bounds.height - 34, width: toastWidth, height: 24)
    }

    private func rowFrame(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: scroll.contentSize.width, height: Self.rowHeight)
    }

    private func layoutRows(animated: Bool) {
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(rows.count) * Self.rowHeight)
        for (index, row) in rows.enumerated() {
            if animated { row.animator().frame = rowFrame(index) } else { row.frame = rowFrame(index) }
        }
    }

    // MARK: Status

    private var toastReset: DispatchWorkItem?

    /// Shows a short status at the bottom, such as "Compressing…": for a moment, or until
    /// the next one when sticky.
    func flash(_ text: String, sticky: Bool = false) {
        toastReset?.cancel()
        toast.show(text)
        needsLayout = true
        guard !sticky else { return }
        let reset = DispatchWorkItem { [weak self] in self?.toast.hide() }
        toastReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: reset)
    }

    // MARK: Content

    func reload(animated: Bool) {
        guard let shelf else { return }
        let items = shelf.items
        if shelf.isClipboard {
            [pile, scroll, grid, gridButton].forEach { $0.isHidden = true }
            clipboard.isHidden = false
            clipboard.reload(items)
            return
        }
        pile.items = items
        grid.reload(items, animated: animated && showsGrid)
        reloadRows(items.count >= 2 ? items : [], animated: animated && !showsGrid)
        updateMode(animated: animated)
        updateGridButton()
    }

    /// Crossfades between the pile and the grid.
    private func updateMode(animated: Bool) {
        let grid = shelf?.showsGrid ?? false
        guard grid != showsGrid else { return }
        showsGrid = grid
        let incoming: [NSView] = grid ? [self.grid] : [pile, scroll]
        let outgoing: [NSView] = grid ? [pile, scroll] : [self.grid]
        incoming.forEach {
            $0.alphaValue = animated ? 0 : 1
            $0.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.2 : 0
            incoming.forEach { $0.animator().alphaValue = 1 }
            outgoing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard self?.showsGrid == grid else { return }
            outgoing.forEach { $0.isHidden = true }
        })
        needsLayout = true
    }

    /// Keeps existing rows, adds new ones, fades out removed ones.
    private func reloadRows(_ wanted: [ShelfItem], animated: Bool) {
        var added: [ItemRowView] = []
        let next = wanted.map { item -> ItemRowView in
            if let row = rows.first(where: { $0.item === item }) { return row }
            let row = ItemRowView(item: item, shelf: shelf)
            added.append(row)
            return row
        }
        let removed = rows.filter { row in !next.contains { $0 === row } }
        rows = next

        added.forEach { row in
            let index = rows.firstIndex { $0 === row } ?? 0
            row.frame = rowFrame(index).offsetBy(dx: 0, dy: animated ? -6 : 0)
            row.alphaValue = animated ? 0 : 1
            list.addSubview(row)
        }

        guard animated else {
            removed.forEach { $0.removeFromSuperview() }
            layoutRows(animated: false)
            return
        }
        rowsAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduced ? 0.12 : 0.22
            context.timingFunction = Motion.easeOut
            removed.forEach { $0.animator().alphaValue = 0 }
            added.forEach { $0.animator().alphaValue = 1 }
            layoutRows(animated: true)
        }, completionHandler: { [weak self] in
            removed.forEach { $0.removeFromSuperview() }
            self?.rowsAnimating = false
            self?.needsLayout = true
        })
        // A new item below the visible rows: bring it into view.
        if let last = added.last, rows.count > Self.maxVisibleRows {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { last.scrollToVisible(last.bounds) }
        }
    }

    /// The clips that match the search, for the arrow keys.
    var clipboardVisibleItems: [ShelfItem] { clipboard.visibleItems }

    /// What is typed in the clip search, for Peek's highlights.
    var clipboardQuery: String { clipboard.query }

    func focusSearch() { clipboard.focusSearch() }

    func selectionChanged() {
        guard let shelf else { return }
        clipboard.selectionChanged()
        rows.forEach { $0.isSelected = shelf.isSelected($0.item) }
        pile.isSelected = !shelf.items.isEmpty && shelf.selectedItems.count == shelf.items.count
        grid.selectionChanged()
    }

    func scrollTo(_ item: ShelfItem) {
        if isClipboard { return clipboard.scrollTo(item) }
        if showsGrid { return grid.scrollTo(item) }
        guard let row = rows.first(where: { $0.item === item }) else { return }
        row.scrollToVisible(row.bounds)
    }

    /// Where an item sits on screen, for Quick Look's zoom: its tile or row icon, or the pile.
    func screenFrame(for item: ShelfItem) -> NSRect {
        let view: NSView
        if isClipboard { view = clipboard.row(for: item)?.icon ?? clipboard }
        else if showsGrid { view = grid.tile(for: item)?.icon ?? grid }
        else { view = rows.first { $0.item === item }?.icon ?? pile }
        guard let window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func thumbnailsChanged() {
        pile.refreshThumbnails()
        rows.forEach { $0.refresh() }
        grid.thumbnailsChanged()
    }

    /// Dims the items currently being dragged out, so you can see what is "in your hand".
    func setInFlight(_ items: [ShelfItem]) {
        let ids = Set(items.map(ObjectIdentifier.init))
        pile.inFlight = ids
        grid.setInFlight(ids)
        clipboard.setInFlight(ids)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            rows.forEach { $0.animator().alphaValue = ids.contains(ObjectIdentifier($0.item)) ? 0.4 : 1 }
        }
    }

    @objc private func showGrid() { shelf?.isExpanded = true }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateGridButton()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateGridButton()
    }

    /// The pile's "show as grid" corner button, on hover when there is something to show.
    private func updateGridButton() {
        let visible = isHovering && !showsGrid && !isClipboard && !(shelf?.items.isEmpty ?? true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            gridButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Dropping in

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func draggingExited(_ info: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ info: NSDraggingInfo) { setTargeted(false) }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        setTargeted(false)
        let accepted = shelf?.receive(info.draggingPasteboard) ?? false
        if accepted {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        return accepted
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        // Ignore items dragged out of this same tab.
        if let source = info.draggingSource as? DragSourceView, source.shelf === shelf { return [] }
        guard shelf?.acceptsDrops(from: info.draggingPasteboard) == true else { return [] }
        setTargeted(true)
        return .copy
    }

    private func setTargeted(_ targeted: Bool) {
        if isClipboard { return }
        if showsGrid { dropOverlay.isTargeted = targeted } else { pile.isTargeted = targeted }
    }
}

/// A small dark capsule at the bottom of a tab for status messages.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width) + 26
    }

    /// Never catches clicks or drags.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: (bounds.height - 15) / 2, width: bounds.width - 16, height: 15)
    }

    func show(_ text: String) {
        label.stringValue = text
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        }
    }
}

// MARK: - Dragging out

/// A view whose items can be dragged out of the shelf, double-clicked to open,
/// or right-clicked for actions.
class DragSourceView: NSView, NSDraggingSource {
    weak var shelf: ShelfController?
    var draggedItems: [ShelfItem] { [] }
    var isWholeShelf: Bool { false }

    private var mouseDownEvent: NSEvent?
    private var inFlight: [ShelfItem] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicking an item gives the shelf keyboard focus (appearing never does).
    override var needsPanelToBecomeKey: Bool { true }

    /// Clicks on labels and images belong to this view; only buttons keep their own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if !draggedItems.isEmpty { NSCursor.openHand.set() }
        hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        hoverChanged(false)
    }

    /// Subclasses react to the pointer entering or leaving.
    func hoverChanged(_ hovering: Bool) {}

    /// Subclasses update the shelf's selection when pressed...
    func selectOnMouseDown(_ event: NSEvent) {}
    /// ...and when released without dragging (a plain click).
    func selectOnClick(_ event: NSEvent) {}

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        selectOnMouseDown(event)
        if !draggedItems.isEmpty { NSCursor.closedHand.set() }
        if event.clickCount == 2 {
            mouseDownEvent = nil
            draggedItems.compactMap(\.url).forEach { NSWorkspace.shared.open($0) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { selectOnClick(event) }
        mouseDownEvent = nil
        if !draggedItems.isEmpty { NSCursor.openHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil

        let items = draggedItems
        guard !items.isEmpty else { return }
        let origin = convert(start, from: nil)
        let side: CGFloat = 56
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
            let offset = CGFloat(min(index, 4)) * 3
            let box = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 + offset, width: side, height: side)
            draggingItem.setDraggingFrame(aspectFit(item.thumbnail.size, in: box), contents: item.thumbnail)
            return draggingItem
        }
        inFlight = items
        shelf?.setInFlight(items)
        let session = beginDraggingSession(with: draggingItems, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = draggedItems
        guard !items.isEmpty else { return nil }
        return shelf?.menu(for: items, wholeShelf: isWholeShelf)
    }

    /// Copy only: dropping into Finder copies the file, it never moves or deletes your original.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dragged = inFlight
        inFlight = []
        shelf?.setInFlight([])
        guard operation != [] else { return }
        shelf?.draggedOut(dragged)
    }
}

/// The fanned-out pile of thumbnails. Dragging it takes everything on the shelf.
/// Each card is its own layer so it can spring into place.
final class PileView: DragSourceView {
    var items: [ShelfItem] = [] {
        didSet {
            updateCards(animated: true)
            updateBadge(animated: oldValue.count != items.count)
            updateEmptyState(animated: true)
        }
    }

    var isTargeted = false {
        didSet {
            guard oldValue != isTargeted else { return }
            updateCards(animated: true)
            updateEmptyState(animated: true)
        }
    }

    /// Items being dragged out right now.
    var inFlight: Set<ObjectIdentifier> = [] {
        didSet { updateCards(animated: true) }
    }

    var tint: NSColor = .systemBlue {
        didSet { updateColors() }
    }

    /// Everything on the shelf is selected: a solid outline in the shelf's colour.
    var isSelected = false {
        didSet { if oldValue != isSelected { updateEmptyState(animated: true) } }
    }

    private var isHovering = false {
        didSet { if oldValue != isHovering { updateCards(animated: true) } }
    }

    override var draggedItems: [ShelfItem] { items }
    override var isWholeShelf: Bool { true }
    override func selectOnMouseDown(_ event: NSEvent) { shelf?.selectAll() }
    // Unflipped, so the layers' images and text draw the right way up.
    override var isFlipped: Bool { false }

    private static let cardSide: CGFloat = 84
    private let outline = CAShapeLayer()
    private var cards: [ObjectIdentifier: CALayer] = [:]
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// A second, quieter line under the empty message (the Screenshots tab's hint).
    private let emptyHint = NSTextField(labelWithString: "")
    /// The Screenshots tab fills itself, so its empty state explains that instead of
    /// inviting a drop.
    private var isScreenshots: Bool { shelf?.isScreenshots ?? false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)

        badge.cornerRadius = 10
        badge.zPosition = 10
        badge.opacity = 0
        badge.shadowOpacity = 0.25
        badge.shadowRadius = 3
        badge.shadowOffset = .zero
        badgeText.fontSize = 11
        badgeText.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badge.addSublayer(badgeText)
        layer?.addSublayer(badge)

        emptyIcon.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        emptyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.alignment = .center
        emptyHint.font = .systemFont(ofSize: 10.5)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        addSubview(emptyIcon)
        addSubview(emptyLabel)
        addSubview(emptyHint)
        updateEmptyState(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hoverChanged(_ hovering: Bool) { isHovering = hovering }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
        CATransaction.commit()
        emptyIcon.frame = iconFrame
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 30, width: bounds.width, height: 18)
        emptyHint.frame = NSRect(x: 8, y: bounds.midY - 47, width: bounds.width - 16, height: 15)
        updateEmptyState(animated: false)
        updateCards(animated: false)
        updateBadge(animated: false)
        updateColors()
    }

    /// The arrow nudges down while something is held over the shelf.
    private var iconFrame: NSRect {
        NSRect(x: bounds.midX - 16, y: bounds.midY - 4 - (isTargeted ? 5 : 0), width: 32, height: 30)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private var showsSelection: Bool { isSelected && !isTargeted && !items.isEmpty }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let strong = isTargeted || showsSelection
            outline.strokeColor = (strong ? tint : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).cgColor
            outline.fillColor = isTargeted ? tint.withAlphaComponent(0.14).cgColor
                : showsSelection ? tint.withAlphaComponent(0.08).cgColor : nil
            badge.backgroundColor = tint.cgColor
        }
        emptyIcon.contentTintColor = isTargeted ? tint : .secondaryLabelColor
        emptyLabel.textColor = isTargeted ? tint : .secondaryLabelColor
    }

    private func updateEmptyState(animated: Bool) {
        // No dashed "drop here" outline on the Screenshots tab: nothing can be dropped there.
        let showOutline = (items.isEmpty && !isScreenshots) || isTargeted || showsSelection
        let showEmpty = items.isEmpty
        if isScreenshots {
            emptyIcon.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
            emptyLabel.stringValue = "No screenshots yet"
            emptyHint.stringValue = "Take one with ⇧⌘4 · " + Self.keptFor(Settings.screenshotRetention)
        } else {
            emptyIcon.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
            emptyLabel.stringValue = isTargeted ? "Release to add" : "Drop anything here"
            emptyHint.stringValue = ""
        }
        // Dashed means "drop here"; solid means "selected".
        outline.lineDashPattern = showsSelection ? nil : [6, 4]
        outline.lineWidth = showsSelection ? 2 : 1.5
        updateColors()
        outline.opacity = showOutline ? 1 : 0  // implicit fade

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.18 : 0
            context.timingFunction = Motion.easeOut
            emptyIcon.animator().alphaValue = showEmpty ? 1 : 0
            emptyLabel.animator().alphaValue = showEmpty ? 1 : 0
            emptyHint.animator().alphaValue = showEmpty ? 1 : 0
            emptyIcon.animator().frame = iconFrame
        }
    }

    /// "kept here for 1 day", following Screenshots → Keep in Tab.
    private static func keptFor(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 0: return "kept here until you clear them"
        case 3_600: return "kept here for 1 hour"
        case 86_400: return "kept here for 1 day"
        case 259_200: return "kept here for 3 days"
        case 604_800: return "kept here for 1 week"
        default: return "kept here for a while"
        }
    }

    // MARK: Cards

    func refreshThumbnails() { updateCards(animated: false) }

    private func updateCards(animated: Bool) {
        guard let host = layer else { return }
        let shown = Array(items.suffix(3))
        let ids = shown.map(ObjectIdentifier.init)

        for (id, card) in cards where !ids.contains(id) {
            cards[id] = nil
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setCompletionBlock { card.removeFromSuperlayer() }
            card.opacity = 0
            CATransaction.commit()
        }

        let angles: [CGFloat] = shown.isEmpty ? [] : [[0], [-5, 4], [-8, 6, 0]][shown.count - 1]
        // Fan out a little on hover, tuck in while something is held over the shelf.
        let spread: CGFloat = isTargeted ? 0.6 : (isHovering ? 1.7 : 1)
        let scale: CGFloat = isTargeted ? 0.94 : (isHovering ? 1.04 : 1)
        let side = Self.cardSide

        for (index, item) in shown.enumerated() {
            let id = ids[index]
            let isNew = cards[id] == nil
            let card = cards[id] ?? makeCard(in: host)
            cards[id] = card
            style(card, for: item, side: side, isTop: index == shown.count - 1)
            card.zPosition = CGFloat(index)

            let angle = angles[index] * spread * .pi / 180
            let target = CATransform3DScale(CATransform3DMakeRotation(angle, 0, 0, 1), scale, scale, 1)

            if isNew && animated && !Motion.reduced {
                // Lands on the pile from slightly above and larger.
                let start = CATransform3DScale(CATransform3DMakeRotation(angle * 2, 0, 0, 1), 1.25, 1.25, 1)
                card.transform = target
                card.add(Motion.spring("transform", from: start, to: target, damping: 14, stiffness: 260), forKey: "transform")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.15
                card.add(fade, forKey: "fadeIn")
            } else {
                Motion.setTransform(card, target, animated: animated)
            }
            card.opacity = inFlight.contains(id) ? 0.35 : 1
        }
    }

    /// A card is a shadow layer holding a rounded image layer and an optional file-type tag.
    private func makeCard(in host: CALayer) -> CALayer {
        let card = CALayer()
        card.shadowOpacity = 0.3
        card.shadowRadius = 7
        card.shadowOffset = .zero

        let image = CALayer()
        image.name = "image"
        image.contentsGravity = .resizeAspect
        image.contentsScale = window?.backingScaleFactor ?? 2
        card.addSublayer(image)

        host.insertSublayer(card, below: badge)
        return card
    }

    private func style(_ card: CALayer, for item: ShelfItem, side: CGFloat, isTop: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = aspectFit(item.thumbnail.size, in: NSRect(x: 0, y: 0, width: side, height: side)).size
        card.bounds = CGRect(origin: .zero, size: size)
        card.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let image = card.sublayers?.first { $0.name == "image" }
        image?.frame = card.bounds
        image?.contents = item.thumbnail
        // Real previews get rounded corners and a solid shadow; icons keep their own shape.
        image?.cornerRadius = item.hasPreview ? 10 : 0
        image?.masksToBounds = item.hasPreview
        card.shadowPath = item.hasPreview
            ? CGPath(roundedRect: card.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil) : nil

        card.sublayers?.first { $0.name == "tag" }?.removeFromSuperlayer()
        if isTop, let text = item.tag {
            let tag = TagLayer(text: text, scale: window?.backingScaleFactor ?? 2)
            tag.name = "tag"
            tag.position = CGPoint(x: size.width - tag.bounds.width / 2 + 4, y: tag.bounds.height / 2 - 4)
            card.addSublayer(tag)
        }
        CATransaction.commit()
    }

    private func updateBadge(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let text = "\(items.count)"
        let width = max(20, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).width + 10)
        badge.bounds = CGRect(x: 0, y: 0, width: width, height: 20)
        badge.position = CGPoint(x: bounds.maxX - 8 - width / 2, y: bounds.maxY - 16)
        badgeText.frame = CGRect(x: 0, y: 3, width: width, height: 14)
        badgeText.string = text
        badgeText.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()

        badge.opacity = items.count > 1 ? 1 : 0
        if animated && items.count > 1 && !Motion.reduced {
            badge.add(Motion.spring("transform.scale", from: 1.35, to: 1, damping: 10, stiffness: 300), forKey: "pop")
        }
    }
}

/// One item on the shelf, as a list row or a grid tile. Handles Finder-style
/// selection, hover and the selected/hover background; subclasses lay out the content.
class ItemCellView: DragSourceView {
    let item: ShelfItem
    /// Also where Quick Look zooms in from.
    let icon = NSImageView()

    private(set) var hovering = false {
        didSet {
            hoverDidChange()
            needsDisplay = true
        }
    }

    var isSelected = false {
        didSet { if oldValue != isSelected { needsDisplay = true } }
    }

    init(item: ShelfItem, shelf: ShelfController?) {
        self.item = item
        super.init(frame: .zero)
        self.shelf = shelf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the latest thumbnail.
    func refresh() {}

    /// Subclasses show or hide hover-only controls.
    func hoverDidChange() {}

    /// Dragging a selected item takes the whole selection; any other item goes alone.
    override var draggedItems: [ShelfItem] {
        guard let shelf, shelf.isSelected(item) else { return [item] }
        return shelf.selectedItems
    }

    /// Finder-style: ⌘ toggles, ⇧ extends, and a press on an unselected item selects it.
    override func selectOnMouseDown(_ event: NSEvent) {
        guard let shelf else { return }
        let flags = event.modifierFlags
        if flags.contains(.command) { shelf.toggleSelection(item) }
        else if flags.contains(.shift) { shelf.extendSelection(to: item) }
        else if !shelf.isSelected(item) { shelf.select(item) }
    }

    /// A plain click inside a bigger selection narrows it to this item.
    override func selectOnClick(_ event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
        shelf?.select(item)
    }

    override func hoverChanged(_ hovering: Bool) { self.hovering = hovering }

    /// The shelf's colour when selected, a light wash on hover.
    func drawCellBackground(in rect: NSRect, radius: CGFloat) {
        guard hovering || isSelected else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isSelected {
            let tint = shelf?.color.color ?? .controlAccentColor
            tint.withAlphaComponent(dark ? 0.38 : 0.26).setFill()
        } else {
            NSColor.white.withAlphaComponent(dark ? 0.08 : 0.4).setFill()
        }
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

/// One row in the list: thumbnail with its file-type tag, name, and "kind · size".
final class ItemRowView: ItemCellView {
    private let tagView = TagView()
    private let label = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let removeButton = IconButton(symbol: "xmark", tip: "Remove from Shelf")

    override init(item: ShelfItem, shelf: ShelfController?) {
        super.init(item: item, shelf: shelf)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        label.stringValue = item.name
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        details.stringValue = item.details
        details.font = .systemFont(ofSize: 10.5)
        details.textColor = .secondaryLabelColor
        details.lineBreakMode = .byTruncatingTail
        tagView.text = item.tag ?? ""
        tagView.isHidden = item.tag == nil
        removeButton.target = self
        removeButton.action = #selector(removeItem)
        removeButton.alphaValue = 0
        [icon, tagView, label, details, removeButton].forEach(addSubview)
        toolTip = item.url?.path ?? item.text.map { String($0.prefix(500)) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh() {
        icon.image = item.thumbnail
        icon.layer?.cornerRadius = item.hasPreview ? 5 : 0
        icon.layer?.masksToBounds = item.hasPreview
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 6, width: 28, height: 28)
        let tagWidth = TagView.width(for: tagView.text)
        tagView.frame = NSRect(x: icon.frame.maxX - tagWidth + 4, y: icon.frame.maxY - 9, width: tagWidth, height: 13)
        label.frame = NSRect(x: 46, y: 5, width: bounds.width - 76, height: 16)
        details.frame = NSRect(x: 46, y: 21, width: bounds.width - 76, height: 14)
        removeButton.frame = NSRect(x: bounds.width - 24, y: 14, width: 12, height: 12)
    }

    override func hoverDidChange() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            removeButton.animator().alphaValue = hovering ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCellBackground(in: bounds.insetBy(dx: 2, dy: 1), radius: 9)
    }

    @objc private func removeItem() { shelf?.remove([item]) }
}

// MARK: - Small pieces

/// A tab's colour dot.
final class DotView: NSView {
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A small dark capsule with a file type, such as "PDF".
final class TagView: NSView {
    static let font = NSFont.systemFont(ofSize: 8, weight: .bold)

    var text = "" { didSet { needsDisplay = true } }

    static func width(for text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

/// The same tag as a layer, for the cards in the pile.
final class TagLayer: CALayer {
    init(text: String, scale: CGFloat) {
        super.init()
        let width = TagView.width(for: text)
        bounds = CGRect(x: 0, y: 0, width: width, height: 13)
        cornerRadius = 4
        backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        let label = CATextLayer()
        label.string = text
        label.font = TagView.font
        label.fontSize = 8
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = scale
        label.frame = CGRect(x: 0, y: 1.5, width: width, height: 11)
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A borderless SF Symbol button that works on the first click, even in an inactive panel.
class IconButton: NSButton {
    convenience init(symbol: String, tip: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        isBordered = false
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .secondaryLabelColor
        toolTip = tip
        setButtonType(.momentaryChange)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The largest rect with the image's proportions that fits inside `rect`.
func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let scale = min(rect.width / size.width, rect.height / size.height)
    let width = size.width * scale, height = size.height * scale
    return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
}
