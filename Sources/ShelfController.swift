import AppKit
import Carbon.HIToolbox
import Quartz

/// One tab of the Dropod window: its items, name, colour and pin, selection, keys and actions.
/// Its view (pile, list or grid) is shown by `DropodWindow` while the tab is active.
final class ShelfController: NSObject {
    static let width: CGFloat = 288
    static let gridWidth: CGFloat = 360

    /// The compact content's height (below the tab bar): pile, plus a list from two items.
    static func height(for count: Int) -> CGFloat {
        let top = ShelfView.topInset + ShelfView.pileHeight
        guard count >= 2 else { return top + 10 }
        return top + 14 + CGFloat(min(count, ShelfView.maxVisibleRows)) * ShelfView.rowHeight
    }

    let id: UUID
    let view: ShelfView
    /// The window showing this tab.
    weak var host: DropodWindow?
    private(set) var items: [ShelfItem] = []

    var color: ShelfColor = .blue {
        didSet {
            view.tint = color.color
            host?.tabAppearanceChanged(self)
            ShelfManager.shared.setNeedsSave()
        }
    }

    /// A name the user gave; nil shows "3 items" and the like.
    private(set) var name: String?

    /// Pinned tabs keep their items when dragged out, and stay open when empty.
    var isPinned = false {
        didSet {
            host?.tabAppearanceChanged(self)
            ShelfManager.shared.setNeedsSave()
        }
    }

