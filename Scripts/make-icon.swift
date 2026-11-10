// Generates Resources/AppIcon.icns: a monochrome charcoal squircle with the
// two-tone grey Snipost mark (capture brackets + outbound arrow). Run: swift Scripts/make-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

func drawIcon(canvas: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: canvas, height: canvas,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(canvas) / 1024.0
    let full = CGFloat(canvas)

    // Squircle plate with the standard macOS icon margin.
    let margin = 100 * s
    let plate = CGRect(x: margin, y: margin, width: full - margin * 2, height: full - margin * 2)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Charcoal plate: soft top-to-bottom falloff.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
    ] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY), options: [])
    }
    ctx.restoreGState()

    // Hairline rim highlight.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 3 * s, dy: 3 * s),
                       cornerWidth: 182 * s, cornerHeight: 182 * s, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(max(0.5, 5 * s))
    ctx.strokePath()
    ctx.restoreGState()

    // Glyph (same geometry as BrandMark.glyphPath), outlined so it can be
    // filled two-tone: light upper half, darker lower half, split by a gap.
    let glyphRect = CGRect(x: 250 * s, y: 250 * s, width: 524 * s, height: 524 * s)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: glyphRect.minX + x * glyphRect.width, y: glyphRect.minY + y * glyphRect.height)
    }
    let line = CGMutablePath()
    line.move(to: p(0.10, 0.60)); line.addLine(to: p(0.10, 0.90)); line.addLine(to: p(0.40, 0.90))
    line.move(to: p(0.60, 0.10)); line.addLine(to: p(0.90, 0.10)); line.addLine(to: p(0.90, 0.40))
    line.move(to: p(0.32, 0.32)); line.addLine(to: p(0.84, 0.84))
    line.move(to: p(0.56, 0.84)); line.addLine(to: p(0.84, 0.84)); line.addLine(to: p(0.84, 0.56))
    let glyph = line.copy(strokingWithWidth: 70 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)

    let midY = glyphRect.midY
    let gap = 14 * s
    for (band, top, bottom) in [
        (CGRect(x: 0, y: midY + gap / 2, width: full, height: full), 0.96, 0.80),
        (CGRect(x: 0, y: 0, width: full, height: midY - gap / 2), 0.62, 0.46),
    ] {
        ctx.saveGState()
        ctx.addPath(glyph)
        ctx.clip()
        ctx.clip(to: band)
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(gray: top, alpha: 1), CGColor(gray: bottom, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: glyphRect.maxY),
                                   end: CGPoint(x: 0, y: glyphRect.minY), options: [])
        }
        ctx.restoreGState()
    }

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let root = scriptDir.deletingLastPathComponent()
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in variants {
    guard let image = drawIcon(canvas: size) else { fatalError("draw failed at \(size)") }
    writePNG(image, to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
