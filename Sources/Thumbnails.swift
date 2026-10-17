import AppKit
import QuickLookThumbnailing

/// Real previews (images, PDFs, videos, documents) made by QuickLook in the background.
/// Files without a preview keep their Finder icon.
enum Thumbnails {
    static func load(_ url: URL, completion: @escaping (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 160, height: 160),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
