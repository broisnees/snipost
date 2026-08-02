import AppKit
import CoreGraphics
import CoreImage

enum AnnotationTool: String, CaseIterable, Identifiable {
    case move = "Select"
    case arrow = "Arrow"
    case line = "Line"
    case box = "Box"
    case ellipse = "Ellipse"
    case pen = "Pen"
    case highlight = "Highlight"
    case text = "Text"
    case step = "Step"
    case blur = "Blur"
    case pixelate = "Pixelate"
    case redact = "Redact"
    case hideText = "Hide text"
    case erase = "Erase"
    case measure = "Measure"
    case spotlight = "Spotlight"
    /// Only ever created by pasting, so it is not in the palette.
    case image = "Image"

    var id: String { rawValue }

    /// The palette: everything you can pick and draw with.
    static var drawable: [AnnotationTool] {
        allCases.filter { $0 != .image }
    }

    var symbolName: String {
        switch self {
        case .move: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .box: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "square.grid.3x3"
        case .redact: return "rectangle.fill"
        case .hideText: return "text.badge.xmark"
        case .erase: return "eraser"
        case .measure: return "ruler"
        case .spotlight: return "flashlight.on.fill"
        case .image: return "photo"
        }
    }

    /// How a drag on the preview turns into an annotation.
    enum Input {
        case none      // selecting / moving what is already there
        case segment   // from-to: arrow, line
        case region    // a rectangle: box, blur, spotlight…
        case stroke    // every point the pointer visits
        case point     // a single click: text, step badge
    }

    var input: Input {
        switch self {
        case .move: return .none
        case .arrow, .line, .measure: return .segment
        case .box, .ellipse, .blur, .pixelate, .redact, .hideText, .erase, .spotlight: return .region
        case .image: return .none
        case .pen, .highlight: return .stroke
        case .text, .step: return .point
        }
    }

