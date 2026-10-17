import AppKit

/// Peek: a glass panel beside the Dropod window showing a clip or text card in full.
/// Scrollable and selectable, with search matches highlighted, JSON and code in a
/// monospaced font, and an Open Link button for links. It is a child of the Dropod window,
/// so it moves with it.
final class PeekController: NSObject {
    let panel: PeekPanel
    private let view = PeekView()
    private let backdrop: NSView
    private weak var parent: NSWindow?
    private weak var shelf: ShelfController?
    private(set) var item: ShelfItem?
    private var query = ""

    static let width: CGFloat = 420

    var isShowing: Bool { item != nil }

    override init() {
        let size = NSSize(width: Self.width, height: 440)
        view.frame = NSRect(origin: .zero, size: size)
        panel = PeekPanel(contentRect: NSRect(origin: .zero, size: size))
        backdrop = Backdrop.make(around: view, radius: ShelfView.cornerRadius)
        super.init()
        panel.contentView = backdrop
        panel.onClose = { [weak self] in self?.close() }
        view.controller = self
    }

    /// Shows an item, sliding out beside `window` the first time.
    func show(_ item: ShelfItem, from shelf: ShelfController, query: String, beside window: NSWindow) {
        let opening = !isShowing
        self.item = item
        self.shelf = shelf
        self.query = query
        panel.host = shelf.host
        Backdrop.tint(backdrop, with: shelf.color.color)
        view.display(item, inClipboard: shelf.isClipboard, query: query)
        guard opening else { return }
        parent = window
        position(beside: window)
        window.addChildWindow(panel, ordered: .above)
        Motion.present(panel)
    }

    /// The same item again: header (pin, time) and highlights, keeping the scroll position.
    func refresh(query: String? = nil) {
        guard let item, let shelf else { return }
        if let query { self.query = query }
        view.display(item, inClipboard: shelf.isClipboard, query: self.query, keepScroll: true)
    }

    func close() {
        guard isShowing else { return }
        item = nil
        parent?.removeChildWindow(panel)
        Motion.dismiss(panel)
    }

    /// Next to the window, on whichever side has room, top edges lined up.
    func position(beside window: NSWindow) {
        let height = min(max(window.frame.height, 320), 560)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let right = window.frame.maxX + 8
        let x = right + Self.width <= visible.maxX - 8 ? right : window.frame.minX - 8 - Self.width
        var frame = NSRect(x: x, y: window.frame.maxY - height, width: Self.width, height: height)
        frame.origin.y = max(frame.minY, visible.minY + 8)
        panel.setFrame(frame, display: true)
    }

    // MARK: Header buttons

    func copyAll() {
        guard let item, let text = item.text else { return }
        if let shelf, shelf.isClipboard {
            shelf.copyClip(item, fromKeyboard: false)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardWatcher.shared.skipCurrent()
            shelf?.view.flash("Copied")
        }
        view.confirmCopied()
    }

    func togglePin() {
        guard let item else { return }
        shelf?.togglePin(item)
        refresh()
    }
}

/// The Peek window: floats with Dropod, never takes over. Esc closes it.
final class PeekPanel: ShelfPanel {
    var onClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onClose?() ?? () }  // Esc
        super.keyDown(with: event)
    }
}

