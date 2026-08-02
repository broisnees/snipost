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
    @Published var tool: AnnotationTool = .move {
        didSet { if tool != .move { selection = nil } }
    }
    @Published var annotations: [Annotation] = [] {
        didSet { rebuildComposition(); renderPreview() }
    }
    @Published var annotationColorIndex = 0
    @Published var annotationWeight: CGFloat = 1
    /// The markup the Select tool has picked up, if any.
    @Published var selection: UUID?
    @Published private var undoStack: [[Annotation]] = []
    @Published private var redoStack: [[Annotation]] = []
    private var draft: Annotation?
    /// Where a move drag started, and the annotation as it was at that moment —
    /// translating from the original each time keeps the drag from drifting.
    private var dragOrigin: CGPoint?
    private var movingBase: Annotation?

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
        let imagePoint = self.imagePoint(fromCanvasNormalized: point)
        switch tool.input {
        case .none:
            moveOrSelect(at: imagePoint, normalized: point)

        case .segment, .region:
            if draft == nil {
                draft = Annotation(
                    tool: tool, start: imagePoint, end: imagePoint,
                    color: currentColor, weight: annotationWeight
                )
            } else {
                draft?.end = imagePoint
            }
            rebuildComposition()
            renderPreview()

        case .stroke:
            if draft == nil {
                draft = Annotation(
                    tool: tool, start: imagePoint, end: imagePoint, points: [imagePoint],
                    color: currentColor, weight: annotationWeight
                )
            } else if let last = draft?.points.last,
                      hypot(imagePoint.x - last.x, imagePoint.y - last.y) > strokeSampleSpacing {
                // Thinning the samples keeps a long stroke from recompositing
                // the whole image on every pointer move.
                draft?.points.append(imagePoint)
                draft?.end = imagePoint
            } else {
                return
            }
            rebuildComposition()
            renderPreview()

        case .point:
            break // placed on release
        }
    }

    func dragEnded(atNormalized point: CGPoint) {
        let imagePoint = self.imagePoint(fromCanvasNormalized: point)
        switch tool.input {
        case .none:
            dragOrigin = nil
            movingBase = nil

        case .segment, .region:
            guard var finished = draft else { break }
            draft = nil
            finished.end = imagePoint
            let span = hypot(finished.end.x - finished.start.x, finished.end.y - finished.start.y)
            if span > 6 {
                commit(finished)
            } else {
                rebuildComposition()
                renderPreview()
            }

        case .stroke:
            guard var finished = draft else { break }
            draft = nil
            finished.points.append(imagePoint)
            finished.end = imagePoint
            if finished.points.count > 2 {
                commit(finished)
            } else {
                rebuildComposition()
                renderPreview()
            }

        case .point:
            let placed = Annotation(
                tool: tool,
                start: imagePoint,
                end: imagePoint,
                text: tool == .text ? "Text" : "",
                color: currentColor,
                weight: annotationWeight,
                stepNumber: nextStepNumber
            )
            commit(placed)
        }
    }

    /// How far the pointer must travel, in source pixels, before a freehand
    /// stroke records another point.
    private var strokeSampleSpacing: CGFloat {
        max(2, CGFloat(min(source.width, source.height)) * 0.003)
    }

    private var nextStepNumber: Int {
        (annotations.filter { $0.tool == .step }.map(\.stepNumber).max() ?? 0) + 1
    }

    private func commit(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selection = annotation.id
    }

    // MARK: Selecting and moving markup

    private func moveOrSelect(at imagePoint: CGPoint, normalized: CGPoint) {
        if let base = movingBase, let origin = dragOrigin {
            let delta = CGSize(width: imagePoint.x - origin.x, height: imagePoint.y - origin.y)
            if let index = annotations.firstIndex(where: { $0.id == base.id }) {
                annotations[index] = base.translated(by: delta)
            }
            return
        }
        if let hit = annotation(at: imagePoint) {
            selection = hit.id
            movingBase = hit
            dragOrigin = imagePoint
            checkpoint()
            return
        }
        selection = nil
        // Nothing under the pointer — fall through to dragging the cursor
        // overlay, which is the other thing this tool does.
        if settings.cursor != .none {
            placeCursor(atNormalized: normalized)
        }
    }

    /// Topmost markup under a point, with a little slop so thin strokes are
    /// still catchable.
    private func annotation(at point: CGPoint) -> Annotation? {
        let minSide = CGFloat(min(source.width, source.height))
        let slop = minSide * 0.008
        return annotations.reversed().first {
            $0.bounds(minSide: minSide).insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    /// The selected markup's box, normalized over the output canvas with y from
    /// the top, so the view can outline it on the preview.
    var selectionBox: CGRect? {
        guard let selection,
              let annotation = annotations.first(where: { $0.id == selection })
        else { return nil }
        let minSide = CGFloat(min(source.width, source.height))
        return normalizedCanvasRect(fromImage: annotation.bounds(minSide: minSide))
    }

    func deleteSelection() {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        checkpoint()
        annotations.remove(at: index)
        self.selection = nil
    }

    var currentColor: RGB {
        Annotation.palette[min(annotationColorIndex, Annotation.palette.count - 1)]
    }

    /// Recolours or reweights the selection instead of only affecting what is
    /// drawn next — otherwise picking a colour with something selected does
    /// nothing visible and reads as broken.
    func restyleSelection() {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        checkpoint()
        annotations[index].color = currentColor
        annotations[index].weight = annotationWeight
    }

    // MARK: Undo

    private func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        pruneSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        pruneSelection()
    }

    private func pruneSelection() {
        if let selection, !annotations.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
        selection = nil
    }

    /// Binding to the selected text markup, or the most recent one.
    var lastTextBinding: Binding<String>? {
        let selected = selection.flatMap { id in
            annotations.firstIndex { $0.id == id && $0.tool == .text }
        }
        guard let index = selected ?? annotations.lastIndex(where: { $0.tool == .text }) else { return nil }
        return Binding(
            get: { [weak self] in self?.annotations[index].text ?? "" },
            set: { [weak self] newValue in
                guard let self, self.annotations.indices.contains(index) else { return }
                self.annotations[index].text = newValue
            }
        )
    }

    /// Where the screenshot sits inside the output canvas, mirroring the
    /// renderer's layout math. Both mappings below are built on it.
    private func layout() -> (canvas: CGSize, origin: CGPoint, image: CGSize) {
        let iw = CGFloat(source.width)
        let ih = CGFloat(source.height)
        let padding = settings.paddingFraction * max(iw, ih)
        var cw = iw + padding * 2
        var ch = ih + padding * 2
        if let ratio = settings.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        return (
            CGSize(width: cw, height: ch),
            CGPoint(x: (cw - iw) / 2, y: (ch - ih) / 2),
            CGSize(width: iw, height: ih)
        )
    }

    /// Maps a normalized canvas point (y from top) into source-image pixels.
    private func imagePoint(fromCanvasNormalized p: CGPoint) -> CGPoint {
        let (canvas, origin, image) = layout()
        return CGPoint(
            x: min(max(p.x * canvas.width - origin.x, 0), image.width),
            y: min(max(p.y * canvas.height - origin.y, 0), image.height)
        )
    }

    /// The inverse, for drawing overlays on the preview.
    private func normalizedCanvasRect(fromImage rect: CGRect) -> CGRect {
        let (canvas, origin, _) = layout()
        return CGRect(
            x: (rect.minX + origin.x) / canvas.width,
            y: (rect.minY + origin.y) / canvas.height,
            width: rect.width / canvas.width,
            height: rect.height / canvas.height
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
