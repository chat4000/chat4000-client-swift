import Foundation
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let dimensionsCache = NSCache<NSString, CachedImageDimensions>()

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        dimensionsCache.countLimit = 800
    }

    func dimensions(id: String, data: Data) -> CGSize? {
        let key = NSString(string: "\(id)|\(data.count)")
        if let cached = dimensionsCache.object(forKey: key) {
            return cached.size
        }
        guard let dimensions = Self.readDimensions(data: data) else {
            return nil
        }
        dimensionsCache.setObject(CachedImageDimensions(size: dimensions), forKey: key)
        return dimensions
    }

    func image(id: String, data: Data, maxPixelSize: CGFloat) async -> PlatformImage? {
        let key = NSString(string: "\(id)|\(data.count)|\(Int(maxPixelSize.rounded()))")
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = await Self.downsample(data: data, maxPixelSize: maxPixelSize) else {
            return nil
        }
        cache.setObject(decoded.image, forKey: key, cost: decoded.cost)
        return decoded.image
    }

    private static func readDimensions(data: Data) -> CGSize? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any],
              let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let int as Int:
            return Double(int)
        case let double as Double:
            return double
        default:
            return nil
        }
    }

    private static func downsample(
        data: Data,
        maxPixelSize: CGFloat
    ) async -> (image: PlatformImage, cost: Int)? {
        await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                return nil
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded()))
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                return nil
            }
            let cost = cgImage.width * cgImage.height * 4
            #if os(iOS)
            return (UIImage(cgImage: cgImage), cost)
            #else
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return (image, cost)
            #endif
        }.value
    }
}

private final class CachedImageDimensions: NSObject {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
    }
}
