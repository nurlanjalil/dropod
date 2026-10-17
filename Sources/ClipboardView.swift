import AppKit

/// The Clipboard tab's content: a search field and the copied texts, newest first.
/// Click a clip (or ↩) to copy it back; drag it into any app to drop the text.
final class ClipboardView: NSView, NSTextFieldDelegate {
    static let searchHeight: CGFloat = 36
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 7

    weak var shelf: ShelfController?
    /// A plain text field with our own magnifier and clear button: an unbezeled NSSearchField
    /// moves its text over the magnifier while editing.
    let search = NSTextField()
    private let magnifier = NSImageView()
    private let clearButton = IconButton(symbol: "xmark.circle.fill", tip: "Clear Search")

    var query: String { search.stringValue.trimmingCharacters(in: .whitespaces) }

    /// The clips that match the search, in order.
    private(set) var visibleItems: [ShelfItem] = []
    private var allItems: [ShelfItem] = []
    private let scroll = NSScrollView()
    private let list = FlippedView()
    /// Rows exist only for the clips in view (plus a few either side); they are made and
    /// dropped as the list scrolls, so hundreds of clips cost no more than a handful.
    private var rows: [ObjectIdentifier: ClipRowView] = [:]
    /// Clips being dragged out, shown dimmed (kept so rows made later are dimmed too).
    private var inFlight = Set<ObjectIdentifier>()
    /// The soft glass pill behind the search field (the field itself has no bezel).
    private let searchPill = PillBackground()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    /// Rows of height the empty state needs.
    static let emptyRows = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search clips"
        search.font = .systemFont(ofSize: 12)
        search.isBezeled = false
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        search.lineBreakMode = .byClipping
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        magnifier.contentTintColor = .secondaryLabelColor
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center

        [searchPill, magnifier, search, clearButton, scroll, emptyIcon, emptyLabel, hintLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        searchPill.frame = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 28)
        let pill = searchPill.frame
        magnifier.frame = NSRect(x: pill.minX + 9, y: pill.midY - 7, width: 14, height: 14)
        clearButton.frame = NSRect(x: pill.maxX - 22, y: pill.midY - 7, width: 14, height: 14)
        // A single line of 12 pt text is 16 pt tall; centre it in the pill.
        search.frame = NSRect(x: pill.minX + 28, y: pill.midY - 8, width: pill.width - 28 - 26, height: 16)
        scroll.frame = NSRect(x: 0, y: Self.searchHeight, width: bounds.width, height: max(0, bounds.height - Self.searchHeight))

        // Icon, message and hint, centred in the space below the search field.
        let area = NSRect(x: 0, y: Self.searchHeight, width: bounds.width, height: max(0, bounds.height - Self.searchHeight))
        let block: CGFloat = hintLabel.isHidden ? 48 : 64
        let top = area.midY - block / 2
        emptyIcon.frame = NSRect(x: area.midX - 12, y: top, width: 24, height: 22)
        emptyLabel.frame = NSRect(x: 8, y: top + 28, width: area.width - 16, height: 17)
        hintLabel.frame = NSRect(x: 8, y: top + 47, width: area.width - 16, height: 14)
        layoutRows()
    }

    @objc private func scrolled() { layoutRows() }

    /// Sizes the list for every match, and keeps rows only for the ones in view.
    private func layoutRows() {
        let width = scroll.contentSize.width
        let height = CGFloat(visibleItems.count) * Self.rowHeight
        if list.frame.size != NSSize(width: width, height: height) {
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        let shown = scroll.contentView.bounds
        let first = max(0, Int(floor(shown.minY / Self.rowHeight)) - 2)
        let last = min(visibleItems.count, Int(ceil(shown.maxY / Self.rowHeight)) + 2)
        var wanted = Set<ObjectIdentifier>()
        if first < last {
            for index in first..<last {
                let item = visibleItems[index]
                let id = ObjectIdentifier(item)
                wanted.insert(id)
                let row = rows[id] ?? makeRow(for: item)
                let frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
                if row.frame != frame { row.frame = frame }
            }
        }
        for (id, row) in rows where !wanted.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
    }

    private func makeRow(for item: ShelfItem) -> ClipRowView {
        let row = ClipRowView(item: item, shelf: shelf)
        row.isSelected = shelf?.isSelected(item) ?? false
        row.alphaValue = inFlight.contains(ObjectIdentifier(item)) ? 0.4 : 1
        list.addSubview(row)
        rows[ObjectIdentifier(item)] = row
        return row
    }

    func reload(_ items: [ShelfItem]) {
        allItems = items
        applyFilter()
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        visibleItems = query.isEmpty ? allItems : allItems.filter { ($0.text ?? $0.name).localizedCaseInsensitiveContains(query) }

        // Rows in view pick up changes (time, pin); the rest are made fresh when scrolled to.
        rows.values.forEach { $0.refresh() }
        layoutRows()

        let noClipsYet = allItems.isEmpty
        emptyIcon.image = NSImage(systemSymbolName: noClipsYet ? "list.clipboard" : "magnifyingglass",
                                  accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        emptyLabel.stringValue = noClipsYet ? "Copy some text and it shows up here" : "No matching clips"
        hintLabel.stringValue = Settings.clipboardShortcut.map { "Press \($0.display) to search clips anytime" } ?? ""
        let empty = visibleItems.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        hintLabel.isHidden = !empty || !noClipsYet || hintLabel.stringValue.isEmpty
        selectionChanged()
        needsLayout = true
    }

    func selectionChanged() {
        guard let shelf else { return }
        rows.values.forEach { $0.isSelected = shelf.isSelected($0.item) }
    }

    func scrollTo(_ item: ShelfItem) {
        guard let index = visibleItems.firstIndex(where: { $0 === item }) else { return }
        list.scrollToVisible(NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: 1, height: Self.rowHeight))
        layoutRows()
    }

    /// The row showing a clip, if it is in view.
    func row(for item: ShelfItem) -> ClipRowView? { rows[ObjectIdentifier(item)] }

    func setInFlight(_ ids: Set<ObjectIdentifier>) {
        inFlight = ids
        rows.values.forEach { $0.alphaValue = ids.contains(ObjectIdentifier($0.item)) ? 0.4 : 1 }
    }

    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) { searchChanged() }

    private func searchChanged() {
        clearButton.isHidden = search.stringValue.isEmpty
        applyFilter()
        shelf?.clipboardFilterChanged()
    }

    @objc private func clearSearch() {
        search.stringValue = ""
        searchChanged()
        focusSearch()
    }

    /// While typing in the search field: ↑ ↓ move through the clips, ↩ copies, Esc clears or closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            shelf?.moveClipSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            shelf?.moveClipSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            shelf?.copySelectedClip()
        case #selector(NSResponder.cancelOperation(_:)):
            if search.stringValue.isEmpty {
                ShelfManager.shared.endClipboard()
            } else {
                search.stringValue = ""
                searchChanged()
            }
        default:
            return false
        }
        return true
    }
}