    var hint: String {
        switch self {
        case .move: return "Click a markup to select it — drag to move, ⌫ to delete"
        case .text: return "Click the preview to place text, then edit it above"
        case .step: return "Click to drop the next numbered badge"
        case .pen, .highlight: return "Draw on the preview"
        case .spotlight: return "Drag the area to keep bright"
        case .hideText: return "Drag over text to hide only the words"
        case .erase: return "Drag over something to wipe it out with the colour around it"
        case .measure: return "Drag to measure, in pixels of the capture"
        case .image: return "Drag the pasted image to place it"
        default: return "Drag on the preview to draw"
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
    /// Every point of a freehand stroke, for `.pen` and `.highlight`.
    var points: [CGPoint]
    var text: String
    var color: RGB
    /// Multiplies the stroke weight (and text size) the renderer derives from
    /// the image's own dimensions, so markup scales with the screenshot.
    var weight: CGFloat
    var stepNumber: Int
    /// Set only for `.image` overlays.
    var image: CGImage?

    init(
        tool: AnnotationTool,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = [],
        text: String = "",
        color: RGB,
        weight: CGFloat = 1,
        stepNumber: Int = 1,
        image: CGImage? = nil
    ) {
        self.id = UUID()
        self.tool = tool
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.color = color
        self.weight = weight
        self.stepNumber = stepNumber
        self.image = image
    }

    /// Hand-written because CGImage is not Equatable; identity is the right
    /// comparison for one anyway.
    static func == (lhs: Annotation, rhs: Annotation) -> Bool {
        lhs.id == rhs.id
            && lhs.tool == rhs.tool
            && lhs.start == rhs.start
            && lhs.end == rhs.end
            && lhs.points == rhs.points
            && lhs.text == rhs.text
            && lhs.color == rhs.color
            && lhs.weight == rhs.weight
            && lhs.stepNumber == rhs.stepNumber
            && lhs.image === rhs.image
    }

    static let palette: [RGB] = [
        RGB(r: 0.93, g: 0.26, b: 0.21), // red
        RGB(r: 1.00, g: 0.58, b: 0.00), // orange
        RGB(r: 1.00, g: 0.80, b: 0.00), // yellow
        RGB(r: 0.20, g: 0.78, b: 0.35), // green
        RGB(r: 0.04, g: 0.52, b: 1.00), // blue
        RGB(r: 0.69, g: 0.32, b: 0.87), // purple
        RGB(r: 1.00, g: 1.00, b: 1.00), // white
        RGB(r: 0.05, g: 0.05, b: 0.05), // black
    ]

    /// Bounding box in source-image pixels, top-down — used for hit-testing and
    /// for drawing selection handles over the preview.
    func bounds(minSide: CGFloat) -> CGRect {
        switch tool.input {
        case .stroke:
            guard let first = points.first else { return CGRect(origin: start, size: .zero) }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            let pad = AnnotationRenderer.strokeWidth(weight: weight, minSide: minSide)
            return box.insetBy(dx: -pad, dy: -pad)
        case .point:
            let size = tool == .step
                ? AnnotationRenderer.badgeRadius(weight: weight, minSide: minSide) * 2
                : AnnotationRenderer.fontSize(weight: weight, minSide: minSide)
            return tool == .step
                ? CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)
                : CGRect(x: start.x, y: start.y - size, width: max(size * 3, 40), height: size * 1.4)
        default:
            let box = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
            guard tool != .image else { return AnnotationRenderer.scaled(box, by: weight) }
            let pad = AnnotationRenderer.strokeWidth(weight: weight, minSide: minSide)
            return box.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Shifted by a drag, in source-image pixels.
    func translated(by delta: CGSize) -> Annotation {
        var moved = self
        moved.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        moved.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        moved.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return moved
    }
}

/// Bakes annotations onto the (filtered) screenshot before the beautify pass,
/// so the compositor itself stays unchanged.
enum AnnotationRenderer {
    static func strokeWidth(weight: CGFloat, minSide: CGFloat) -> CGFloat {
        max(2, minSide * 0.006) * weight
    }

    static func fontSize(weight: CGFloat, minSide: CGFloat) -> CGFloat {
        max(14, minSide * 0.035) * weight
    }

    static func badgeRadius(weight: CGFloat, minSide: CGFloat) -> CGFloat {
        max(14, minSide * 0.026) * weight
    }

    static func compose(_ base: CGImage, annotations: [Annotation]) -> CGImage {
        guard !annotations.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(base, in: fullRect)

        // Obscuring tools sample the untouched screenshot, so they go first and
        // markup lands on top of them rather than being blurred away.
        let ordered = annotations.filter { $0.tool.obscures } + annotations.filter { !$0.tool.obscures }
        for annotation in ordered {
            draw(annotation, in: ctx, base: base, height: CGFloat(height), minSide: CGFloat(min(width, height)))
        }
        return ctx.makeImage() ?? base
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, base: CGImage, height: CGFloat, minSide: CGFloat) {
        // Flip stored top-down points into CG's bottom-up space.
        let start = CGPoint(x: a.start.x, y: height - a.start.y)
        let end = CGPoint(x: a.end.x, y: height - a.end.y)
        let lineWidth = strokeWidth(weight: a.weight, minSide: minSide)
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
            dropShadow(in: ctx, lineWidth: lineWidth)
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

        case .line:
            guard hypot(end.x - start.x, end.y - start.y) > 4 else { break }
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: lineWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
            ctx.restoreGState()

        case .box:
            let rect = normalizedRect(start, end)
            guard rect.width > 4, rect.height > 4 else { break }
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: lineWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineWidth, cornerHeight: lineWidth, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()

        case .ellipse:
            let rect = normalizedRect(start, end)
            guard rect.width > 4, rect.height > 4 else { break }
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: lineWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.strokeEllipse(in: rect)
            ctx.restoreGState()

        case .pen:
            guard a.points.count > 1 else { break }
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: lineWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            stroke(a.points, in: ctx, height: height)
            ctx.restoreGState()

        case .highlight:
            guard a.points.count > 1 else { break }
            // Multiply keeps the text underneath readable, like a real marker.
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: 0.45))
            ctx.setLineWidth(lineWidth * 5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            stroke(a.points, in: ctx, height: height)
            ctx.restoreGState()

        case .text:
            guard !a.text.isEmpty else { break }
            let size = fontSize(weight: a.weight, minSide: minSide)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: 1),
            ]
            let string = NSAttributedString(string: a.text, attributes: attributes)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size * 0.05),
                blur: size * 0.14,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
            )
            let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            string.draw(at: NSPoint(x: start.x, y: start.y - size))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()

        case .step:
            let radius = badgeRadius(weight: a.weight, minSide: minSide)
            let circle = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: radius * 0.25)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()

            let label = "\(a.stepNumber)"
            let size = radius * 1.15
            // Dark badges need light numerals and vice versa.
            let luma = 0.299 * a.color.r + 0.587 * a.color.g + 0.114 * a.color.b
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: luma > 0.6 ? NSColor.black : NSColor.white,
            ]
            let string = NSAttributedString(string: label, attributes: attributes)
            let textSize = string.size()
            let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            string.draw(at: NSPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()

        case .blur, .pixelate:
            // Stored coords are already top-down, which is what cropping expects.
            let topDownRect = normalizedRect(a.start, a.end).integral
                .intersection(CGRect(x: 0, y: 0, width: CGFloat(base.width), height: height))
            guard topDownRect.width > 6, topDownRect.height > 6,
                  let patch = base.cropping(to: topDownRect)
            else { break }
            let ci = CIImage(cgImage: patch)
            let filtered: CIImage
            if a.tool == .pixelate {
                let scale = max(10, min(topDownRect.width, topDownRect.height) / 8) * a.weight
                filtered = ci.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputCenterKey: CIVector(x: ci.extent.midX, y: ci.extent.midY),
                ]).cropped(to: ci.extent)
            } else {
                // Clamp first, or the blur pulls transparency in at the edges.
                let radius = max(8, min(topDownRect.width, topDownRect.height) / 10) * a.weight
                filtered = ci.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: ci.extent)
            }
            guard let output = CIContext().createCGImage(filtered, from: filtered.extent) else { break }
            ctx.draw(output, in: CGRect(
                x: topDownRect.minX,
                y: height - topDownRect.maxY,
                width: topDownRect.width,
                height: topDownRect.height
            ))

        case .redact:
            let rect = normalizedRect(start, end)
            guard rect.width > 2, rect.height > 2 else { break }
            ctx.setFillColor(color)
            ctx.fill(rect)

        case .erase:
            let rect = normalizedRect(start, end)
            guard rect.width > 2, rect.height > 2 else { break }
            let topDownRect = normalizedRect(a.start, a.end).integral
            guard let fill = surroundingColor(of: base, around: topDownRect) else {
                // Nothing to sample from — leave the pixels alone rather than
                // painting a guessed colour over them.
                break
            }
            ctx.setFillColor(fill)
            ctx.fill(rect)

        case .measure:
            let distance = hypot(a.end.x - a.start.x, a.end.y - a.start.y)
            guard distance > 4 else { break }
            ctx.saveGState()
            dropShadow(in: ctx, lineWidth: lineWidth)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.butt)
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()

            // End ticks, square to the line, so it reads as a dimension.
            let angle = atan2(end.y - start.y, end.x - start.x)
            let tick = lineWidth * 3
            for point in [start, end] {
                ctx.move(to: CGPoint(
                    x: point.x - cos(angle + .pi / 2) * tick,
                    y: point.y - sin(angle + .pi / 2) * tick
                ))
                ctx.addLine(to: CGPoint(
                    x: point.x + cos(angle + .pi / 2) * tick,
                    y: point.y + sin(angle + .pi / 2) * tick
                ))
            }
            ctx.strokePath()
            ctx.restoreGState()

            // Measurements are in capture pixels — the number people want when
            // they are checking a layout.
            let label = "\(Int(distance.rounded())) px"
            let size = fontSize(weight: a.weight, minSide: minSide) * 0.6
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: label, attributes: attributes)
            let textSize = string.size()
            let padding = size * 0.35
            let plate = CGRect(
                x: (start.x + end.x) / 2 - textSize.width / 2 - padding,
                y: (start.y + end.y) / 2 - textSize.height / 2 - padding * 0.6,
                width: textSize.width + padding * 2,
                height: textSize.height + padding * 1.2
            )
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plate.height / 2, cornerHeight: plate.height / 2, transform: nil))
            ctx.fillPath()

            let measureContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = measureContext
            string.draw(at: NSPoint(x: plate.minX + padding, y: plate.minY + padding * 0.6))
            NSGraphicsContext.restoreGraphicsState()

        case .hideText:
            // Only ever drawn mid-drag: on release it becomes one pixelation
            // per line of text found, and this annotation is discarded.
            let rect = normalizedRect(start, end)
            ctx.saveGState()
            ctx.setFillColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: 0.18))
            ctx.fill(rect)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth * 0.6)
            ctx.setLineDash(phase: 0, lengths: [lineWidth * 2, lineWidth * 2])
            ctx.stroke(rect)
            ctx.restoreGState()

        case .image:
            guard let overlay = a.image else { break }
            let rect = scaled(normalizedRect(start, end), by: a.weight)
            guard rect.width > 2, rect.height > 2 else { break }
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -rect.height * 0.02),
                blur: rect.height * 0.05,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            )
            ctx.interpolationQuality = .high
            ctx.draw(overlay, in: rect)
            ctx.restoreGState()

        case .spotlight:
            let rect = normalizedRect(start, end)
            guard rect.width > 8, rect.height > 8 else { break }
            ctx.saveGState()
            ctx.beginPath()
            ctx.addRect(CGRect(x: 0, y: 0, width: CGFloat(base.width), height: height))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineWidth, cornerHeight: lineWidth, transform: nil))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
    }

    private static func stroke(_ points: [CGPoint], in ctx: CGContext, height: CGFloat) {
        guard let first = points.first else { return }
        ctx.move(to: CGPoint(x: first.x, y: height - first.y))
        for point in points.dropFirst() {
            ctx.addLine(to: CGPoint(x: point.x, y: height - point.y))
        }
        ctx.strokePath()
    }

    private static func dropShadow(in ctx: CGContext, lineWidth: CGFloat) {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -lineWidth * 0.4),
            blur: lineWidth,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        )
    }

    /// Median colour of a thin ring just outside `rect`, in top-down image
    /// coordinates. On the flat backgrounds UI screenshots are mostly made of,
    /// filling with it reads as "nothing was ever here"; over busy photography
    /// it is only ever a solid patch, which is the honest limit of doing this
    /// without a real inpainting model.
    ///
    /// Median, not mean, so one high-contrast neighbour (a border, a caret)
    /// can't drag the fill away from the background it is meant to match.
    private static func surroundingColor(of base: CGImage, around rect: CGRect) -> CGColor? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let ring = max(2, min(rect.width, rect.height) * 0.08)
        let outer = rect.insetBy(dx: -ring, dy: -ring).integral.intersection(bounds)
        guard outer.width > 2, outer.height > 2,
              let patch = base.cropping(to: outer),
              let pixels = PixelMap(patch, width: patch.width, height: patch.height)
        else { return nil }

        let inner = rect.offsetBy(dx: -outer.minX, dy: -outer.minY)
        var reds: [CGFloat] = []
        var greens: [CGFloat] = []
        var blues: [CGFloat] = []
        // Sample at most ~40 rows and columns; a thousand samples is plenty for
        // a median and keeps a live slider drag responsive.
        let stepX = max(1, pixels.width / 40)
        let stepY = max(1, pixels.height / 40)
        for y in stride(from: 0, to: pixels.height, by: stepY) {
            for x in stride(from: 0, to: pixels.width, by: stepX) {
                guard !inner.contains(CGPoint(x: x, y: y)), pixels.alpha(x, y) > 200 else { continue }
                let color = pixels.color(x, y)
                reds.append(color.r)
                greens.append(color.g)
                blues.append(color.b)
            }
        }
        guard reds.count > 3 else { return nil }
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        // Device RGB explicitly: the samples were read in that space, and going
        // out through a generic-RGB CGColor shifts each channel by ~0.02, which
        // is just enough to leave a visible seam around the patch.
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [median(reds), median(greens), median(blues), 1]
        )
    }

    /// Grown or shrunk about its own centre.
    static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        guard factor != 1 else { return rect }
        let width = rect.width * factor
        let height = rect.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
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

extension AnnotationTool {
    /// Tools that hide what is underneath, so they have to be composited before
    /// any markup that should stay legible on top of them.
    var obscures: Bool {
        switch self {
        case .blur, .pixelate, .redact, .erase, .spotlight: return true
        default: return false
        }
    }
}
