import CoreGraphics

/// Whole-image operations the editor performs on the capture itself — as
/// opposed to the beautify pass, which only ever draws it.
enum ImageOps {
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    enum Axis {
        case vertical
        case horizontal
    }

    /// Puts captures on one canvas. Off-axis sizes are matched by centring, not
    /// stretching, so nothing gets distorted to fit.
    static func stacked(_ images: [CGImage], axis: Axis, gap: CGFloat = 0, background: CGColor? = nil) -> CGImage? {
        guard !images.isEmpty else { return nil }
        guard images.count > 1 else { return images[0] }

        let widths = images.map { CGFloat($0.width) }
        let heights = images.map { CGFloat($0.height) }
        let gaps = gap * CGFloat(images.count - 1)

        let canvasWidth: CGFloat
        let canvasHeight: CGFloat
        switch axis {
        case .vertical:
            canvasWidth = widths.max() ?? 1
            canvasHeight = heights.reduce(0, +) + gaps
        case .horizontal:
            canvasWidth = widths.reduce(0, +) + gaps
            canvasHeight = heights.max() ?? 1
        }

        guard let context = CGContext(
            data: nil,
            width: Int(canvasWidth.rounded()),
            height: Int(canvasHeight.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        }
        context.interpolationQuality = .high

        // CG draws bottom-up, so a vertical stack lays out from the last image.
        var offset: CGFloat = 0
        let order = axis == .vertical ? Array(images.reversed()) : images
        for image in order {
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            let rect: CGRect
            switch axis {
            case .vertical:
                rect = CGRect(x: (canvasWidth - width) / 2, y: offset, width: width, height: height)
                offset += height + gap
            case .horizontal:
                rect = CGRect(x: offset, y: (canvasHeight - height) / 2, width: width, height: height)
                offset += width + gap
            }
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }
}
