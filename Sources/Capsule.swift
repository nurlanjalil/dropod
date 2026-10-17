import AppKit
import QuartzCore

// MARK: - Collapsed capsule

/// The collapsed window: a small copy of the tab bar (Screenshots, Clipboard, then a glass
/// dot per tab) and ⌃. Instead of a total, a tab shows a badge with what's new since you last
/// opened Dropod. When something arrives, that tab's chip unfolds a one-line label ("Screenshot
/// copied") for a few seconds, then folds back into its badge.
/// Click it (or a chip) to expand; hold a drag over it to expand; drag it to move the window.
final class CapsuleView: NSView {
    weak var host: DropodWindow?

    static let height: CGFloat = 44
    private static let padding: CGFloat = 9
    private static let gap: CGFloat = 6
    private static let chevronWidth: CGFloat = 12
    /// Beyond this many of your tabs, only the first ones (and the active one) are shown.
    private static let maxOwnChips = 6
    /// How long a label stays out.
    private static let messageDuration: TimeInterval = 3

    private var chips: [CapsuleChip] = []
    private let chevron = NSImageView()
    private var dividerX: CGFloat?
    private var mouseDownEvent: NSEvent?
    private var springTimer: Timer?
    private var foldTimer: Timer?

    /// The chip showing a label right now.
    private var unfolded: CapsuleChip?
    /// The chip that takes the capsule's extra width. It stays set while the label folds
    /// away, so the chip shrinks along with the window instead of snapping shut.
    private var growing: CapsuleChip?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Expand")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        addSubview(chevron)
        registerForDraggedTypes(Importer.types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    // MARK: Chips

    /// Matches the chips to the window's tabs, reusing existing chips.
    func reload() {
        guard let host else { return }
        let system = host.tabs.filter(\.isSystem).sorted { $0.isScreenshots && !$1.isScreenshots }
        var own = host.tabs.filter { !$0.isSystem }
        if own.count > Self.maxOwnChips {
            let active = host.active
            own = Array(own.prefix(Self.maxOwnChips))
            if let active, !active.isSystem, !own.contains(where: { $0 === active }) { own[own.count - 1] = active }
        }
        let next = (system + own).map { shelf -> CapsuleChip in
            if let chip = chips.first(where: { $0.shelf === shelf }) { return chip }
            let chip = CapsuleChip(shelf: shelf)
            addSubview(chip)
            return chip
        }
        chips.filter { chip in !next.contains { $0 === chip } }.forEach { $0.removeFromSuperview() }
        chips = next
        if let unfolded, !chips.contains(where: { $0 === unfolded }) { self.unfolded = nil }
        if let growing, !chips.contains(where: { $0 === growing }) { self.growing = nil }
        // A letter only where two of your tabs share a colour, as in the tab bar.
        let colorCounts = Dictionary(grouping: own, by: \.color).mapValues(\.count)
        for chip in chips {
            chip.showsLetter = !chip.shelf.isSystem && (colorCounts[chip.shelf.color] ?? 0) > 1
            chip.refresh()
        }
        needsLayout = true
        needsDisplay = true
    }

    private var hasDivider: Bool {
        chips.contains { $0.shelf.isSystem } && chips.contains { !$0.shelf.isSystem }
    }

    /// The capsule's width with every chip folded.
    var restWidth: CGFloat {
        let count = CGFloat(chips.count)
        return Self.padding * 2 + count * CapsuleChip.size + count * Self.gap
            + (hasDivider ? 1 + Self.gap : 0) + Self.chevronWidth
    }

    /// The width the capsule wants now: its rest width plus any label that's out.
    var preferredWidth: CGFloat { restWidth + (unfolded?.labelWidth ?? 0) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The window animates its size; the unfolding chip follows it frame by frame.
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let extra = max(0, bounds.width - restWidth)
        var x = Self.padding
        dividerX = nil
        for (index, chip) in chips.enumerated() {
            let width = CapsuleChip.size + (chip === growing ? extra : 0)
            chip.frame = NSRect(x: x, y: (bounds.height - CapsuleChip.size) / 2, width: width, height: CapsuleChip.size)
            x += width + Self.gap
            let next = index + 1 < chips.count ? chips[index + 1] : nil
            if chip.shelf.isSystem, let next, !next.shelf.isSystem {
                dividerX = x
                x += 1 + Self.gap
            }
        }
        chevron.frame = NSRect(x: bounds.width - Self.padding - Self.chevronWidth, y: bounds.midY - 6,
                               width: Self.chevronWidth, height: 12)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let dividerX else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: dividerX, y: bounds.midY - 9, width: 1, height: 18).fill()
    }

