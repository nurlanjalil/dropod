import AppKit
import QuartzCore

/// The expanded shelf: large tiles three to a row, and a bar with actions for the selection.
final class GridView: NSView {
    static let columns = 3
    static let tileHeight: CGFloat = 104
    static let maxVisibleRows = 3
    static let barHeight: CGFloat = 34

    weak var shelf: ShelfController?
    private(set) var tiles: [GridTileView] = []

    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let pileButton = IconButton(symbol: "square.stack", tip: "Show as Pile")
    private let countLabel = NSTextField(labelWithString: "")
    private let airDropButton = CapsuleButton(title: "AirDrop", symbol: "airplayaudio")
    private let shareButton = CapsuleButton(title: "Share", symbol: "square.and.arrow.up")
    private let zipButton = CapsuleButton(title: "ZIP", symbol: "doc.zipper")

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content

        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        airDropButton.target = self
        airDropButton.action = #selector(airDrop)
        shareButton.target = self
        shareButton.action = #selector(share)
        zipButton.target = self
        zipButton.action = #selector(compress)
        pileButton.target = self
        pileButton.action = #selector(showPile)

        [scroll, pileButton, countLabel, airDropButton, shareButton, zipButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.barHeight)
        layoutTiles()

        let barY = bounds.height - Self.barHeight + 6
        var x = bounds.width - 4
        for button in [zipButton, shareButton, airDropButton] {
            let width = button.preferredWidth
            x -= width
            button.frame = NSRect(x: x, y: barY, width: width, height: 22)
            x -= 6
        }
        pileButton.frame = NSRect(x: 6, y: barY + 4, width: 14, height: 14)
        countLabel.frame = NSRect(x: 28, y: barY + 3, width: max(0, x - 28), height: 16)
    }

    private func layoutTiles() {
        let width = scroll.contentSize.width
        let tileWidth = floor(width / CGFloat(Self.columns))
        let rows = Int(ceil(Double(tiles.count) / Double(Self.columns)))
        content.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * Self.tileHeight)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % Self.columns) * tileWidth,
                                y: CGFloat(index / Self.columns) * Self.tileHeight,
                                width: tileWidth, height: Self.tileHeight)
        }
    }

    /// Keeps existing tiles, fades new ones in, drops removed ones.
    func reload(_ items: [ShelfItem], animated: Bool) {
        var added: [GridTileView] = []
        let next = items.map { item -> GridTileView in
            if let tile = tiles.first(where: { $0.item === item }) { return tile }
            let tile = GridTileView(item: item, shelf: shelf)
            added.append(tile)
            return tile
        }
        tiles.filter { tile in !next.contains { $0 === tile } }.forEach { $0.removeFromSuperview() }
        tiles = next
        added.forEach { tile in
            tile.alphaValue = animated ? 0 : 1
            content.addSubview(tile)
        }
        layoutTiles()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                added.forEach { $0.animator().alphaValue = 1 }
            }
        }
        updateCount()
    }

    func selectionChanged() {
        guard let shelf else { return }
        tiles.forEach { $0.isSelected = shelf.isSelected($0.item) }
        updateCount()
    }

    private func updateCount() {
        guard let shelf else { return }
        let selected = shelf.selectedItems.count
        countLabel.stringValue = selected > 0 ? "\(selected) selected" : "\(shelf.items.count) items"
    }

    func tile(for item: ShelfItem) -> GridTileView? { tiles.first { $0.item === item } }

    func scrollTo(_ item: ShelfItem) {
        guard let tile = tile(for: item) else { return }
        tile.scrollToVisible(tile.bounds)
    }

    func thumbnailsChanged() { tiles.forEach { $0.refresh() } }

    func setInFlight(_ ids: Set<ObjectIdentifier>) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            tiles.forEach { $0.animator().alphaValue = ids.contains(ObjectIdentifier($0.item)) ? 0.4 : 1 }
        }
    }

    func refreshColors() { tiles.forEach { $0.needsDisplay = true } }

    // MARK: Bar actions: the selection, or everything when nothing is selected.

    private var targets: [ShelfItem] {
        guard let shelf else { return [] }
        return shelf.selectedItems.isEmpty ? shelf.items : shelf.selectedItems
    }

    @objc private func showPile() { shelf?.isExpanded = false }
    @objc private func airDrop() { shelf?.airDrop(targets) }
    @objc private func share() { shelf?.share(targets, from: shareButton) }
    @objc private func compress() { shelf?.compress(targets) }
}

/// One tile in the grid: a large thumbnail with its file-type tag and name.
final class GridTileView: ItemCellView {
    private let tagView = TagView()
    private let label = NSTextField(labelWithString: "")

    override init(item: ShelfItem, shelf: ShelfController?) {
        super.init(item: item, shelf: shelf)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        label.stringValue = item.name
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        tagView.text = item.tag ?? ""
        tagView.isHidden = item.tag == nil
        [icon, tagView, label].forEach(addSubview)
        toolTip = item.url?.path ?? item.text.map { String($0.prefix(500)) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh() {
        icon.image = item.thumbnail
        icon.layer?.cornerRadius = item.hasPreview ? 8 : 0
        icon.layer?.masksToBounds = item.hasPreview
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 64
        icon.frame = NSRect(x: (bounds.width - side) / 2, y: 8, width: side, height: side)
        let tagWidth = TagView.width(for: tagView.text)
        tagView.frame = NSRect(x: icon.frame.maxX - tagWidth + 4, y: icon.frame.maxY - 11, width: tagWidth, height: 13)
        label.frame = NSRect(x: 4, y: icon.frame.maxY + 6, width: bounds.width - 8, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCellBackground(in: bounds.insetBy(dx: 3, dy: 2), radius: 10)
    }
}

/// In grid mode, a dashed highlight over the tiles while something is held over the shelf.
final class DropOverlay: NSView {
    var tint: NSColor = .systemBlue { didSet { updateColors() } }

    var isTargeted = false {
        didSet {
            guard oldValue != isTargeted else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = isTargeted ? 1 : 0
            }
        }
    }

    private let outline = CAShapeLayer()
    private let label = NSTextField(labelWithString: "Release to add")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        outline.lineWidth = 2
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never catches clicks or drags; the shelf underneath handles them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
        CATransaction.commit()
        label.frame = NSRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18)
    }

    private func updateColors() {
        outline.strokeColor = tint.cgColor
        outline.fillColor = tint.withAlphaComponent(0.14).cgColor
        label.textColor = tint
    }
}

/// A small capsule button with an icon and a title, for the grid's action bar.
final class CapsuleButton: NSButton {
    convenience init(title: String, symbol: String) {
        self.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .medium)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 8
        updateBackground()
    }

    var preferredWidth: CGFloat { ceil(intrinsicContentSize.width) + 16 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.12 : 0.45).cgColor
    }
}

/// A coloured dot as a menu image.
func colorDot(_ color: NSColor, size: CGFloat = 10) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        return true
    }
}
