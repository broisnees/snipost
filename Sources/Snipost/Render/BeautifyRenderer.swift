import AppKit
import CoreGraphics

/// Pure CoreGraphics compositor: background → shadow → rounded screenshot → cursor.
/// Fast enough to re-render live while dragging sliders.
enum BeautifyRenderer {
    static func render(
        image: CGImage,
        settings: BeautifySettings,
        autoColors: [RGB],
        backgroundImage: CGImage? = nil,
        maxDimension: CGFloat? = nil,
        logicalSize: CGSize? = nil
    ) -> CGImage? {
        // Previews pass a downscaled image with the original's logical size,
        // so layout (padding, radius, cursor) matches the full render exactly.
        let imageWidth = logicalSize?.width ?? CGFloat(image.width)
        let imageHeight = logicalSize?.height ?? CGFloat(image.height)
        let padding = settings.paddingFraction * max(imageWidth, imageHeight)

        // Canvas grows around the screenshot; aspect presets expand it further
        // (never crop) to hit platform ratios.
        var canvasWidth = imageWidth + padding * 2
        var canvasHeight = imageHeight + padding * 2
        if let ratio = settings.aspect.ratio {
            if canvasWidth / canvasHeight < ratio {
                canvasWidth = canvasHeight * ratio
            } else {
                canvasHeight = canvasWidth / ratio
            }
        }

        var scale: CGFloat = 1
        if let maxDimension, max(canvasWidth, canvasHeight) > maxDimension {
            scale = maxDimension / max(canvasWidth, canvasHeight)
        }

        let pixelWidth = Int((canvasWidth * scale).rounded())
        let pixelHeight = Int((canvasHeight * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = RenderColor.space(for: image)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let canvasSize = CGSize(width: pixelWidth, height: pixelHeight)
        drawBackground(
            in: context,
            size: canvasSize,
            settings: settings,
            autoColors: autoColors,
            backgroundImage: backgroundImage
        )

        let drawWidth = imageWidth * scale
        let drawHeight = imageHeight * scale
        let imageRect = CGRect(
            x: (CGFloat(pixelWidth) - drawWidth) / 2,
            y: (CGFloat(pixelHeight) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        let radius = min(settings.cornerRadius * scale, min(drawWidth, drawHeight) / 2)
        let path = CGPath(
            roundedRect: imageRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // Shadow pass: fill the rounded rect with the shadow enabled, then draw
        // the clipped screenshot on top.
        if settings.shadowOpacity > 0.01 {
            context.saveGState()
            let blur = 0.035 * max(imageWidth, imageHeight) * scale
            let offsetY = -0.012 * max(imageWidth, imageHeight) * scale
            context.setShadow(
                offset: CGSize(width: 0, height: offsetY),
                blur: blur,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: settings.shadowOpacity)
            )
            context.addPath(path)
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        context.restoreGState()

        drawCursor(in: context, canvasSize: canvasSize, settings: settings, scale: scale)

        return context.makeImage()
    }

    private static func drawBackground(
        in context: CGContext,
        size: CGSize,
        settings: BeautifySettings,
        autoColors: [RGB],
        backgroundImage: CGImage?
    ) {
        switch settings.background {
        case .transparent:
            return

        case .image:
            if let backgroundImage {
                drawAspectFill(backgroundImage, in: context, size: size)
                return
            }
            // No image picked yet — fall back to the auto gradient.
            drawGradient(colors: autoColors, in: context, size: size)

        case .auto:
            drawGradient(colors: autoColors, in: context, size: size)

        case .preset(let preset):
            drawGradient(colors: preset.colors, in: context, size: size)

        case .solid(let color):
            // A solid must stay flat — no glow, or black turns into a gradient.
            drawGradient(colors: [color, color], in: context, size: size, glow: false)

        case .customGradient(let start, let end):
            drawGradient(colors: [start, end], in: context, size: size)
        }
    }

    private static func drawGradient(colors: [RGB], in context: CGContext, size: CGSize, glow: Bool = true) {
        let cgColors = colors.map { CGColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
        guard cgColors.count >= 2 else {
            if let first = cgColors.first {
                context.setFillColor(first)
                context.fill(CGRect(origin: .zero, size: size))
            }
            return
        }

        let locations = (0..<cgColors.count).map { CGFloat($0) / CGFloat(cgColors.count - 1) }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cgColors as CFArray,
            locations: locations
        ) else { return }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: size.width, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        // Soft radial glow near the top — the "presentation ready" studio look.
        guard glow else { return }
        if let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.92)
            context.drawRadialGradient(
                highlight,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: max(size.width, size.height) * 0.75,
                options: []
            )
        }
    }

    private static func drawAspectFill(_ image: CGImage, in context: CGContext, size: CGSize) {
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let canvasAspect = size.width / size.height
        var drawRect = CGRect(origin: .zero, size: size)
        if imageAspect > canvasAspect {
            let width = size.height * imageAspect
            drawRect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / imageAspect
            drawRect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        context.restoreGState()
    }

    private static func drawCursor(
        in context: CGContext,
        canvasSize: CGSize,
        settings: BeautifySettings,
        scale: CGFloat
    ) {
        guard settings.cursor != .none else { return }

        let size = settings.cursorSize * scale
        // cursorPosition is normalized with y measured from the top; CG is bottom-up.
        let tip = CGPoint(
            x: settings.cursorPosition.x * canvasSize.width,
            y: (1 - settings.cursorPosition.y) * canvasSize.height
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.08),
            blur: size * 0.22,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        )
        CursorArt.draw(settings.cursor, in: context, tip: tip, size: size)
        context.restoreGState()
    }
}

/// Keep the capture's own color space (Display P3 on most Macs) so saturated
/// colors aren't clipped; fall back to sRGB for anything a bitmap can't use.
enum RenderColor {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func space(for image: CGImage) -> CGColorSpace {
        guard let space = image.colorSpace, space.model == .rgb, space.supportsOutput else { return sRGB }
        return space
    }
}
