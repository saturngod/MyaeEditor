//
//  ImageLoader.swift
//  MyaeEditorKit
//
//  Off-main image downsampling with a bounded cache. Editor images are displayed
//  at no more than 520×400 points, so decoding a camera's full-resolution bitmap
//  wastes memory and can stall scrolling.
//

import AppKit
import ImageIO

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 128
    }

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? canonicalURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        let key = "\(canonicalURL.path)|\(stamp)|\(fileSize)|\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let image = await Task.detached(priority: .utility) {
            PerformanceTrace.measure("ImageDecode") {
                Self.downsample(url: canonicalURL, maxPixelSize: maxPixelSize)
            }
        }.value
        guard !Task.isCancelled, let image else { return nil }

        let pixels = image.representations.reduce(0) { partial, representation in
            max(partial, representation.pixelsWide * representation.pixelsHigh)
        }
        cache.setObject(image, forKey: key, cost: max(1, pixels * 4))
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    nonisolated private static func downsample(url: URL, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Construct an explicit bitmap representation. `NSImage(cgImage:size:)`
        // can synthesize a 2× representation under a Retina test/application
        // context, which partially reverses the requested pixel bound.
        let representation = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(representation)
        return image
    }
}