    /// Shown as a grid of large tiles instead of the pile.
    var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            changed()
        }
    }

    /// An empty tab always shows the pile's drop area, even when expanded.
    var showsGrid: Bool { isExpanded && !items.isEmpty }

    var defaultTitle: String {
        switch items.count {
        case 0: return "New tab"
        case 1: return items[0].name
        default: return "\(items.count) items"
        }
    }

    var displayTitle: String { name ?? defaultTitle }

    func rename(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? nil : trimmed
        host?.tabAppearanceChanged(self)
        ShelfManager.shared.setNeedsSave()
    }

    /// The content's size below the tab bar.
    var contentSize: NSSize {
        if isClipboard {
            let visible = view.clipboardVisibleItems.count
            let rows = visible == 0 ? ClipboardView.emptyRows : min(visible, ClipboardView.maxVisibleRows)
            let height = ShelfView.topInset + ClipboardView.searchHeight + CGFloat(rows) * ClipboardView.rowHeight + 10
            return NSSize(width: Self.width, height: height)
        }
        guard showsGrid else { return NSSize(width: Self.width, height: Self.height(for: items.count)) }
        let rows = Int(ceil(Double(items.count) / Double(GridView.columns)))
        let height = ShelfView.topInset + CGFloat(min(rows, GridView.maxVisibleRows)) * GridView.tileHeight
            + GridView.barHeight + 8
        return NSSize(width: Self.gridWidth, height: height)
    }

    /// Kept alive while its Share submenu is open.
    private var sharePicker: NSSharingServicePicker?

    /// The tab new screenshots are added to.
    var isScreenshots = false

    /// The tab copied text is kept in: a searchable list, newest first.
    var isClipboard = false

    /// Screenshots and Clipboard: always there, can't be closed or renamed, only cleared.
    var isSystem: Bool { isClipboard || isScreenshots }

    /// Whether something being dragged can land here. The Screenshots tab fills itself
    /// (nothing can be dropped on it); the Clipboard tab only takes text.
    func acceptsDrops(from pasteboard: NSPasteboard) -> Bool {
        if isScreenshots { return false }
        if isClipboard { return pasteboard.string(forType: .string) != nil && !Importer.hasFiles(pasteboard) }
        return Importer.canImport(pasteboard)
    }

    /// Opened by a shake mid-drag: removed again if that drag ends without a drop here.
    var autoCloseIfEmpty = false
    private(set) var receivedDrop = false

    init(id: UUID = UUID()) {
        self.id = id
        view = ShelfView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(for: 0)))
        super.init()
        view.shelf = self
        view.tint = color.color
        view.reload(animated: false)
    }

    /// Whether this tab is on screen right now.
    private var isVisible: Bool { host?.isShowing(self) ?? false }
    /// How many things arrived while Dropod was collapsed or hidden; a badge on the capsule.
    var unseen = 0

    func close() { host?.closeTab(self) }

    // MARK: Items

    /// Adds whatever was dropped. Returns false when nothing could be used.
    func receive(_ pasteboard: NSPasteboard) -> Bool {
        guard acceptsDrops(from: pasteboard) else { return false }
        if isClipboard {
            guard let text = pasteboard.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            addClip(text, from: nil)
            host?.announce(self, TextCard.title(for: text))
            receivedDrop = true
            ShelfManager.shared.noteDrop()
            return true
        }
        let accepted = Importer.read(pasteboard) { [weak self] items in
            guard let self else { return }
            self.add(items)
            guard let first = items.first else { return }
            self.host?.announce(self, items.count == 1 ? first.name : "\(items.count) items")
        }
        if accepted {
            receivedDrop = true
            ShelfManager.shared.noteDrop()
        }
        return accepted
    }

    func add(_ newItems: [ShelfItem]) {
        let known = Set(items.map(\.identity))
        let fresh = newItems.filter { !known.contains($0.identity) }
        guard !fresh.isEmpty else { return }
        items += fresh
        for item in fresh {
            guard let url = item.url else { continue }  // text cards draw their own
            Thumbnails.load(url) { [weak self, weak item] image in
                item?.thumbnail = image
                item?.hasPreview = true
                self?.view.thumbnailsChanged()
            }
        }
        changed()
    }

    // MARK: Clips

    /// Copied text: a new clip at the top, or the same text moved back to the top.
    func addClip(_ text: String, from app: NSRunningApplication?, cut: Bool = false) {
        if let existing = items.first(where: { $0.isNote && $0.text == text }) {
            items.removeAll { $0 === existing }
            existing.addedAt = Date()
            if let bundle = app?.bundleIdentifier { existing.sourceApp = bundle }
            items.insert(existing, at: 0)
        } else {
            let clip = ShelfItem(note: text, sourceApp: app?.bundleIdentifier)
            clip.wasCut = cut
            items.insert(clip, at: 0)
        }
        changed()
    }

    /// Puts a clip back on the clipboard, ready for ⌘V. Chosen with ↩ (after ⌃⌘V),
    /// Dropod then steps aside so you can paste straight away.
    func copyClip(_ item: ShelfItem, fromKeyboard: Bool) {
        guard let text = item.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared.skipCurrent()
        if fromKeyboard {
            ShelfManager.shared.endClipboard()
        } else {
            view.flash("Copied")
        }
    }

    /// ↑ ↓ in the Clipboard tab move through the clips that match the search.
    func moveClipSelection(by step: Int) {
        let visible = view.clipboardVisibleItems
        guard !visible.isEmpty else { return }
        let current = cursor.flatMap { item in visible.firstIndex { $0 === item } } ?? (step > 0 ? -1 : visible.count)
        let target = visible[min(max(current + step, 0), visible.count - 1)]
        select(target)
        view.scrollTo(target)
    }

    /// ↩ copies the selected clip, or the first one that matches.
    func copySelectedClip() {
        let visible = view.clipboardVisibleItems
        guard let clip = visible.first(where: { isSelected($0) }) ?? visible.first else { return NSSound.beep() }
        copyClip(clip, fromKeyboard: true)
    }

    func togglePin(_ item: ShelfItem) {
        item.isPinned.toggle()
        changed()
        if host?.peek.item === item { host?.peek.refresh() }
    }

    func clipboardFilterChanged() {
        host?.tabContentChanged(self)
        host?.peek.refresh(query: view.clipboardQuery)
    }

    func remove(_ gone: [ShelfItem]) {
        items.removeAll { item in gone.contains { $0 === item } }
        gone.forEach { selected.remove(ObjectIdentifier($0)) }
        if items.isEmpty && !isPinned { close() } else { changed() }
    }

    // MARK: Selection

    private var selected = Set<ObjectIdentifier>()
    /// Where ⇧-click and ⇧-arrow ranges start.
    private var anchor: ShelfItem?
    /// The item the arrow keys move from.
    private var cursor: ShelfItem?

    var selectedItems: [ShelfItem] { items.filter { selected.contains(ObjectIdentifier($0)) } }

    func isSelected(_ item: ShelfItem) -> Bool { selected.contains(ObjectIdentifier(item)) }

    func select(_ item: ShelfItem) { setSelection([item], anchor: item, cursor: item) }

    func toggleSelection(_ item: ShelfItem) {
        let id = ObjectIdentifier(item)
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchor = item
        cursor = item
        selectionChanged()
    }

    func extendSelection(to item: ShelfItem) {
        guard let anchor, let from = index(of: anchor), let to = index(of: item) else { return select(item) }
        setSelection(Array(items[min(from, to)...max(from, to)]), anchor: anchor, cursor: item)
    }

    func selectAll() { setSelection(items, anchor: items.first, cursor: items.last) }

    private func moveSelection(by step: Int, extend: Bool) {
        guard !items.isEmpty else { return }
        let current = cursor.flatMap(index(of:)) ?? (step > 0 ? -1 : items.count)
        let target = items[min(max(current + step, 0), items.count - 1)]
        if extend { extendSelection(to: target) } else { select(target) }
        view.scrollTo(target)
    }

    private func setSelection(_ list: [ShelfItem], anchor: ShelfItem?, cursor: ShelfItem?) {
        selected = Set(list.map(ObjectIdentifier.init))
        self.anchor = anchor
        self.cursor = cursor
        selectionChanged()
    }

    private func selectionChanged() {
        view.selectionChanged()
        if let preview = quickLookPanelIfOurs { preview.reloadData() }
        // Peek follows the arrow keys; a file in its place goes back to Quick Look.
        if let host, host.peek.isShowing, let item = selectedItems.first {
            if item.url == nil { showPeek(item) } else { host.peek.close() }
        }
    }

    /// Text (clips and text cards) opens in Peek beside the window; files use Quick Look.
    private func showPeek(_ item: ShelfItem) {
        guard let host else { return }
        host.peek.show(item, from: self, query: isClipboard ? view.clipboardQuery : "", beside: host.panel)
    }

    private func index(of item: ShelfItem) -> Int? { items.firstIndex { $0 === item } }

    // MARK: Keyboard

    /// Keys work once the window has been clicked. Returns false for keys it doesn't use.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command = flags == .command
        let shift = flags.contains(.shift)
        let targets = selectedItems.isEmpty ? items : selectedItems

        switch Int(event.keyCode) {
        case kVK_UpArrow where isClipboard:
            moveClipSelection(by: -1)
        case kVK_DownArrow where isClipboard:
            moveClipSelection(by: 1)
        case kVK_Space where flags.isEmpty:
            toggleQuickLook()
        case kVK_Delete, kVK_ForwardDelete:
            if selectedItems.isEmpty { NSSound.beep() } else { remove(selectedItems) }
        case kVK_Escape:
            if let peek = host?.peek, peek.isShowing { peek.close() } else { host?.setCollapsed(true) }
        case kVK_LeftArrow:
            moveSelection(by: -1, extend: shift)
        case kVK_RightArrow:
            moveSelection(by: 1, extend: shift)
        case kVK_UpArrow:
            moveSelection(by: showsGrid ? -GridView.columns : -1, extend: shift)
        case kVK_DownArrow:
            moveSelection(by: showsGrid ? GridView.columns : 1, extend: shift)
        case kVK_Return where flags.isEmpty && isClipboard:
            copySelectedClip()
        case kVK_Return where flags.isEmpty, kVK_ANSI_O where command:
            targets.compactMap(\.url).forEach { NSWorkspace.shared.open($0) }
        case kVK_ANSI_A where command:
            selectAll()
        case kVK_ANSI_C where command:
            copy(targets)
        case kVK_ANSI_W where command:
            // Screenshots and Clipboard can't be closed; ⌘W just tucks the window away.
            if isSystem { host?.setCollapsed(true) } else { close() }
        default:
            return false
        }
        return true
    }

    private func copy(_ items: [ShelfItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map(\.pasteboardWriter))
    }

    /// Dims the items while they are being dragged out.
    func setInFlight(_ dragged: [ShelfItem]) { view.setInFlight(dragged) }

    /// Called after a drag out of this tab landed somewhere (including another tab).
    func draggedOut(_ dragged: [ShelfItem]) {
        if Settings.removeAfterDragOut && !isPinned { remove(dragged) }
    }

    private func changed() {
        view.reload(animated: isVisible)
        view.selectionChanged()
        if let preview = quickLookPanelIfOurs { preview.reloadData() }
        host?.tabContentChanged(self)
        ShelfManager.shared.setNeedsSave()
    }

    // MARK: Menus

    func menu(for selection: [ShelfItem], wholeShelf: Bool) -> NSMenu {
        let menu = NSMenu()
        if !selection.isEmpty { addItemActions(for: selection, to: menu) }

        if wholeShelf {
            // The tab itself. Screenshots and Clipboard keep their name and can't be closed.
            if !isSystem {
                menu.addItem(ActionItem("Rename…", symbol: "pencil") { [weak self] in
                    guard let self else { return }
                    self.host?.beginRename(self)
                })
            }
            let colors = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
            colors.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            colors.submenu = NSMenu()
            for option in ShelfColor.allCases {
                let item = ActionItem(option.title) { [weak self] in self?.color = option }
                item.image = colorDot(option.color)
                item.state = option == color ? .on : .off
                colors.submenu?.addItem(item)
            }
            menu.addItem(colors)
            if !isSystem {
                menu.addItem(ActionItem(isPinned ? "Unpin Tab" : "Pin Tab", symbol: isPinned ? "pin.slash" : "pin") {
                    [weak self] in self?.isPinned.toggle()
                })
            }
            if !items.isEmpty && !isClipboard {
                menu.addItem(ActionItem(isExpanded ? "Show as Pile" : "Show as Grid",
                                        symbol: isExpanded ? "square.stack" : "square.grid.3x3") {
                    [weak self] in self?.isExpanded.toggle()
                })
            }
            menu.addItem(.separator())
            if isClipboard {
                if items.contains(where: { !$0.isPinned }) {
                    menu.addItem(ActionItem("Clear Clips…", symbol: "trash") { ShelfManager.shared.clearClips() })
                }
            } else if isScreenshots {
                if !items.isEmpty {
                    menu.addItem(ActionItem("Clear Screenshots…", symbol: "trash") { ShelfManager.shared.clearScreenshots() })
                }
            } else {
                menu.addItem(ActionItem("Close Tab", symbol: "xmark") { [weak self] in self?.close() })
            }
        } else {
            menu.addItem(ActionItem("Remove from Shelf", symbol: "minus.circle") { [weak self] in
                self?.remove(selection)
            })
        }
        return menu
    }

    private func addItemActions(for selection: [ShelfItem], to menu: NSMenu) {
        let urls = selection.compactMap(\.url)
        let allFiles = urls.count == selection.count
        if allFiles {
            menu.addItem(ActionItem(selection.count == 1 ? "Open" : "Open All", symbol: "arrow.up.forward.app") {
                urls.forEach { NSWorkspace.shared.open($0) }
            })
            menu.addItem(ActionItem("Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            })
        }
        menu.addItem(ActionItem("Quick Look", symbol: "eye") { [weak self] in
            guard let self else { return }
            self.setSelection(selection, anchor: selection.first, cursor: selection.last)
            self.toggleQuickLook()
        })
        menu.addItem(ActionItem("Copy", symbol: "doc.on.doc") { [weak self] in self?.copy(selection) })
        if isClipboard, selection.count == 1, let clip = selection.first {
            menu.addItem(ActionItem(clip.isPinned ? "Unpin Clip" : "Pin Clip", symbol: clip.isPinned ? "pin.slash" : "pin") {
                [weak self] in self?.togglePin(clip)
            })
        }

        // Sending.
        menu.addItem(.separator())
        menu.addItem(ActionItem("AirDrop", symbol: "airplayaudio") { [weak self] in self?.airDrop(selection) })
        let picker = NSSharingServicePicker(items: selection.map(\.shareable))
        sharePicker = picker  // the Share submenu needs its picker kept alive
        menu.addItem(picker.standardShareMenuItem)
        guard allFiles else { return menu.addItem(.separator()) }

        // Making new files.
        menu.addItem(.separator())
        menu.addItem(ActionItem("Compress to ZIP", symbol: "doc.zipper") { [weak self] in self?.compress(selection) })
        let images = selection.filter { $0.kind == "Image" }
        if !images.isEmpty && images.count == selection.count {
            menu.addItem(imageSubmenu("Resize Image", symbol: "arrow.down.right.and.arrow.up.left",
                                      options: Actions.resizeOptions.map { mode in
                (mode.title, { [weak self] in
                    self?.run(busy: "Resizing…", work: { urls.compactMap { Actions.resize($0, mode) } })
                })
            }))
            let currentTypes = Set(urls.compactMap(Actions.imageType(of:)))
            menu.addItem(imageSubmenu("Convert Image", symbol: "arrow.triangle.2.circlepath",
                                      options: Actions.convertOptions.compactMap { option in
                // Converting to the format they already all have would do nothing.
                guard currentTypes != [option.type] else { return nil }
                return ("To \(option.title)", { [weak self] in
                    self?.run(busy: "Converting…", work: {
                        urls.filter { Actions.imageType(of: $0) != option.type }
                            .compactMap { Actions.convert($0, to: option.type) }
                    })
                })
            }))
            menu.addItem(ActionItem("Copy Text from Image", symbol: "text.viewfinder") { [weak self] in
                self?.copyText(from: urls)
            })
        }
        menu.addItem(.separator())
    }

    // MARK: Sending (also used by the grid's action bar)

    func airDrop(_ selection: [ShelfItem]) {
        NSApp.activate()
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: selection.map(\.shareable))
    }

    func share(_ selection: [ShelfItem], from view: NSView) {
        let picker = NSSharingServicePicker(items: selection.map(\.shareable))
        sharePicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func compress(_ selection: [ShelfItem]) {
        let urls = selection.compactMap(\.url)
        guard !urls.isEmpty else { return NSSound.beep() }
        run(busy: "Compressing…", work: { Actions.compress(urls).map { [$0] } ?? [] })
    }

    private func imageSubmenu(_ title: String, symbol: String, options: [(String, () -> Void)]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        options.forEach { title, handler in submenu.addItem(ActionItem(title, handler: handler)) }
        item.submenu = submenu
        return item
    }

    // MARK: Actions

    /// Runs an action in the background, then puts its results on this shelf, selected.
    private func run(busy: String, work: @escaping () -> [URL]) {
        view.flash(busy, sticky: true)
        Actions.queue.async {
            let results = work()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !results.isEmpty else {
                    NSSound.beep()
                    self.view.flash("Couldn't do that")
                    return
                }
                let added = results.map { ShelfItem(url: $0) }
                self.add(added)
                self.setSelection(added, anchor: added.first, cursor: added.last)
                if let last = added.last { self.view.scrollTo(last) }
                self.view.flash(added.count == 1 ? "Added \(added[0].name)" : "Added \(added.count) files")
            }
        }
    }

    private func copyText(from urls: [URL]) {
        view.flash("Reading text…", sticky: true)
        Actions.queue.async {
            let text = Actions.recognizeText(in: urls)
            DispatchQueue.main.async { [weak self] in
                guard !text.isEmpty else {
                    self?.view.flash("No text found")
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let lines = text.split(whereSeparator: \.isNewline).count
                self?.view.flash(lines == 1 ? "Copied 1 line" : "Copied \(lines) lines")
            }
        }
    }
}

// MARK: - Quick Look

extension ShelfController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The selection, or everything when nothing is selected.
    private var quickLookItems: [ShelfItem] { selectedItems.isEmpty ? items : selectedItems }

    /// The shared Quick Look panel, if it is open and showing this shelf.
    fileprivate var quickLookPanelIfOurs: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
              preview.isVisible, (preview.dataSource as AnyObject?) === self else { return nil }
        return preview
    }

    func toggleQuickLook() {
        if let peek = host?.peek, peek.isShowing { return peek.close() }
        if !items.isEmpty, selectedItems.isEmpty, let start = cursor ?? items.first { select(start) }
        if let item = selectedItems.first, item.url == nil { return showPeek(item) }
        guard let preview = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && preview.isVisible {
            preview.orderOut(nil)
            return
        }
        guard !items.isEmpty else { return }
        // Like Finder: with nothing selected, start from the first item (or where the arrows left off).
        if selectedItems.isEmpty, let start = cursor ?? items.first { select(start) }
        // Quick Look needs Dropod in front; only ever on an explicit Space or menu choice.
        NSApp.activate()
        host?.panel.makeKey()
        preview.makeKeyAndOrderFront(nil)
        preview.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItems[index].quickLookURL as NSURL
    }

    /// Space closes the preview again; the arrow keys move to the previous or next item,
    /// and the preview follows, like in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case kVK_Space:
            panel.orderOut(nil)
            return true
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            return handleKey(event)
        default:
            return false
        }
    }

    /// Zoom in from (and back into) the item's thumbnail.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL, let shelfItem = items.first(where: { $0.quickLookURL == url })
        else { return .zero }
        return view.screenFrame(for: shelfItem)
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        return items.first { $0.quickLookURL == url }?.thumbnail
    }
}
