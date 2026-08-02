import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor
final class EditorModel: ObservableObject {
    /// The capture being edited. Crop, resize and combine replace it, so it is
    /// part of the undo state rather than a constant.
    @Published private(set) var source: CGImage
    @Published private(set) var autoColors: [RGB]

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
    /// Undo covers the image too, not just markup — cropping and resizing are
    /// as reversible as drawing. CGImages are immutable and cropped ones share
    /// their parent's buffer, so keeping them here is cheap.
    private struct EditState {
        var annotations: [Annotation]
        var source: CGImage
    }
    @Published private var undoStack: [EditState] = []
    @Published private var redoStack: [EditState] = []

    // Crop
    @Published var cropping = false {
        didSet { if !cropping { cropRect = nil } }
    }
    /// Pending crop in source-image pixels, y from the top.
    @Published private(set) var cropRect: CGRect?
    private var cropAnchor: CGPoint?

    // Pixel loupe / colour picker
    @Published var inspecting = false {
        didSet { if !inspecting { loupe = nil } }
    }
    @Published private(set) var loupe: Loupe?
    /// Built on demand — a full pixel copy of the capture is only worth its
    /// memory while someone is actually picking colours.
    private var pixels: PixelMap?

    struct Loupe {
        /// Pointer position, normalized over the output canvas.
        var at: CGPoint
        var patch: CGImage?
        var hex: String
        var color: RGB
        var pixel: CGPoint
    }
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
        // Crop and inspect take over the preview while they are armed.
        if cropping {
            let anchor = cropAnchor ?? point
            cropAnchor = anchor
            cropDragChanged(from: anchor, to: point)
            return
        }
        if inspecting {
            updateLoupe(atNormalized: point)
            return
        }

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
        if cropping {
            cropAnchor = nil
            return
        }
        if inspecting {
            updateLoupe(atNormalized: point)
            copyPickedColor()
            return
        }

