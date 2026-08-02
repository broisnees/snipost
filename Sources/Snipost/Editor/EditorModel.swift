import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor
final class EditorModel: ObservableObject {
    let source: CGImage
    let autoColors: [RGB]

    @Published var settings = BeautifySettings() {
        didSet {
            if oldValue.filter != settings.filter {
                filteredSource = ImageFilters.apply(settings.filter, to: source)
                rebuildComposition()
            }
            renderPreview()
        }
    }
    @Published var preview: NSImage?
    @Published var justCopied = false
    @Published var lastSaveMessage: String?

    // Annotations
    @Published var tool: AnnotationTool = .move
    @Published var annotations: [Annotation] = [] {
        didSet { rebuildComposition(); renderPreview() }
    }
    @Published var annotationColorIndex = 0
    private var draft: Annotation?

    // Custom background colors
    @Published var customSolid: Color = Color(red: 0.35, green: 0.45, blue: 0.85)
    @Published var customGradientStart: Color = Color(red: 0.20, green: 0.35, blue: 0.90)
    @Published var customGradientEnd: Color = Color(red: 0.80, green: 0.30, blue: 0.70)

    // System wallpapers
    @Published private(set) var wallpapers: [Wallpaper] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var selectedWallpaper: URL?

    private(set) var filteredSource: CGImage
    private(set) var composedSource: CGImage
    private(set) var backgroundImage: CGImage?

    init(source: CGImage) {
        self.source = source
        self.filteredSource = source
        self.composedSource = source
        self.autoColors = ColorAnalysis.autoGradient(for: source)
        // A window capture arrives with its own rounded corners; start the
        // slider there so it reflects the radius actually on screen.
        self.settings.cornerRadius = max(
            settings.cornerRadius,
            BeautifyRenderer.sourceCornerRadius(of: source).rounded()
        )
        renderPreview()
        loadWallpapers()
    }

    var outputSizeText: String {
        guard let full = renderedSize() else { return "" }
        return "\(Int(full.width)) × \(Int(full.height)) px"
    }

    private func renderedSize() -> CGSize? {
        let w = CGFloat(source.width)
        let h = CGFloat(source.height)
        let padding = settings.paddingFraction * max(w, h)
        var cw = w + padding * 2
        var ch = h + padding * 2
        if let ratio = settings.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        return CGSize(width: cw.rounded(), height: ch.rounded())
    }

    private func rebuildComposition() {
        var all = annotations
        if let draft { all.append(draft) }
        composedSource = AnnotationRenderer.compose(filteredSource, annotations: all)
    }

    private func renderPreview() {
        guard let rendered = BeautifyRenderer.render(
            image: composedSource,
            settings: settings,
            autoColors: autoColors,
            backgroundImage: backgroundImage,
            maxDimension: 1400
        ) else { return }
        preview = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }

    func renderFull() -> CGImage? {
        BeautifyRenderer.render(
            image: composedSource,
            settings: settings,
            autoColors: autoColors,
            backgroundImage: backgroundImage
        )
    }

    // MARK: Preview interaction (cursor placement or annotation drawing)

    func dragChanged(atNormalized point: CGPoint) {
        switch tool {
        case .move:
            placeCursor(atNormalized: point)
        case .arrow, .box, .blur:
            let imagePoint = imagePoint(fromCanvasNormalized: point)
            if draft == nil {
                draft = Annotation(tool: tool, start: imagePoint, end: imagePoint, color: currentColor)
            } else {
                draft?.end = imagePoint
            }
            rebuildComposition()
            renderPreview()
        case .text:
            break // placed on release
        }
    }

    func dragEnded(atNormalized point: CGPoint) {
        switch tool {
        case .move:
            break
        case .arrow, .box, .blur:
            if var finished = draft {
                finished.end = imagePoint(fromCanvasNormalized: point)
                draft = nil
                let span = hypot(finished.end.x - finished.start.x, finished.end.y - finished.start.y)
                if span > 6 {
                    annotations.append(finished)
                } else {
                    rebuildComposition()
                    renderPreview()
                }
            }
        case .text:
            let imagePoint = imagePoint(fromCanvasNormalized: point)
            annotations.append(Annotation(
                tool: .text,
                start: imagePoint,
                end: imagePoint,
                text: "Text",
                color: currentColor
            ))
        }
    }

    var currentColor: RGB {
        Annotation.palette[min(annotationColorIndex, Annotation.palette.count - 1)]
    }

    func undoAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func clearAnnotations() {
        annotations.removeAll()
    }

