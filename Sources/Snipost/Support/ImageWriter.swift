import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var isLossy: Bool { self != .png }
}

enum ImageWriter {
    static func write(_ image: CGImage, to path: String, format: ExportFormat = .png) -> Bool {
        var output = image
        if format.isLossy, let flattened = flattenedOnWhite(image) {
            output = flattened // JPEG/HEIC can't hold transparency
        }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { return false }

        // Tag Retina DPI (144 on a 2× screen) so apps show the capture at its
        // real on-screen size, crisp, instead of blown up 2×.
        var options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * retinaScale,
            kCGImagePropertyDPIHeight: 72 * retinaScale,
        ]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Encodes PNG bytes with the Retina DPI tag (used for the clipboard).
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * retinaScale,
            kCGImagePropertyDPIHeight: 72 * retinaScale,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Backing scale of the main display, read once (thread-safe afterwards).
    static let retinaScale: CGFloat = {
        if Thread.isMainThread { return NSScreen.main?.backingScaleFactor ?? 2 }
        return DispatchQueue.main.sync { NSScreen.main?.backingScaleFactor ?? 2 }
    }()

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