        let imagePoint = self.imagePoint(fromCanvasNormalized: point)
        switch tool.input {
        case .none:
            dragOrigin = nil
            movingBase = nil
            grip = nil

        case .segment, .region:
            guard var finished = draft else { break }
            draft = nil
            finished.end = imagePoint
            let span = hypot(finished.end.x - finished.start.x, finished.end.y - finished.start.y)
            guard span > 6 else {
                rebuildComposition()
                renderPreview()
                break
            }
            if finished.tool == .hideText {
                // Drop the region itself and pixelate the words inside it.
                rebuildComposition()
                renderPreview()
                hideText(in: CGRect(
                    x: min(finished.start.x, finished.end.x),
                    y: min(finished.start.y, finished.end.y),
                    width: abs(finished.start.x - finished.end.x),
                    height: abs(finished.start.y - finished.end.y)
                ))
            } else {
                commit(finished)
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
            if let grip {
                applyResize(base: base, grip: grip, to: imagePoint)
                return
            }
            let delta = CGSize(width: imagePoint.x - origin.x, height: imagePoint.y - origin.y)
            if let index = annotations.firstIndex(where: { $0.id == base.id }) {
                annotations[index] = base.translated(by: delta)
            }
            return
        }
        // A grab near a handle of what is already selected resizes it; anywhere
        // else picks up whatever is under the pointer.
        if let selected = selectedAnnotation, let grabbed = grip(near: imagePoint, of: selected) {
            grip = grabbed
            movingBase = selected
            dragOrigin = imagePoint
            checkpoint()
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

    var selectedAnnotation: Annotation? {
        selection.flatMap { id in annotations.first { $0.id == id } }
    }

    /// The selected markup's box, normalized over the output canvas with y from
    /// the top, so the view can outline it on the preview.
    var selectionBox: CGRect? {
        selectedAnnotation.map { normalizedCanvasRect(fromImage: $0.bounds(minSide: minSide)) }
    }

    /// Where the resize handles go, normalized over the canvas: the two ends of
    /// a line, or the four corners of a region.
    var selectionHandles: [CGPoint] {
        guard let annotation = selectedAnnotation else { return [] }
        return handlePoints(of: annotation).map(normalizedCanvasPoint(fromImage:))
    }

    /// Which handle, if any, a grab lands on.
    private enum Grip {
        case start
        case end
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
    private var grip: Grip?

    private func handlePoints(of annotation: Annotation) -> [CGPoint] {
        switch annotation.tool.input {
        case .segment:
            return [annotation.start, annotation.end]
        case .region, .none:
            // `.none` here is an image overlay; `.move` itself is never stored.
            guard annotation.tool != .move else { return [] }
            let rect = annotation.bounds(minSide: minSide)
            return [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
            ]
        case .stroke, .point:
            // Freehand and badges scale with the weight slider instead.
            return []
        }
    }

    private func grip(near point: CGPoint, of annotation: Annotation) -> Grip? {
        let tolerance = minSide * 0.02
        let grips: [Grip] = annotation.tool.input == .segment
            ? [.start, .end]
            : [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let points = handlePoints(of: annotation)
        guard points.count == grips.count else { return nil }
        return zip(grips, points)
            .first { hypot(point.x - $0.1.x, point.y - $0.1.y) < tolerance }?.0
    }

    private func applyResize(base: Annotation, grip: Grip, to point: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == base.id }) else { return }
        var updated = base
        switch grip {
        case .start:
            updated.start = point
        case .end:
            updated.end = point
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Handles sit on the drawn box, so for an already-scaled image
            // overlay the drag defines the new rect outright.
            var rect = base.tool == .image
                ? base.bounds(minSide: minSide)
                : CGRect(
                    x: min(base.start.x, base.end.x),
                    y: min(base.start.y, base.end.y),
                    width: abs(base.start.x - base.end.x),
                    height: abs(base.start.y - base.end.y)
                )
            switch grip {
            case .topLeft:
                rect = CGRect(x: point.x, y: point.y, width: rect.maxX - point.x, height: rect.maxY - point.y)
            case .topRight:
                rect = CGRect(x: rect.minX, y: point.y, width: point.x - rect.minX, height: rect.maxY - point.y)
            case .bottomLeft:
                rect = CGRect(x: point.x, y: rect.minY, width: rect.maxX - point.x, height: point.y - rect.minY)
            default:
                rect = CGRect(x: rect.minX, y: rect.minY, width: point.x - rect.minX, height: point.y - rect.minY)
            }
            rect = rect.standardized
            updated.start = CGPoint(x: rect.minX, y: rect.minY)
            updated.end = CGPoint(x: rect.maxX, y: rect.maxY)
            if base.tool == .image { updated.weight = 1 }
        }
        annotations[index] = updated
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
        undoStack.append(EditState(annotations: annotations, source: source))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(EditState(annotations: annotations, source: source))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditState(annotations: annotations, source: source))
        restore(next)
    }

    private func restore(_ state: EditState) {
        if state.source !== source {
            adopt(state.source)
        }
        annotations = state.annotations
        pruneSelection()
    }

    // MARK: Crop, resize, combine

    /// Called while dragging with the crop tool armed; both points are
    /// normalized over the output canvas.
    func cropDragChanged(from anchor: CGPoint, to point: CGPoint) {
        let a = imagePoint(fromCanvasNormalized: anchor)
        let b = imagePoint(fromCanvasNormalized: point)
        cropRect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// The pending crop, normalized over the canvas, for the preview overlay.
    var cropBox: CGRect? {
        cropRect.map { normalizedCanvasRect(fromImage: $0) }
    }

    func applyCrop() {
        guard let rect = cropRect?.integral,
              rect.width > 8, rect.height > 8,
              let cropped = source.cropping(to: rect.intersection(sourceBounds))
        else { return }
        checkpoint()
        adopt(cropped)
        // Markup keeps its place on the picture, so it moves with the crop.
        annotations = annotations
            .map { $0.translated(by: CGSize(width: -rect.minX, height: -rect.minY)) }
            .filter { $0.bounds(minSide: minSide).intersects(sourceBounds) }
        cropping = false
        selection = nil
    }

    func resize(scale: CGFloat) {
        let width = Int((CGFloat(source.width) * scale).rounded())
        let height = Int((CGFloat(source.height) * scale).rounded())
        guard width > 8, height > 8, abs(scale - 1) > 0.001,
              let scaled = ImageOps.scaled(source, width: width, height: height)
        else { return }
        checkpoint()
        adopt(scaled)
        annotations = annotations.map { annotation in
            var scaledAnnotation = annotation
            scaledAnnotation.start = CGPoint(x: annotation.start.x * scale, y: annotation.start.y * scale)
            scaledAnnotation.end = CGPoint(x: annotation.end.x * scale, y: annotation.end.y * scale)
            scaledAnnotation.points = annotation.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            return scaledAnnotation
        }
    }

    /// Grabs another area shot and appends it to this canvas.
    func addCapture(axis: ImageOps.Axis) {
        CaptureService.capture(.area) { [weak self] image in
            guard let self, let image else { return }
            self.addCapture(image, axis: axis)
            self.flashSaveMessage("Added to canvas")
        }
    }

    /// Puts another capture on the same canvas, below or beside this one.
    func addCapture(_ image: CGImage, axis: ImageOps.Axis) {
        guard let combined = ImageOps.stacked([source, image], axis: axis, gap: 0) else { return }
        checkpoint()
        adopt(combined)
    }

    // MARK: Hiding text, pasting images

    /// Pixelates each line of text inside the region and nothing else, so a
    /// redaction doesn't have to swallow the surrounding layout.
    private func hideText(in region: CGRect) {
        let rect = region.integral.intersection(sourceBounds)
        guard rect.width > 8, rect.height > 8, let patch = source.cropping(to: rect) else { return }
        flashSaveMessage("Looking for text…")
        Task { @MainActor in
            let boxes = await TextRecognizer.textBoxes(in: patch)
            let placed: [Annotation] = boxes.compactMap { box in
                let shifted = box.offsetBy(dx: rect.minX, dy: rect.minY).intersection(sourceBounds)
                guard shifted.width > 2, shifted.height > 2 else { return nil }
                return Annotation(
                    tool: .pixelate,
                    start: CGPoint(x: shifted.minX, y: shifted.minY),
                    end: CGPoint(x: shifted.maxX, y: shifted.maxY),
                    color: currentColor,
                    weight: annotationWeight
                )
            }
            guard !placed.isEmpty else {
                flashSaveMessage("No text found there")
                return
            }
            checkpoint()
            // One assignment, so the image is recomposited once and not per line.
            annotations += placed
            flashSaveMessage("Hid \(placed.count) line\(placed.count == 1 ? "" : "s") of text")
        }
    }

    /// Drops the clipboard's image onto the capture as a movable overlay.
    func pasteImageOverlay() {
        guard let overlay = Clipboard.image() else {
            flashSaveMessage("No image on the clipboard")
            return
        }
        let width = CGFloat(source.width) * 0.4
        let height = width * CGFloat(overlay.height) / CGFloat(max(overlay.width, 1))
        let origin = CGPoint(
            x: (CGFloat(source.width) - width) / 2,
            y: (CGFloat(source.height) - height) / 2
        )
        let annotation = Annotation(
            tool: .image,
            start: origin,
            end: CGPoint(x: origin.x + width, y: origin.y + height),
            color: currentColor,
            image: overlay
        )
        commit(annotation)
        // Land on the Select tool so it can be dragged into place at once.
        tool = .move
        selection = annotation.id
    }

    // MARK: Pixel loupe and colour picker

    /// Magnified patch and colour readout under the pointer.
    func updateLoupe(atNormalized point: CGPoint) {
        guard inspecting else {
            loupe = nil
            return
        }
        if pixels == nil {
            pixels = PixelMap(source, width: source.width, height: source.height)
        }
        let imagePoint = self.imagePoint(fromCanvasNormalized: point)
        let x = Int(imagePoint.x.rounded(.down))
        let y = Int(imagePoint.y.rounded(.down))
        guard let pixels, x >= 0, y >= 0, x < pixels.width, y < pixels.height else {
            loupe = nil
            return
        }
        // Odd span so there is a true centre pixel to line the crosshair up on.
        let span = 15
        let patchRect = CGRect(
            x: x - span / 2,
            y: y - span / 2,
            width: span,
            height: span
        ).intersection(sourceBounds).integral
        loupe = Loupe(
            at: point,
            patch: patchRect.isEmpty ? nil : source.cropping(to: patchRect),
            hex: pixels.hex(x, y),
            color: pixels.color(x, y),
            pixel: CGPoint(x: x, y: y)
        )
    }

    func copyPickedColor() {
        guard let loupe else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loupe.hex, forType: .string)
        flashSaveMessage("Copied \(loupe.hex)")
    }

    // MARK: Pin

    /// Floats the finished render above everything as a borderless window.
    func pinToDesktop() {
        guard let rendered = renderFull() else { return }
        PinnedWindow.show(rendered)
        flashSaveMessage("Pinned — ⌘W or double-click to close")
    }

    private var sourceBounds: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))
    }

    private var minSide: CGFloat {
        CGFloat(min(source.width, source.height))
    }

    /// Single path for swapping the capture: everything derived from it has to
    /// be rebuilt, or the preview keeps rendering the old pixels.
    private func adopt(_ image: CGImage) {
        source = image
        autoColors = ColorAnalysis.autoGradient(for: image)
        filteredSource = ImageFilters.apply(settings.filter, to: image)
        pixels = nil
        cropRect = nil
        rebuildComposition()
        renderPreview()
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

    private func normalizedCanvasPoint(fromImage point: CGPoint) -> CGPoint {
        let (canvas, origin, _) = layout()
        return CGPoint(x: (point.x + origin.x) / canvas.width, y: (point.y + origin.y) / canvas.height)
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

    var saveFolderName: String { Preferences.shared.saveFolderName }

    func saveToFolder() {
        guard let full = renderFull() else { return }
        let folder = Preferences.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(defaultFilename())
        if ImageWriter.write(full, to: url.path, format: settings.exportFormat) {
            flashSaveMessage("Saved to \(folder.lastPathComponent)")
        } else {
            flashSaveMessage("Could not write to \(folder.lastPathComponent)")
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

    /// OCR via Vision: recognized text — and any QR or barcode payload — from
    /// the original capture → clipboard.
    func copyRecognizedText() {
        let image = source
        flashSaveMessage("Recognizing text…")
        Task { @MainActor in
            let text = await TextRecognizer.recognize(in: image)
            let codes = await TextRecognizer.codes(in: image)
            // A code is usually the point of the shot when there is one, so it
            // goes first.
            let combined = (codes + (text.isEmpty ? [] : [text])).joined(separator: "\n")
            guard !combined.isEmpty else {
                flashSaveMessage("No text found")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(combined, forType: .string)
            if codes.isEmpty {
                flashSaveMessage("Text copied (\(combined.count) chars)")
            } else {
                flashSaveMessage("Copied \(codes.count) code\(codes.count == 1 ? "" : "s")\(text.isEmpty ? "" : " + text")")
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
