import AppKit

enum Clipboard {
    static func copy(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Image on the clipboard, for pasting one capture on top of another.
    static func image() -> CGImage? {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