/// A soft, rounded sheet of glass, like the tab chips: used behind the search field.
final class PillBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.07 : 0.4).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.1 : 0.5).cgColor
    }
}

/// One clip: the app it came from, two lines of its text, how long ago, and a pin.
final class ClipRowView: ItemCellView {
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let pinButton = IconButton(symbol: "pin", tip: "Pin Clip")
    private var measuredWidth: CGFloat = 0
    private var textHeight: CGFloat = 34

    /// App icons by bundle identifier: looking one up is slow, and every clip from the same
    /// app shares it.
    private static var iconCache: [String: NSImage] = [:]
    // Symbol images are slow to make; every row shares these.
    private static let textSymbol = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
    private static let pinOutline = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    private static let pinFilled = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    private static func appIcon(_ bundle: String) -> NSImage? {
        if let cached = iconCache[bundle] { return cached }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        iconCache[bundle] = image
        return image
    }

    override init(item: ShelfItem, shelf: ShelfController?) {
        super.init(item: item, shelf: shelf)
        icon.imageScaling = .scaleProportionallyUpOrDown
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.truncatesLastVisibleLine = true
        timeLabel.font = .systemFont(ofSize: 10.5)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        [icon, textLabel, timeLabel, pinButton].forEach(addSubview)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh() {
        // The app it was copied from, or a text symbol.
        if let bundle = item.sourceApp, let image = Self.appIcon(bundle) {
            icon.image = image
        } else {
            icon.image = Self.textSymbol
            icon.contentTintColor = .secondaryLabelColor
        }
        let text = (item.text ?? item.name).trimmingCharacters(in: .whitespacesAndNewlines)
        if text != textLabel.stringValue {
            textLabel.stringValue = text
            measuredWidth = 0
            needsLayout = true
        }
        timeLabel.stringValue = Self.ago(item.addedAt)
        toolTip = String((item.text ?? "").prefix(500))
        updatePin()
    }

    private func updatePin() {
        let pinned = item.isPinned
        pinButton.image = pinned ? Self.pinFilled : Self.pinOutline
        pinButton.contentTintColor = pinned ? (shelf?.color.color ?? .controlAccentColor) : .secondaryLabelColor
        pinButton.toolTip = pinned ? "Unpin Clip" : "Pin Clip (keep forever)"
        pinButton.isHidden = !(pinned || hovering)
    }

    override func hoverDidChange() { updatePin() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 13, width: 20, height: 20)
        // Two lines fill the row; a single line sits centred beside the icon. The text is
        // measured once per width, not on every layout pass (rows lay out on every frame
        // while the window resizes).
        let width = bounds.width - 36 - 44
        if width != measuredWidth {
            measuredWidth = width
            textHeight = min(34, ceil(textLabel.sizeThatFits(NSSize(width: width, height: 34)).height))
        }
        textLabel.frame = NSRect(x: 36, y: (bounds.height - textHeight) / 2, width: width, height: textHeight)
        timeLabel.frame = NSRect(x: bounds.width - 44, y: 7, width: 36, height: 14)
        pinButton.frame = NSRect(x: bounds.width - 22, y: 26, width: 12, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCellBackground(in: bounds.insetBy(dx: 4, dy: 1), radius: 9)
    }

    /// A plain click copies the clip, ready for ⌘V.
    override func selectOnClick(_ event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
        shelf?.select(item)
        shelf?.copyClip(item, fromKeyboard: false)
    }

    @objc private func togglePin() { shelf?.togglePin(item) }

    /// "now", "5m", "3h", "2d".
    static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