    // MARK: Labels

    /// Unfolds a tab's chip to show a short message. `holds` keeps it out until `fold()`.
    func unfold(_ shelf: ShelfController, message: String, holds: Bool = false) {
        guard let chip = chips.first(where: { $0.shelf === shelf }) else { return }
        foldTimer?.invalidate()
        foldTimer = nil
        if let growing, growing !== chip { growing.setOpen(false, animated: false) }
        unfolded = chip
        growing = chip
        chip.message = message
        chip.setOpen(true, animated: true)
        host?.capsuleResized()
        guard !holds else { return }
        foldTimer = Timer.scheduledTimer(withTimeInterval: Self.messageDuration, repeats: false) { [weak self] _ in self?.fold() }
        RunLoop.main.add(foldTimer!, forMode: .common)
    }

    /// Folds the label back into its chip; the badge appears once it has closed.
    func fold() {
        foldTimer?.invalidate()
        foldTimer = nil
        guard let chip = unfolded else { return }
        unfolded = nil
        chip.setOpen(false, animated: true)
        host?.capsuleResized()
    }

    /// Back to rest at once, e.g. when the window expands.
    func foldNow() {
        foldTimer?.invalidate()
        foldTimer = nil
        unfolded?.setOpen(false, animated: false)
        unfolded = nil
        growing = nil
        needsLayout = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil
        window?.performDrag(with: event)
    }

    /// A click opens Dropod; a click on a chip opens it on that tab.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let chip = chips.first(where: { $0.frame.insetBy(dx: -3, dy: -6).contains(point) }) {
            host.activate(chip.shelf)
        }
        host.setCollapsed(false)
    }

    // MARK: Drops

    /// The tab a drop on the capsule goes to: the active one, if it takes this kind of thing.
    private func dropTarget(for info: NSDraggingInfo) -> ShelfController? {
        guard let active = host?.active, active.acceptsDrops(from: info.draggingPasteboard) else { return nil }
        return active
    }

    // Holding a drag over the capsule says where it will land, then opens it so you can pick a tab.
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard Importer.canImport(info.draggingPasteboard) else { return [] }
        let target = dropTarget(for: info)
        if let target { unfold(target, message: "Drop here", holds: true) }
        springTimer?.invalidate()
        springTimer = Timer.scheduledTimer(withTimeInterval: target == nil ? 0.3 : 1.0, repeats: false) { [weak self] _ in
            self?.host?.setCollapsed(false)
        }
        RunLoop.main.add(springTimer!, forMode: .common)
        return target == nil ? [] : .copy
    }

    override func draggingExited(_ info: NSDraggingInfo?) {
        stopSpring()
        fold()
    }

    override func draggingEnded(_ info: NSDraggingInfo) { stopSpring() }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        stopSpring()
        // The tab announces what arrived, which replaces "Drop here".
        let accepted = dropTarget(for: info)?.receive(info.draggingPasteboard) ?? false
        if !accepted { fold() }
        return accepted
    }

    private func stopSpring() {
        springTimer?.invalidate()
        springTimer = nil
    }
}

// MARK: - Capsule chip

/// One tab in the capsule: a glass circle with the tab's icon or colour dot, a badge with
/// what's new, and a label that unfolds to the right when something arrives.
final class CapsuleChip: NSView {
    static let size: CGFloat = 26
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let maxLabelWidth: CGFloat = 170

    let shelf: ShelfController
    var showsLetter = false
    var message = "" {
        didSet { label.stringValue = message }
    }
    private(set) var isOpen = false

