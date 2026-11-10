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
                applyFilter(settings.filter)
            }
            schedulePreview()
        }
    }
    @Published var preview: NSImage?
    @Published var justCopied = false
    @Published var lastSaveMessage: String?

    // Annotations
    @Published var tool: AnnotationTool = .move
    @Published var annotations: [Annotation] = [] {
        didSet { schedulePreview() }
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
    private(set) var backgroundImage: CGImage?

    // Live preview works on a reduced copy; full size is only touched on export.
    private static let previewPixels: CGFloat = 2000
    private let previewScale: CGFloat
    private var previewBase: CGImage
    private var previewBackground: CGImage?
    private var previewBusy = false
    private var previewDirty = false
    private var filterTask: Task<Void, Never>?

    init(source: CGImage) {
        self.source = source
        self.filteredSource = source
        self.autoColors = ColorAnalysis.autoGradient(for: source)
        let longest = CGFloat(max(source.width, source.height))
        previewScale = min(1, Self.previewPixels / max(longest, 1))
        previewBase = Self.reduced(source, by: previewScale)
        schedulePreview()
        loadWallpapers()
    }

    private nonisolated static func reduced(_ image: CGImage, by factor: CGFloat) -> CGImage {
        guard factor < 0.999 else { return image }
        return ImageEncoding.downscale(image, factor: factor) ?? image
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

    /// Coalesced background preview render: at most one in flight; if more
    /// changes arrive meanwhile, exactly one more render runs with the latest
    /// state. Keeps drags, sliders and typing smooth on 5K/6K captures.
    private func schedulePreview() {
        previewDirty = true
        if !previewBusy { startPreview() }
    }

    private func startPreview() {
        previewDirty = false
        previewBusy = true
        var all = annotations
        if let draft { all.append(draft) }
        let scale = previewScale
        let markup = all.map { $0.scaled(by: scale) }
        let base = previewBase
        let settings = settings
        let autoColors = autoColors
        let background = previewBackground ?? backgroundImage
        let logical = CGSize(width: source.width, height: source.height)
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                BeautifyRenderer.render(
                    image: AnnotationRenderer.compose(base, annotations: markup),
                    settings: settings,
                    autoColors: autoColors,
                    backgroundImage: background,
                    maxDimension: 1800,
                    logicalSize: logical
                )
            }.value
            guard let self else { return }
            if let rendered {
                self.preview = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            }
            self.previewBusy = false
            if self.previewDirty { self.startPreview() }
        }
    }

    private func applyFilter(_ filter: ImageFilter) {
        filterTask?.cancel()
        let source = source
        let scale = previewScale
        filterTask = Task { @MainActor [weak self] in
            let (full, small) = await Task.detached(priority: .userInitiated) {
                let filtered = ImageFilters.apply(filter, to: source)
                return (filtered, EditorModel.reduced(filtered, by: scale))
            }.value
            guard let self, !Task.isCancelled, self.settings.filter == filter else { return }
            self.filteredSource = full
            self.previewBase = small
            self.schedulePreview()
        }
    }

    private func setBackgroundImage(_ image: CGImage) {
        backgroundImage = image
        previewBackground = nil
        settings.background = .image
        Task { @MainActor [weak self] in
            let small = await Task.detached(priority: .userInitiated) {
                EditorModel.reduced(image, by: min(1, 2400 / CGFloat(max(image.width, image.height, 1))))
            }.value
            guard let self, self.backgroundImage === image else { return }
            self.previewBackground = small
            self.schedulePreview()
        }
    }

    /// Full-size render (markup + beautify) off the main thread.
    func renderFullAsync() async -> CGImage? {
        let base = filteredSource
        let markup = annotations
        let settings = settings
        let autoColors = autoColors
        let background = backgroundImage
        return await Task.detached(priority: .userInitiated) {
            BeautifyRenderer.render(
                image: AnnotationRenderer.compose(base, annotations: markup),
                settings: settings,
                autoColors: autoColors,
                backgroundImage: background
            )
        }.value
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
            schedulePreview()
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
                    schedulePreview()
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
            self.setBackgroundImage(image)
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
                // Downsampled + EXIF-rotated, decoded off the main thread.
                let image = await Task.detached(priority: .userInitiated) {
                    WallpaperLibrary.fullImage(for: url)
                }.value
                guard let self, let image else { return }
                self.selectedWallpaper = nil
                self.setBackgroundImage(image)
            }
        }
    }

    // MARK: Export & share

    func copyToClipboard() {
        Task { @MainActor in
            guard let full = await renderFullAsync() else { return }
            await Clipboard.copyAsync(full)
            markCopied()
        }
    }

    private func markCopied() {
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.justCopied = false
        }
    }

    func saveToDesktop() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desktop.appendingPathComponent(defaultFilename())
        let format = settings.exportFormat
        Task { @MainActor in
            guard let full = await renderFullAsync() else { return }
            let ok = await Task.detached(priority: .userInitiated) {
                ImageWriter.write(full, to: url.path, format: format)
            }.value
            if ok { flashSaveMessage("Saved to Desktop") }
        }
    }

    func saveAs() {
        let format = settings.exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = defaultFilename()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, let full = await self.renderFullAsync() else { return }
                let ok = await Task.detached(priority: .userInitiated) {
                    ImageWriter.write(full, to: url.path, format: format)
                }.value
                if ok { self.flashSaveMessage("Saved") }
            }
        }
    }

    func uploadToDrive() {
        guard DriveService.shared.isConnected else {
            flashSaveMessage("Connect Google Drive in Settings → Accounts")
            SettingsWindowController.shared.show()
            return
        }
        flashSaveMessage("Uploading to Drive…")
        let filename = defaultFilename()
        Task { @MainActor in
            guard let full = await renderFullAsync() else { return }
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
