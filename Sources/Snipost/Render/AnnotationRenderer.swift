import AppKit
import CoreGraphics
import CoreImage

enum AnnotationTool: String, CaseIterable, Identifiable {
    case move = "Move"
    case arrow = "Arrow"
    case box = "Box"
    case text = "Text"
    case blur = "Blur"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .move: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .text: return "textformat"
        case .blur: return "eye.slash"
        }
    }
}

/// One drawn markup. Points are in source-image pixels with y measured from
/// the top (same orientation as the preview).
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var text: String
    var color: RGB

    init(tool: AnnotationTool, start: CGPoint, end: CGPoint, text: String = "", color: RGB) {
        self.id = UUID()
        self.tool = tool
        self.start = start
        self.end = end
        self.text = text
        self.color = color
    }

    /// Same markup at another image scale (previews render at reduced size).
    func scaled(by factor: CGFloat) -> Annotation {
        guard factor != 1 else { return self }
        var copy = self
        copy.start = CGPoint(x: start.x * factor, y: start.y * factor)
        copy.end = CGPoint(x: end.x * factor, y: end.y * factor)
        return copy
    }

    static let palette: [RGB] = [
        RGB(r: 0.93, g: 0.26, b: 0.21), // red
        RGB(r: 1.00, g: 0.58, b: 0.00), // orange
        RGB(r: 1.00, g: 0.80, b: 0.00), // yellow
        RGB(r: 0.04, g: 0.52, b: 1.00), // blue
        RGB(r: 1.00, g: 1.00, b: 1.00), // white
        RGB(r: 0.05, g: 0.05, b: 0.05), // black
    ]
}

/// Bakes annotations onto the (filtered) screenshot before the beautify pass,
/// so the compositor itself stays unchanged.
enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func compose(_ base: CGImage, annotations: [Annotation]) -> CGImage {
        guard !annotations.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: RenderColor.space(for: base),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(base, in: fullRect)

        for annotation in annotations {
            draw(annotation, in: ctx, base: base, height: CGFloat(height), minSide: CGFloat(min(width, height)))
        }
        return ctx.makeImage() ?? base
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, base: CGImage, height: CGFloat, minSide: CGFloat) {
        // Flip stored top-down points into CG's bottom-up space.
        let start = CGPoint(x: a.start.x, y: height - a.start.y)
        let end = CGPoint(x: a.end.x, y: height - a.end.y)
        let lineWidth = max(3, minSide * 0.006)
        let color = CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: 1)

        switch a.tool {
        case .move:
            break

        case .arrow:
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            guard length > 8 else { break }
            let angle = atan2(dy, dx)
            let headLength = min(4.5 * lineWidth, length * 0.4)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -lineWidth * 0.4), blur: lineWidth, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            let shaftEnd = CGPoint(
                x: end.x - cos(angle) * headLength * 0.7,
                y: end.y - sin(angle) * headLength * 0.7
            )
            ctx.move(to: start)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()

            let spread: CGFloat = .pi / 7
            let left = CGPoint(
                x: end.x - cos(angle - spread) * headLength,
                y: end.y - sin(angle - spread) * headLength
            )
            let right = CGPoint(
                x: end.x - cos(angle + spread) * headLength,
                y: end.y - sin(angle + spread) * headLength
            )
            ctx.setFillColor(color)
            ctx.move(to: end)
            ctx.addLine(to: left)
            ctx.addLine(to: right)
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()

        case .box:
            let rect = normalizedRect(start, end)
            guard rect.width > 4, rect.height > 4 else { break }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -lineWidth * 0.4), blur: lineWidth, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            let path = CGPath(roundedRect: rect, cornerWidth: lineWidth, cornerHeight: lineWidth, transform: nil)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

        case .text:
            guard !a.text.isEmpty else { break }
            let fontSize = max(18, minSide * 0.035)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: 1),
            ]
            let string = NSAttributedString(string: a.text, attributes: attributes)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.14, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            string.draw(at: NSPoint(x: start.x, y: start.y - fontSize))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()

        case .blur:
            // Pixellate the covered region — stored coords are already top-down,
            // which is what CGImage.cropping expects.
            let topDownRect = normalizedRect(a.start, a.end).integral
            guard topDownRect.width > 6, topDownRect.height > 6,
                  let patch = base.cropping(to: topDownRect)
            else { break }
            let ci = CIImage(cgImage: patch)
            let scale = max(10, min(topDownRect.width, topDownRect.height) / 8)
            let pixellated = ci.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale,
                kCIInputCenterKey: CIVector(x: ci.extent.midX, y: ci.extent.midY),
            ]).cropped(to: ci.extent)
            guard let output = ciContext.createCGImage(pixellated, from: pixellated.extent) else { break }
            let drawRect = CGRect(
                x: topDownRect.minX,
                y: height - topDownRect.maxY,
                width: topDownRect.width,
                height: topDownRect.height
            )
            ctx.draw(output, in: drawRect)
        }
    }

    private static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