    private let symbol = NSImageView()
    private let dot = DotView()
    private let initial = NSTextField(labelWithString: "")
    /// Clips the label while the chip is narrower than it.
    private let labelClip = NSView()
    private let label = NSTextField(labelWithString: "")
    private let badge = CapsuleBadge()

    init(shelf: ShelfController) {
        self.shelf = shelf
        super.init(frame: .zero)
        wantsLayer = true
        labelClip.wantsLayer = true
        labelClip.layer?.masksToBounds = true
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.alphaValue = 0
        initial.font = .systemFont(ofSize: 11, weight: .bold)
        initial.alignment = .center
        labelClip.addSubview(label)
        [symbol, dot, initial, labelClip, badge].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The label's own width: the text, plus the few points a text field pads it with.
    private var textWidth: CGFloat {
        min(ceil((message as NSString).size(withAttributes: [.font: Self.font]).width), Self.maxLabelWidth) + 6
    }

    /// How much wider the chip gets with its label out (the label plus a little room after it).
    var labelWidth: CGFloat { textWidth + 8 }

    func refresh() {
        let color = shelf.color.color
        let name = shelf.isScreenshots ? "photo.on.rectangle" : shelf.isClipboard ? "list.clipboard" : nil
        if let name {
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: shelf.displayTitle)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        }
        symbol.isHidden = name == nil
        // Screenshots and Clipboard always show their colour, so they read at a glance.
        symbol.contentTintColor = color
        dot.color = color
        dot.isHidden = name != nil || showsLetter
        initial.isHidden = name != nil || !showsLetter
        initial.stringValue = shelf.displayTitle.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
        initial.textColor = color
        badge.color = color
        badge.count = shelf.unseen
        badge.isHidden = shelf.unseen == 0
        toolTip = shelf.displayTitle
        needsLayout = true
        needsDisplay = true
    }

    /// Opens or closes the label. Opening, the text fades in as the chip widens; closing, it
    /// fades out first, and the badge comes back once the chip has shut.
    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen || !animated else { return }
        isOpen = open
        refresh()
        let animate = animated && !Motion.reduced
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? (open ? 0.3 : 0.15) : 0
            label.animator().alphaValue = open ? 1 : 0
            badge.animator().alphaValue = open ? 0 : badge.alphaValue
        }
        if !open {
            let delay = animate ? 0.4 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isOpen else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = animate ? 0.2 : 0
                    self.badge.animator().alphaValue = 1
                }
            }
        }
        if open, animate, let layer {
            // The icon gives a small hop as its label comes out.
            layer.add(Motion.spring("transform", from: Motion.scale(1.1, around: layer), to: CATransform3DIdentity,
                                    damping: 10, stiffness: 320), forKey: "hop")
        }
    }

    override func layout() {
        super.layout()
        let icon = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        symbol.frame = icon.insetBy(dx: 5, dy: 5)
        dot.frame = NSRect(x: icon.midX - 4.5, y: icon.midY - 4.5, width: 9, height: 9)
        initial.frame = NSRect(x: 0, y: icon.midY - 8, width: icon.width, height: 16)
        labelClip.frame = NSRect(x: Self.size - 2, y: 0, width: max(0, bounds.width - Self.size + 2 - 6), height: bounds.height)
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: textWidth, height: 16)
        let badgeWidth = badge.preferredWidth
        badge.frame = NSRect(x: bounds.width - badgeWidth + 5, y: -5, width: badgeWidth, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = shelf.color.color
        // A small sheet of glass, like the tab bar's circles; tinted with the tab's colour while
        // its label is out.
        (isOpen ? color.withAlphaComponent(dark ? 0.3 : 0.22) : NSColor.white.withAlphaComponent(dark ? 0.08 : 0.4)).setFill()
        path.fill()
        // No ring for the active tab: a ringed dot reads as a Record button.
        NSColor.white.withAlphaComponent(dark ? 0.12 : 0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The count of new items on a capsule chip.
final class CapsuleBadge: NSView {
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var count = 0 { didSet { needsDisplay = true } }

    private var text: String { count > 99 ? "99+" : "\(count)" }

    var preferredWidth: CGFloat {
        max(15, ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 8)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
