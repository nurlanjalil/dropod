import AppKit

/// Notices new screenshots in the folder macOS saves them to, so they can go to the
/// clipboard and the Screenshots tab. The file itself is left where macOS put it.
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    var onScreenshot: ((URL) -> Void)?

    /// The folder being watched, for the menu.
    private(set) var folder: URL?

    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var locationCheck: Timer?

    private static let domain = "com.apple.screencapture" as CFString

    func start() {
        watch(Self.screenshotFolder())
        // Follow the folder if it is changed in ⇧⌘5 → Options, and retry if it couldn't be
        // opened yet (for example while macOS is still asking for access to the folder).
        locationCheck?.invalidate()
        locationCheck = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = Self.screenshotFolder()
            if current != self.folder || self.source == nil { self.watch(current) }
        }
    }

    func stop() {
        locationCheck?.invalidate()
        locationCheck = nil
        source?.cancel()
        source = nil
        folder = nil
    }

    /// Where macOS saves screenshots: the setting from ⇧⌘5 → Options, or the Desktop.
    static func screenshotFolder() -> URL {
        // Newer macOS reads "location-screenshot"; earlier versions read "location".
        for key in ["location-screenshot", "location"] {
            if let path = CFPreferencesCopyAppValue(key as CFString, domain) as? String, !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                    return url.standardizedFileURL
                }
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func watch(_ url: URL) {
        source?.cancel()
        source = nil
        folder = url
        // Everything already there is old; only files that appear from now on count.
        known = Set(contents(of: url))

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func folderChanged() {
        guard let folder else { return }
        let names = contents(of: folder)
        let fresh = names.filter { !known.contains($0) }
        known = Set(names)
        for name in fresh {
            let url = folder.appendingPathComponent(name)
            // Give macOS a moment to finish writing before reading the file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard Self.isScreenshot(url) else { return }
                self?.onScreenshot?(url)
            }
        }
    }

    private func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// macOS marks every screenshot file with this attribute; recordings and other files don't have it.
    private static func isScreenshot(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let marked = getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        let image = ["png", "jpg", "jpeg", "heic", "tiff", "pdf", "gif", "bmp"].contains(url.pathExtension.lowercased())
        return marked && image
    }

    // MARK: Clipboard

    /// Puts the image on the clipboard the way ⌃⇧⌘4 does, ready for ⌘V anywhere.
    static func copyToClipboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
    }

    // MARK: Floating thumbnail

    /// Turns macOS's floating thumbnail off (screenshots save instantly) or back to how it was.
    static func setInstant(_ instant: Bool) {
        let key = "show-thumbnail" as CFString
        if instant {
            let previous = CFPreferencesCopyAppValue(key, domain) as? Bool
            UserDefaults.standard.set(previous.map { $0 ? "on" : "off" } ?? "default", forKey: "thumbnailBeforeInstant")
            CFPreferencesSetAppValue(key, false as CFPropertyList, domain)
        } else {
            switch UserDefaults.standard.string(forKey: "thumbnailBeforeInstant") {
            case "off": CFPreferencesSetAppValue(key, false as CFPropertyList, domain)
            case "on": CFPreferencesSetAppValue(key, true as CFPropertyList, domain)
            default: CFPreferencesSetAppValue(key, nil, domain)  // back to the macOS default
            }
        }
        // Written through cfprefsd, so the screenshot service sees it right away.
        CFPreferencesAppSynchronize(domain)
    }
}
