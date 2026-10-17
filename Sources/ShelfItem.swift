import AppKit
import UniformTypeIdentifiers

/// Something sitting on a shelf: a file (kept by reference, never copied) or a piece of text.
final class ShelfItem {
    /// What was originally dropped or copied, so dragging it out can offer the right thing.
    enum Content {
        case file
        /// A .txt file from an older version, with its text.
        case text(String)
        case link(URL)
        /// A text card: text without any file, from the clipboard or dropped text.
        case note(String)
    }

    /// The file, or nil for a text card.
    let url: URL?
    let content: Content
    var thumbnail: NSImage
    /// True once there is a real preview (a QuickLook thumbnail, or a text card's drawing).
    var hasPreview = false
    /// A short kind such as "Image" or "PDF".
    let kind: String
    /// A file-type tag for the thumbnail, such as "HEIC" or "ZIP". Nil for folders, apps and text cards.
    let tag: String?
    /// "Image · 2.4 MB"
    let details: String

    /// When it was added; screenshots and clips leave after a set time. A clip copied
    /// again moves back to the top with a new time.
    var addedAt: Date
    /// A pinned clip never expires.
    var isPinned = false
    /// The app a clip was copied from (bundle identifier), for its icon.
    var sourceApp: String?
    /// The copied text was longer than a clip keeps (100,000 characters) and was cut.
    var wasCut = false

    init(url: URL, content: Content = .file, addedAt: Date = Date()) {
        self.url = url.standardizedFileURL
        self.content = content
        self.addedAt = addedAt
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        let info = ShelfItem.describe(url.standardizedFileURL)
        kind = info.kind
        tag = info.tag
        details = info.size.map { "\(info.kind) · \($0)" } ?? info.kind
    }

    /// A text card.
    init(note text: String, addedAt: Date = Date(), sourceApp: String? = nil) {
        url = nil
        content = .note(text)
        self.addedAt = addedAt
        self.sourceApp = sourceApp
        thumbnail = TextCard.image(for: text)
        hasPreview = true
        kind = "Text"
        tag = nil
        details = text.count == 1 ? "Text · 1 character" : "Text · \(text.count) characters"
    }

    var name: String {
        if let url { return FileManager.default.displayName(atPath: url.path) }
        return TextCard.title(for: text ?? "")
    }

    /// The text of a text card (or an older .txt item).
    var text: String? {
        switch content {
        case .note(let text), .text(let text): return text
        case .file, .link: return nil
        }
    }

    var isNote: Bool {
        if case .note = content { return true }
        return false
    }

    /// Two items are the same when they are the same file, or the same text.
    var identity: String { url?.path ?? "note:" + (text ?? "") }

    /// What a drag out carries. Files are offered as files. Text and links also carry
    /// the text or URL itself, so a text field gets the words and a browser gets the page.
    /// A text card is only text; dropped into Finder, macOS makes a text clipping.
    var pasteboardWriter: NSPasteboardWriting {
        let item = NSPasteboardItem()
        switch content {
        case .file:
            if let url { return url as NSURL }
        case .text(let text):
            if let url { item.setString(url.absoluteString, forType: .fileURL) }
            item.setString(text, forType: .string)
        case .link(let link):
            if let url { item.setString(url.absoluteString, forType: .fileURL) }
            item.setString(link.absoluteString, forType: .URL)
            item.setString(link.absoluteString, forType: .string)
        case .note(let text):
            item.setString(text, forType: .string)
        }
        return item
    }

    /// What sharing (AirDrop, Messages…) sends: the file, or the text.
    var shareable: Any { url ?? (text ?? "") as Any }

    /// Quick Look needs a file; a text card gets a temporary one.
    lazy var quickLookURL: URL = {
        if let url { return url }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropod Quick Look", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(DropStore.fileName(from: name) + " \(UUID().uuidString.prefix(4)).txt")
        try? (text ?? "").write(to: file, atomically: true, encoding: .utf8)
        return file
    }()

    private static func describe(_ url: URL) -> (kind: String, tag: String?, size: String?) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey, .isPackageKey])
        let type = values?.contentType
        let ext = url.pathExtension.uppercased()
        func conforms(_ other: UTType) -> Bool { type?.conforms(to: other) ?? false }

        let kind: String
        if conforms(.application) { kind = "App" }
        else if values?.isDirectory == true && values?.isPackage != true { kind = "Folder" }
        else if ext == "WEBLOC" { kind = "Link" }
        else if conforms(.pdf) { kind = "PDF" }
        else if conforms(.image) { kind = "Image" }
        else if conforms(.movie) { kind = "Video" }
        else if conforms(.audio) { kind = "Audio" }
        else if conforms(.archive) { kind = "Archive" }
        else if conforms(.text) { kind = "Text" }
        else { kind = type?.localizedDescription ?? "File" }

        let tag: String?
        switch kind {
        case "Folder", "App": tag = nil
        case "Link": tag = "LINK"
        default: tag = ext.isEmpty ? nil : String(ext.prefix(4))
        }
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return (kind, tag, size)
    }
}

/// How a text card looks: a small sheet of paper with the first lines of the text.
enum TextCard {
    /// The first line with words in it, shortened, as the card's name.
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Text"
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    static func image(for text: String) -> NSImage {
        let size = NSSize(width: 120, height: 150)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.99, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.85, alpha: 1).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(white: 0.25, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            (String(text.prefix(400)) as NSString).draw(in: rect.insetBy(dx: 10, dy: 10), withAttributes: attributes)
            return true
        }
    }
}

/// The colours a shelf can have.
enum ShelfColor: String, CaseIterable {
    case blue, purple, pink, orange, green, graphite

    var color: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }

    var title: String { rawValue.capitalized }

    /// The order new tabs get their colours in. Pink comes last: a pink or red dot in the
    /// capsule looks like a Record button.
    static let newTabOrder: [ShelfColor] = [.blue, .purple, .graphite, .orange, .green, .pink]
}
