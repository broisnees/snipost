import CoreGraphics

/// Random pixel access to a CGImage: where a window capture's real pixels stop
/// (alpha) and what colour sits under the pointer (colour). `y` is measured
/// from the top, matching CGImage rows and `cropping(to:)`, not the bottom-up
/// drawing space.
struct PixelMap {
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

    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        rgba[(y * width + x) * 4 + 3]
    }

    /// Un-premultiplied, so picking a colour out of a translucent region
    /// reports the colour rather than the colour times its alpha.
    func color(_ x: Int, _ y: Int) -> RGB {
        let offset = (y * width + x) * 4
        let a = CGFloat(rgba[offset + 3]) / 255
        guard a > 0 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: min(CGFloat(rgba[offset]) / 255 / a, 1),
            g: min(CGFloat(rgba[offset + 1]) / 255 / a, 1),
            b: min(CGFloat(rgba[offset + 2]) / 255 / a, 1)
        )
    }

    func hex(_ x: Int, _ y: Int) -> String {
        let rgb = color(x, y)
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.r * 255).rounded()),
            Int((rgb.g * 255).rounded()),
            Int((rgb.b * 255).rounded())
        )
    }
}
