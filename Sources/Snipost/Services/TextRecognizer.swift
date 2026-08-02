import CoreGraphics
import Vision

/// OCR via Apple's Vision framework — ships with macOS, runs on-device, and
/// outperforms Tesseract on screen-rendered text (same engine Shottr/TRex use).
enum TextRecognizer {
    /// Recognized text, top-to-bottom, one line per string. Empty if none.
    static func recognize(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    /// Payloads of any QR or barcode in the image, in the order Vision reports.
    static func codes(in image: CGImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([request])
            return (request.results ?? []).compactMap { $0.payloadStringValue }
        }.value
    }

    /// Where the text is, in image pixels with y from the top — for hiding the
    /// words without touching anything around them.
    ///
    /// Boxes come back padded a little: Vision's are tight to the glyphs, and an
    /// exact box leaves legible fringes along the edges.
    static func textBoxes(in image: CGImage) async -> [CGRect] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            // Speed over transcription quality — the strings are thrown away,
            // only the boxes matter.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([request])

            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            return (request.results ?? []).map { observation in
                // Vision normalizes with the origin at the bottom left.
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
                return rect.insetBy(dx: -rect.height * 0.12, dy: -rect.height * 0.12)
            }
        }.value
    }
}
