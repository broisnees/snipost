import SwiftUI

/// Editor layout: a toolbar (markup tools · canvas size · export actions)
/// over a canvas, with a tabbed inspector on the right.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var showShare = false
    @State private var tab: InspectorTab = .background
    @State private var showAllWallpapers = false

    enum InspectorTab: String, CaseIterable, Identifiable {
        case background = "Background"
        case frame = "Frame"
        case effects = "Effects"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: $showShare) {
            ShareSheetView(model: model)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Markup tools
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    ToolbarIcon(symbol: tool.symbolName, help: tool.rawValue, isOn: model.tool == tool) {
                        model.tool = tool
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))

            if model.tool != .move {
                HStack(spacing: 4) {
                    ForEach(Array(Annotation.palette.enumerated()), id: \.offset) { index, rgb in
                        ColorDot(rgb: rgb, isSelected: model.annotationColorIndex == index) {
                            model.annotationColorIndex = index
                        }
                    }
                }
                if model.tool == .text, let binding = model.lastTextBinding {
                    TextField("Label text", text: binding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            HStack(spacing: 2) {
                ToolbarIcon(symbol: "arrow.uturn.backward", help: "Undo markup (⌘Z)", isOn: false) {
                    model.undoAnnotation()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.annotations.isEmpty)
                ToolbarIcon(symbol: "trash", help: "Clear all markup", isOn: false) {
                    model.clearAnnotations()
                }
                .disabled(model.annotations.isEmpty)
            }

            Spacer(minLength: 8)

            if let message = model.lastSaveMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            Menu {
                Button("Upload to Google Drive", systemImage: "icloud.and.arrow.up") { model.uploadToDrive() }
                Button("Post to social…", systemImage: "paperplane") { showShare = true }
                Divider()
                Button("Copy recognized text", systemImage: "text.viewfinder") { model.copyRecognizedText() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .fixedSize()

            Menu {
                Button("Save to Desktop") { model.saveToDesktop() }
                Button("Save As…") { model.saveAs() }
                Divider()
                Picker("Format", selection: $model.settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            } primaryAction: {
                model.saveAs()
            }
            .menuStyle(.button)
            .fixedSize()
            .keyboardShortcut("s", modifiers: .command)

            Button {
                model.copyToClipboard()
            } label: {
                Label(model.justCopied ? "Copied" : "Copy", systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: .command)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack {
            CanvasBackdrop(transparent: model.settings.background == .transparent)

            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            model.dragChanged(atNormalized: normalized(value.location, in: geo.size))
                                        }
                                        .onEnded { value in
                                            model.dragEnded(atNormalized: normalized(value.location, in: geo.size))
                                        }
                                )
                        }
                    )
                    .padding(36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                Text(model.outputSizeText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider().frame(height: 12)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .padding(.bottom, 10)
        }
    }

    private var hint: String {
        switch model.tool {
        case .move:
            return model.settings.cursor == .none ? "Pick a markup tool to annotate" : "Drag to place the cursor"
        case .text: return "Click to place a label"
        case .blur: return "Drag over anything sensitive"
        default: return "Drag on the image to draw"
        }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .background: backgroundTab
                    case .frame: frameTab
                    case .effects: effectsTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Background tab

    @ViewBuilder private var backgroundTab: some View {
        InspectorSection("Gradients") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                Swatch(colors: model.autoColors, help: "Auto — from the screenshot",
                       isSelected: model.settings.background == .auto, badge: "A") {
                    model.settings.background = .auto
                }
                ForEach(GradientPreset.all) { preset in
                    Swatch(colors: preset.colors, help: preset.name,
                           isSelected: model.settings.background == .preset(preset)) {
                        model.settings.background = .preset(preset)
                    }
                }
            }
        }

        if !model.wallpapers.isEmpty {
            InspectorSection("macOS wallpapers") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(showAllWallpapers ? model.wallpapers : Array(model.wallpapers.prefix(8))) { wallpaper in
                        wallpaperThumb(wallpaper)
                    }
                }
                if model.wallpapers.count > 8 {
                    Button(showAllWallpapers ? "Show fewer" : "Show all \(model.wallpapers.count)") {
                        withAnimation(.easeOut(duration: 0.2)) { showAllWallpapers.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }

        InspectorSection("Custom") {
            VStack(spacing: 10) {
                HStack {
                    Text("Solid color")
                    Spacer()
                    ColorPicker("", selection: $model.customSolid, supportsOpacity: false).labelsHidden()
                }
                .onChange(of: model.customSolid) { model.applyCustomSolid() }
                HStack {
                    Text("Gradient")
                    Spacer()
                    ColorPicker("", selection: $model.customGradientStart, supportsOpacity: false).labelsHidden()
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    ColorPicker("", selection: $model.customGradientEnd, supportsOpacity: false).labelsHidden()
                }
                .onChange(of: model.customGradientStart) { model.applyCustomGradient() }
                .onChange(of: model.customGradientEnd) { model.applyCustomGradient() }
                HStack(spacing: 8) {
                    WideChip(title: "Image…", symbol: "photo",
                             isSelected: model.settings.background == .image && model.selectedWallpaper == nil) {
                        model.chooseBackgroundImage()
                    }
                    WideChip(title: "None", symbol: "square.dashed",
                             isSelected: model.settings.background == .transparent) {
                        model.settings.background = .transparent
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    private func wallpaperThumb(_ wallpaper: Wallpaper) -> some View {
        let isSelected = model.selectedWallpaper == wallpaper.url && model.settings.background == .image
        return Button {
            model.selectWallpaper(wallpaper)
        } label: {
            Group {
                if let thumb = model.thumbnails[wallpaper.url] {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .overlay(SelectionRing(isSelected: isSelected, radius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(wallpaper.name)
    }

    // MARK: Frame tab

    @ViewBuilder private var frameTab: some View {
        InspectorSection("Canvas size") {
            Picker("", selection: $model.settings.aspect) {
                ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        InspectorSection("Frame") {
            VStack(spacing: 14) {
                SliderRow(title: "Padding", value: $model.settings.paddingFraction, range: 0.02...0.25) {
                    "\(Int($0 * 100))%"
                }
                SliderRow(title: "Corner radius", value: $model.settings.cornerRadius, range: 0...48) {
                    "\(Int($0)) pt"
                }
                SliderRow(title: "Shadow", value: $model.settings.shadowOpacity, range: 0...0.9) {
                    "\(Int($0 * 100))%"
                }
            }
        }

        InspectorSection("Cursor") {
            HStack(spacing: 6) {
                ForEach(CursorStyle.allCases) { style in
                    IconChip(symbol: style.symbolName, help: style.rawValue, isSelected: model.settings.cursor == style) {
                        model.settings.cursor = style
                    }
                }
            }
            if model.settings.cursor != .none {
                SliderRow(title: "Size", value: $model.settings.cursorSize, range: 32...220) { "\(Int($0))" }
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Effects tab

    @ViewBuilder private var effectsTab: some View {
        InspectorSection("Look") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(ImageFilter.allCases) { filter in
                    WideChip(title: filter.rawValue, symbol: nil, isSelected: model.settings.filter == filter) {
                        model.settings.filter = filter
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let format: (CGFloat) -> String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

private struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 26)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
        .help(help)
    }
}

private struct IconChip: View {
    let symbol: String
    let help: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
        .help(help)
    }
}

private struct WideChip: View {
    let title: String
    let symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
    }
}

private struct Swatch: View {
    let colors: [RGB]
    let help: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    colors: colors.map { Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b)) },
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .overlay {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .overlay(SelectionRing(isSelected: isSelected, radius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
        .help(help)
    }
}

private struct ColorDot: View {
    let rgb: RGB
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b)))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(isSelected ? 1 : 0))
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
    }
}

/// Ring drawn outside the element so corners stay concentric.
private struct SelectionRing: View {
    let isSelected: Bool
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-3)
            .opacity(isSelected ? 1 : 0)
    }
}

/// Tactile press feedback: 0.96 scale, interruptible, only transform animates.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Dotted workspace behind the render; a checkerboard when it's transparent.
private struct CanvasBackdrop: View {
    let transparent: Bool

    var body: some View {
        Canvas { context, size in
            if transparent {
                let cell: CGFloat = 12
                for row in 0...Int(size.height / cell) {
                    for column in 0...Int(size.width / cell) where (row + column) % 2 == 0 {
                        let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        context.fill(Path(rect), with: .color(.primary.opacity(0.06)))
                    }
                }
            } else {
                let step: CGFloat = 18
                for y in stride(from: step / 2, to: size.height, by: step) {
                    for x in stride(from: step / 2, to: size.width, by: step) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                                     with: .color(.primary.opacity(0.12)))
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
