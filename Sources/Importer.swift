import AppKit

/// Turns whatever was dropped on a shelf into shelf items: files as they are, and
/// everything else (promised files, images, links, text) saved as real files in
/// Dropod's own storage so it can be dragged out again later.
enum Importer {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, .string]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    private static let urlName = NSPasteboard.PasteboardType("public.url-name")
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Files or folders are being dragged (as opposed to text, links or images).
    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions)
    }

    static func canImport(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self, NSImage.self, NSString.self], options: nil)
    }

    /// Reads what it can right away; promised files arrive later through `add`.
    /// Returns false when nothing on the pasteboard could be used.
    static func read(_ pasteboard: NSPasteboard, add: @escaping ([ShelfItem]) -> Void) -> Bool {
        // Files and folders: kept by reference.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            add(urls.map { ShelfItem(url: $0) })
            return true
        }

        // Promised files: Mail attachments, Photos, images dragged from some browsers.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let folder = DropStore.newFolder()
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { add([ShelfItem(url: url)]) }
                }
            }
            return true
        }

        // Image data without a file.
        if let png = pngData(from: pasteboard),
           let url = DropStore.write(png, named: "Image \(DropStore.timestamp).png") {
            add([ShelfItem(url: url)])
            return true
        }

        // A web link: saved as a .webloc named after the page.
        if let links = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let link = links.first(where: { !$0.isFileURL }) {
            let title = pasteboard.string(forType: urlName) ?? link.host ?? "Link"
            let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString],
                                                            format: .xml, options: 0)
            if let plist, let url = DropStore.write(plist, named: DropStore.fileName(from: title) + ".webloc") {
                add([ShelfItem(url: url, content: .link(link))])
                return true
            }
        }

        // Plain text: a text card, no file.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add([ShelfItem(note: text)])
            return true
        }
        return false
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard pasteboard.availableType(from: [.tiff]) != nil,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Where dropped text, images, links and promised files are saved:
/// ~/Library/Application Support/Dropod/Drops/<one folder per drop>/
enum DropStore {
    static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dropod/Drops", isDirectory: true)
    }()

    /// A fresh folder per drop, so names never collide.
    static func newFolder() -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(_ data: Data, named name: String) -> URL? {
        let url = newFolder().appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Removes drop folders that no saved shelf uses any more.
    static func clearUnused(keeping paths: Set<String>) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let prefix = folder.standardizedFileURL.path + "/"
            if !paths.contains(where: { $0.hasPrefix(prefix) }) {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    static var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// A short, safe file name from arbitrary text.
    static func fileName(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Untitled" : short
    }
}
