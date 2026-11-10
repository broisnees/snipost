import AppKit

/// One pasteboard item carrying full-resolution PNG (Retina DPI-tagged) and a
/// real .png file: pastes as an image in chat/docs apps and as a file in
/// Finder or upload fields.
enum Clipboard {
    @MainActor
    static func copy(_ image: CGImage) {
        _ = ImageWriter.retinaScale // resolve on main before any background use
        let png = ImageWriter.pngData(image)
        write(png: png, fileURL: FileActions.stage(image, pngData: png))
    }

    /// Same as `copy`, with the PNG encode and file write off the main thread.
    @MainActor
    static func copyAsync(_ image: CGImage) async {
        _ = ImageWriter.retinaScale
        let (png, url) = await Task.detached(priority: .userInitiated) { () -> (Data?, URL?) in
            let png = ImageWriter.pngData(image)
            return (png, png.flatMap(FileActions.writeStaged))
        }.value
        write(png: png, fileURL: url)
    }

    @MainActor
    private static func write(png: Data?, fileURL: URL?) {
        let item = NSPasteboardItem()
        if let png { item.setData(png, forType: .png) }
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}
