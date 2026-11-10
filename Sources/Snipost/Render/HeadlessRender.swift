import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// CLI entry points so the render pipeline can be exercised (and eyeballed)
/// without any UI — used for development and CI.
enum HeadlessRender {
    static func beautify(inputPath: String, outputPath: String) {
        let url = URL(fileURLWithPath: inputPath)
        guard let image = CaptureService.loadCGImage(at: url) else {
            fputs("snipost: could not read image at \(inputPath)\n", stderr)
            exit(1)
        }
        renderAndWrite(image: image, outputPath: outputPath)
    }

    static func selftest(outputPath: String) {
        guard let fake = makeFakeWindowScreenshot(width: 900, height: 600) else {
            fputs("snipost: failed to draw synthetic screenshot\n", stderr)
            exit(1)
        }
        // Keep the raw input next to the output for comparison.
        let rawPath = (outputPath as NSString).deletingPathExtension + "-raw.png"
        _ = ImageWriter.write(fake, to: rawPath)

        // Showcase settings: exercise the cursor overlay too.
        var settings = BeautifySettings()
        settings.cursor = .arrow
        settings.cursorPosition = CGPoint(x: 0.66, y: 0.52)
        settings.cursorSize = 110
        renderAndWrite(image: fake, outputPath: outputPath, settings: settings)
    }

    /// Renders known text into an image and OCRs it back — verifies the
    /// Vision pipeline without any UI.
    static func ocrTest() {
        let expected = "Snipost turns screenshots into posts 12345"
        guard let image = makeTextImage(text: expected, width: 1100, height: 160) else {
            fputs("snipost: failed to draw text image\n", stderr)
            exit(1)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        let recognized = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        print("recognized: \(recognized)")
        print(recognized.contains("Snipost") && recognized.contains("12345") ? "OCR TEST PASSED" : "OCR TEST FAILED")
    }

    private static func makeTextImage(text: String, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        string.draw(at: NSPoint(x: 30, y: 55))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Simulates a scrolling capture: slice a tall synthetic page into
    /// overlapping viewport frames, then stitch them back together.
    static func stitchTest(outputPath: String) {
        let width = 700
        let tallHeight = 2400
        let viewportHeight = 600
        let step = 340

        guard let tall = makeTallContent(width: width, height: tallHeight) else {
            fputs("snipost: failed to draw tall content\n", stderr)
            exit(1)
        }

        // Viewport frames with a sticky 60px header and 50px footer drawn
        // over the scrolling content — the case that used to repeat bars.
        let header = 60, footer = 50
        var frames: [CGImage] = []
        var offset = 0
        while offset + viewportHeight <= tallHeight {
            if let frame = tall.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewportHeight)),
               let framed = overlayBars(frame, header: header, footer: footer) {
                frames.append(framed)
            }
            offset += step
        }

        var session = Stitcher.Session()
        var allCorrect = true
        for (index, frame) in frames.enumerated() {
            let result = session.add(frame)
            switch result {
            case .first: print("frame 0: first")
            case .added(let rows):
                print("frame \(index): +\(rows) rows (expected \(step))")
                if rows != step { allCorrect = false }
            case .unchanged: print("frame \(index): unchanged"); allCorrect = false
            case .lost: print("frame \(index): LOST"); allCorrect = false
            }
        }
        guard let stitched = session.render() else {
            fputs("snipost: stack failed\n", stderr)
            exit(1)
        }
        let expectedHeight = viewportHeight + (frames.count - 1) * step
        print("stitched \(stitched.width)x\(stitched.height), expected \(width)x\(expectedHeight)")
        _ = ImageWriter.write(stitched, to: outputPath)
        print(allCorrect && stitched.height == expectedHeight ? "STITCH TEST PASSED" : "STITCH TEST FAILED")
    }

    private static func overlayBars(_ frame: CGImage, header: Int, footer: Int) -> CGImage? {
        let w = frame.width, h = frame.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - header, width: w, height: header)) // top (y-up)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: footer))
        // Some texture so the bars aren't "flat" rows.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 40, y: h - header + 20, width: 200, height: 18))
        ctx.fill(CGRect(x: 60, y: 16, width: 160, height: 16))
        return ctx.makeImage()
    }

    private static func makeTallContent(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Deterministic pseudo-random content rows so every row is distinctive.
        var y: CGFloat = 20
        var index = 0
        while y < h - 40 {
            if y > 900 && y < 1250 { y += 34; index += 1; continue } // blank gap
            let hue = CGFloat((index * 37) % 100) / 100
            let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1)
            let indent = CGFloat((index * 53) % 180)
            let rowWidth = w * (0.35 + CGFloat((index * 29) % 50) / 100)
            let rect = CGRect(x: 24 + indent, y: y, width: min(rowWidth, w - 48 - indent), height: 18)
            let path = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            y += 34
            index += 1
        }
        return ctx.makeImage()
    }

    private static func renderAndWrite(
        image: CGImage,
        outputPath: String,
        settings: BeautifySettings = BeautifySettings()
    ) {
        let autoColors = ColorAnalysis.autoGradient(for: image)
        guard let output = BeautifyRenderer.render(image: image, settings: settings, autoColors: autoColors),
              ImageWriter.write(output, to: outputPath)
        else {
            fputs("snipost: render failed\n", stderr)
            exit(1)
        }
        print("wrote \(outputPath) (\(output.width)x\(output.height))")
    }

    /// Draws a plausible dark-themed app window so the auto-gradient and
    /// compositor have something realistic to chew on.
    private static func makeFakeWindowScreenshot(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)

        // Window body: dark editor purple
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Title bar (top of image = high y in CG coordinates)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.23, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 44, width: w, height: 44))

        // Traffic lights
        let lights: [CGColor] = [
            CGColor(red: 1.00, green: 0.38, blue: 0.35, alpha: 1),
            CGColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        ]
        for (i, light) in lights.enumerated() {
            ctx.setFillColor(light)
            ctx.fillEllipse(in: CGRect(x: 16 + CGFloat(i) * 22, y: h - 28, width: 13, height: 13))
        }

        // Fake code lines
        let lineColors: [CGColor] = [
            CGColor(red: 0.55, green: 0.65, blue: 0.98, alpha: 1),
            CGColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1),
            CGColor(red: 0.55, green: 0.85, blue: 0.70, alpha: 1),
            CGColor(red: 0.80, green: 0.75, blue: 0.50, alpha: 1),
        ]
        var y = h - 84
        var i = 0
        while y > 32 {
            let indent: CGFloat = [0, 24, 48, 24][i % 4]
            let lineWidth = w * [0.42, 0.61, 0.33, 0.52][i % 4] - indent
            let rect = CGRect(x: 32 + indent, y: y, width: lineWidth, height: 12)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(lineColors[i % lineColors.count])
            ctx.addPath(path)
            ctx.fillPath()
            y -= 28
            i += 1
        }

        return ctx.makeImage()
    }
}