    /// Binding to the most recent text annotation, for inline editing.
    var lastTextBinding: Binding<String>? {
        guard let index = annotations.lastIndex(where: { $0.tool == .text }) else { return nil }
        return Binding(
            get: { [weak self] in self?.annotations[index].text ?? "" },
            set: { [weak self] newValue in
                guard let self, self.annotations.indices.contains(index) else { return }
                self.annotations[index].text = newValue
            }
        )
    }

    /// Maps a normalized canvas point (y from top) into source-image pixels,
    /// mirroring the renderer's layout math.
    private func imagePoint(fromCanvasNormalized p: CGPoint) -> CGPoint {
        let iw = CGFloat(source.width)
        let ih = CGFloat(source.height)
        let padding = settings.paddingFraction * max(iw, ih)
        var cw = iw + padding * 2
        var ch = ih + padding * 2
        if let ratio = settings.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        let originX = (cw - iw) / 2
        let originY = (ch - ih) / 2
        return CGPoint(
            x: min(max(p.x * cw - originX, 0), iw),
            y: min(max(p.y * ch - originY, 0), ih)
        )
    }

    /// Called with a click/drag location normalized over the preview (y from the top).
    func placeCursor(atNormalized point: CGPoint) {
        var updated = settings
        if updated.cursor == .none { updated.cursor = .arrow }
        updated.cursorPosition = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        settings = updated
    }

    // MARK: Custom background colors

    func applyCustomSolid() {
        settings.background = .solid(Self.rgb(from: customSolid))
    }

    func applyCustomGradient() {
        settings.background = .customGradient(
            Self.rgb(from: customGradientStart),
            Self.rgb(from: customGradientEnd)
        )
    }

    private static func rgb(from color: Color) -> RGB {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return RGB(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
    }

    // MARK: Backgrounds from images

    private func loadWallpapers() {
        Task { @MainActor in
            let found = WallpaperLibrary.systemWallpapers()
            self.wallpapers = found
            for wallpaper in found {
                let url = wallpaper.url
                let cg = await Task.detached(priority: .utility) {
                    WallpaperLibrary.thumbnail(for: url)
                }.value
                if let cg {
                    self.thumbnails[url] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
    }

    func selectWallpaper(_ wallpaper: Wallpaper) {
        selectedWallpaper = wallpaper.url
        Task { @MainActor in
            let url = wallpaper.url
            let image = await Task.detached(priority: .userInitiated) {
                WallpaperLibrary.fullImage(for: url)
            }.value
            guard let image, self.selectedWallpaper == url else { return }
            self.backgroundImage = image
            self.settings.background = .image
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, let image = CaptureService.loadCGImage(at: url) else { return }
                self.selectedWallpaper = nil
                self.backgroundImage = image
                self.settings.background = .image
            }
        }
    }

    // MARK: Export & share

    func copyToClipboard() {
        guard let full = renderFull() else { return }
        Clipboard.copy(full)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.justCopied = false
        }
    }

    func saveToDesktop() {
        guard let full = renderFull() else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desktop.appendingPathComponent(defaultFilename())
        if ImageWriter.write(full, to: url.path, format: settings.exportFormat) {
            flashSaveMessage("Saved to Desktop")
        }
    }

    func saveAs() {
        guard let full = renderFull() else { return }
        let format = settings.exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = defaultFilename()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if ImageWriter.write(full, to: url.path, format: format) {
                Task { @MainActor in self?.flashSaveMessage("Saved") }
            }
        }
    }

    func uploadToDrive() {
        guard DriveService.shared.isConnected else {
            flashSaveMessage("Connect Google Drive in Settings → Accounts")
            SettingsWindowController.shared.show()
            return
        }
        guard let full = renderFull() else { return }
        flashSaveMessage("Uploading to Drive…")
        let filename = defaultFilename()
        Task { @MainActor in
            do {
                let link = try await DriveService.shared.uploadAndLink(full, filename: filename)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                flashSaveMessage("Drive link copied")
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Uploaded to Google Drive", body: "Share link copied — \(filename)")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "Drive upload failed"
                flashSaveMessage(reason)
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Drive upload failed", body: reason)
                }
            }
        }
    }

    /// OCR via Vision: recognized text from the original capture → clipboard.
    func copyRecognizedText() {
        let image = source
        flashSaveMessage("Recognizing text…")
        Task { @MainActor in
            let text = await TextRecognizer.recognize(in: image)
            if text.isEmpty {
                flashSaveMessage("No text found")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flashSaveMessage("Text copied (\(text.count) chars)")
            }
        }
    }

    func flashSaveMessage(_ message: String) {
        lastSaveMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.lastSaveMessage == message {
                self?.lastSaveMessage = nil
            }
        }
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Snipost \(formatter.string(from: Date())).\(settings.exportFormat.fileExtension)"
    }
}
