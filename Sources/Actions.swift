import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The work behind the quick actions. Every result is a new file in Dropod's own
/// storage; the originals are never changed. These are slow, so call them off the
/// main thread (on `queue`).
enum Actions {
    static let queue = DispatchQueue(label: "Dropod.actions", qos: .userInitiated)

    enum Resize {
        case half
        case longestSide(Int)

        var title: String {
            switch self {
            case .half: return "50%"
            case .longestSide(let pixels): return "Longest Side \(pixels) px"
            }
        }

        /// Added to the file name, as in "Beach 1080px.jpg".
        var suffix: String {
            switch self {
            case .half: return "50%"
            case .longestSide(let pixels): return "\(pixels)px"
            }
        }
    }

    static let resizeOptions: [Resize] = [.half, .longestSide(2048), .longestSide(1080)]
    static let convertOptions: [(title: String, type: UTType)] = [("JPEG", .jpeg), ("PNG", .png), ("HEIC", .heic)]

    // MARK: ZIP

    /// One item becomes "name.zip"; several are gathered into "Archive.zip", like Finder.
    static func compress(_ urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let fileManager = FileManager.default
        let folder = DropStore.newFolder()
        var source = urls[0]
        var staging: URL?
        if urls.count > 1 {
            // Copies on the same disk are instant clones, so this costs no space or time.
            let gathered = folder.appendingPathComponent("Archive", isDirectory: true)
            try? fileManager.createDirectory(at: gathered, withIntermediateDirectories: true)
            for url in urls {
                try? fileManager.copyItem(at: url, to: gathered.appendingPathComponent(url.lastPathComponent))
            }
            source = gathered
            staging = gathered
        }
        let zip = folder.appendingPathComponent(source.lastPathComponent + ".zip")

        // A folder keeps its name inside the zip; a single file goes in on its own.
        // No Mac-only extras (__MACOSX), so the zip is clean on Windows and in web uploads.
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]
            + (isFolder ? ["--keepParent"] : []) + [source.path, zip.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        if let staging { try? fileManager.removeItem(at: staging) }
        return process.terminationStatus == 0 ? zip : nil
    }

    // MARK: Images

    /// Scales down (never up), keeping the format when it can be written back.
    static func resize(_ url: URL, _ mode: Resize) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let longest = max(width, height)
        let target: Int
        switch mode {
        case .half: target = max(1, longest / 2)
        case .longestSide(let pixels): target = min(pixels, longest)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // bakes in the photo's rotation
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let type = writableType(of: source)
        // Same format: keep the original extension ("jpg" stays "jpg").
        let ext = imageType(of: url) == type && !url.pathExtension.isEmpty ? url.pathExtension : fileExtension(for: type)
        let name = url.deletingPathExtension().lastPathComponent + " \(mode.suffix)." + ext
        let output = DropStore.newFolder().appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output : nil
    }

    /// Re-encodes in another format, keeping metadata and orientation.
    static func convert(_ url: URL, to type: UTType) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent + "." + fileExtension(for: type)
        let output = DropStore.newFolder().appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output : nil
    }

    static func imageType(of url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// "jpg" rather than "jpeg", as people expect.
    private static func fileExtension(for type: UTType) -> String {
        type == .jpeg ? "jpg" : (type.preferredFilenameExtension ?? "png")
    }

    private static func writableType(of source: CGImageSource) -> UTType {
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? .png
        return [UTType.jpeg, .png, .heic].contains(type) ? type : .png
    }

    // MARK: Text

    /// Reads the text in images with on-device recognition. Empty when there is none.
    static func recognizeText(in urls: [URL]) -> String {
        urls.compactMap { url -> String? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init) ?? .up

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