/// Peek's content: header, counts, link button or note, and the text.
final class PeekView: NSView {
    weak var controller: PeekController?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let pinButton = ToolbarButton(symbol: "pin", tip: "Pin Clip")
    private let copyButton = ToolbarButton(symbol: "doc.on.doc", tip: "Copy All")
    private let closeButton = ToolbarButton(symbol: "xmark", tip: "Close (Esc)")
    private let linkButton = CapsuleButton(title: "Open Link", symbol: "safari")
    private let noteLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private var link: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: 11, weight: .medium)
        noteLabel.textColor = .systemOrange
        separator.boxType = .separator

        pinButton.target = self
        pinButton.action = #selector(pin)
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        closeButton.target = self
        closeButton.action = #selector(close)
        linkButton.target = self
        linkButton.action = #selector(openLink)

        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        // Lays out only what is on screen, so long texts open and scroll smoothly.
        textView.layoutManager?.allowsNonContiguousLayout = true

        [icon, titleLabel, statsLabel, pinButton, copyButton, closeButton, linkButton, noteLabel, separator, scroll]
            .forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        icon.frame = NSRect(x: 14, y: 14, width: 20, height: 20)
        closeButton.frame = NSRect(x: width - 36, y: 11, width: 26, height: 26)
        copyButton.frame = closeButton.frame.offsetBy(dx: -28, dy: 0)
        pinButton.frame = copyButton.frame.offsetBy(dx: -28, dy: 0)
        let titleRight = (pinButton.isHidden ? copyButton.frame.minX : pinButton.frame.minX) - 6
        titleLabel.frame = NSRect(x: 42, y: 9, width: max(0, titleRight - 42), height: 17)
        statsLabel.frame = NSRect(x: 42, y: 26, width: max(0, titleRight - 42), height: 14)

        var y: CGFloat = 50
        if !linkButton.isHidden {
            linkButton.frame = NSRect(x: 14, y: y, width: width - 28, height: 30)
            y += 38
        }
        if !noteLabel.isHidden {
            noteLabel.frame = NSRect(x: 14, y: y, width: width - 28, height: 15)
            y += 21
        }
        separator.frame = NSRect(x: 14, y: y, width: width - 28, height: 1)
        scroll.frame = NSRect(x: 4, y: y + 2, width: width - 8, height: max(0, bounds.height - y - 8))
    }

    func display(_ item: ShelfItem, inClipboard: Bool, query: String, keepScroll: Bool = false) {
        let text = item.text ?? ""

        // Header: where it came from and when.
        if let bundle = item.sourceApp, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            icon.image = NSWorkspace.shared.icon(forFile: app.path)
            icon.contentTintColor = nil
            titleLabel.stringValue = "\(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) · \(ClipRowView.ago(item.addedAt)) ago"
        } else {
            icon.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            titleLabel.stringValue = (inClipboard ? "Clip" : "Text card") + " · " + ClipRowView.ago(item.addedAt) + (item.addedAt.timeIntervalSinceNow > -60 ? "" : " ago")
        }
        let formatted = TextFormat.prepare(text)
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        statsLabel.stringValue = [formatted.kind, "\(words.formatted()) words", "\(text.count.formatted()) characters"]
            .compactMap { $0 }.joined(separator: " · ")

        pinButton.isHidden = !inClipboard
        pinButton.image = NSImage(systemSymbolName: item.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        pinButton.toolTip = item.isPinned ? "Unpin Clip" : "Pin Clip (keep forever)"

        link = TextFormat.link(in: text)
        linkButton.isHidden = link == nil
        linkButton.title = link.map { "Open \($0.host ?? "Link")" } ?? "Open Link"
        noteLabel.isHidden = !item.wasCut
        noteLabel.stringValue = "Cut at 100,000 characters when copied."

        // The text itself, unless it is the same item again (keeps the scroll position).
        let font = formatted.monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)
        if !(keepScroll && textView.string == formatted.text) {
            textView.textStorage?.setAttributedString(NSAttributedString(string: formatted.text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ]))
            textView.scrollToBeginningOfDocument(nil)
        }
        highlight(query)
        needsLayout = true
    }

    /// Search matches, highlighted in yellow; the first one is scrolled into view.
    private func highlight(_ query: String) {
        guard let layout = textView.layoutManager else { return }
        let string = textView.string as NSString
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: string.length))
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        var searchRange = NSRange(location: 0, length: string.length)
        var first: NSRange?
        for _ in 0..<1_000 {
            let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard found.location != NSNotFound else { break }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45),
                                         forCharacterRange: found)
            first = first ?? found
            searchRange = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
        if let first { textView.scrollRangeToVisible(first) }
    }

    func confirmCopied() {
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        }
    }

    @objc private func pin() { controller?.togglePin() }
    @objc private func copyAll() { controller?.copyAll() }
    @objc private func close() { controller?.close() }
    @objc private func openLink() { if let link { NSWorkspace.shared.open(link) } }
}

/// How Peek shows a text: JSON neatly indented, code in a monospaced font, plain text as is.
enum TextFormat {
    static func prepare(_ text: String) -> (text: String, monospaced: Bool, kind: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let indented = String(data: pretty, encoding: .utf8) {
            return (indented, true, "JSON")
        }
        if looksLikeCode(text) { return (text, true, "Code") }
        return (text, false, nil)
    }

    /// Several lines, many of them with code punctuation or keywords, or indented.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).prefix(200)
        guard lines.count >= 3 else { return false }
        let markers = [";", "{", "}", "=>", "->", "();", "</", "def ", "func ", "import ", "const ", "let ",
                       "var ", "return ", "#include", "class ", "SELECT ", "fn "]
        let hits = lines.filter { line in markers.contains { line.contains($0) } }.count
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        return Double(hits) + Double(indented) / 2 >= Double(lines.count) * 0.5
    }

    /// The text is a single web address.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), trimmed.count < 4_000,
              let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}
