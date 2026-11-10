import AppKit
import SwiftUI

/// The Snipost mark: two capture-corner brackets with an arrow breaking out
/// through the open corner — snip, then post. Keep in sync with
/// Scripts/make-icon.swift.
enum BrandMark {
    /// Stroke-only path in a unit square (y up), scaled into `rect`.
    static func glyphPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        // Top-left bracket.
        path.move(to: p(0.10, 0.60)); path.addLine(to: p(0.10, 0.90)); path.addLine(to: p(0.40, 0.90))
        // Bottom-right bracket.
        path.move(to: p(0.60, 0.10)); path.addLine(to: p(0.90, 0.10)); path.addLine(to: p(0.90, 0.40))
        // Arrow shaft + head, out through the open top-right corner.
        path.move(to: p(0.32, 0.32)); path.addLine(to: p(0.84, 0.84))
        path.move(to: p(0.56, 0.84)); path.addLine(to: p(0.84, 0.84)); path.addLine(to: p(0.84, 0.56))
        return path
    }

    /// Menu bar template image (auto-tinted for light/dark/highlight).
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(glyphPath(in: rect.insetBy(dx: 1.5, dy: 1.5)))
            ctx.setLineWidth(1.7)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snipost"
        return image
    }

    static let gradient = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.48, blue: 0.27),
            Color(red: 0.95, green: 0.22, blue: 0.48),
            Color(red: 0.48, green: 0.30, blue: 1.00),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// The app-icon tile drawn live in SwiftUI (popover header, settings).
struct BrandTile: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .overlay(
                GlyphShape()
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.96), location: 0),
                                .init(color: Color(white: 0.82), location: 0.5),
                                .init(color: Color(white: 0.6), location: 0.5),
                                .init(color: Color(white: 0.46), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round)
                    )
                    .padding(size * 0.25)
            )
            .frame(width: size, height: size)
    }
}

private struct GlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        // SwiftUI is y-down: flip the unit-square path.
        var transform = CGAffineTransform(translationX: 0, y: rect.maxY + rect.minY).scaledBy(x: 1, y: -1)
        let cg = BrandMark.glyphPath(in: rect)
        return Path(cg.copy(using: &transform) ?? cg)
    }
}
