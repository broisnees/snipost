import CoreGraphics

/// Per-pixel alpha of a CGImage — how we find where a window capture's real
/// pixels stop and its transparent shadow margin or rounded corner begins.
/// `y` is measured from the top, matching CGImage rows (and `cropping(to:)`),
/// not the bottom-up drawing space.
struct AlphaMap {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.rgba = pixels
    }

    subscript(x: Int, y: Int) -> UInt8 {
        rgba[(y * width + x) * 4 + 3]
    }
}
