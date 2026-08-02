import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showShare = false

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        annotateSection
                        backgroundSection
                        wallpaperSection
                        customColorSection
                        filterSection
                        cursorSection
                        paddingSection
                        radiusSection
                        shadowSection
                        canvasSection
                        formatSection
                    }
                    .padding(.bottom, 12)
                }
                footer
            }
            .frame(width: 284)
            .padding(16)
        }
        .frame(minWidth: 920, minHeight: 600)
        .sheet(isPresented: $showShare) {
            ShareSheetView(model: model)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        ZStack {
            if model.settings.background == .transparent {
                CheckerboardView()
            } else {
                Color(nsColor: .underPageBackgroundColor)
            }
            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(
                        // Subtle outline so the render reads as an object, not a hole.
                        RoundedRectangle(cornerRadius: 1)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.1)
                                    : Color.black.opacity(0.1),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            model.dragChanged(atNormalized: CGPoint(
                                                x: value.location.x / max(geo.size.width, 1),
                                                y: value.location.y / max(geo.size.height, 1)
                                            ))
                                        }
                                        .onEnded { value in
                                            model.dragEnded(atNormalized: CGPoint(
                                                x: value.location.x / max(geo.size.width, 1),
                                                y: value.location.y / max(geo.size.height, 1)
                                            ))
                                        }
                                )
                                .overlay(selectionOverlay(in: geo.size))
                        }
                    )
                    .padding(28)
                    // Focus lets ⌫ reach the selected markup; the sidebar keeps
                    // a visible Delete for anyone who never clicks the preview.
                    .focusable()
                    .onKeyPress(.delete) {
                        guard model.selection != nil else { return .ignored }
                        model.deleteSelection()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard model.selection != nil else { return .ignored }
                        model.selection = nil
                        return .handled
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Marching-ants box with corner handles around the selected markup. Drawn
    /// over the preview rather than into the image, so it never exports.
    private func selectionOverlay(in size: CGSize) -> some View {
        Canvas { context, _ in
            guard let box = model.selectionBox else { return }
            let rect = CGRect(
                x: box.minX * size.width,
                y: box.minY * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            ).insetBy(dx: -2, dy: -2)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            // Two offset dashes stay visible on light and dark content alike.
            context.stroke(path, with: .color(.black.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4], dashPhase: 4))

            for corner in [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
            ] {
                let handle = Path(ellipseIn: CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7))
                context.fill(handle, with: .color(.white))
                context.stroke(handle, with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Sections

    private var annotateSection: some View {
        section("Annotate") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(AnnotationTool.allCases) { tool in
                    toolButton(tool)
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(Annotation.palette.enumerated()), id: \.offset) { index, rgb in
                    colorDot(rgb, isSelected: model.annotationColorIndex == index) {
                        model.annotationColorIndex = index
                        model.restyleSelection()
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Weight")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $model.annotationWeight, in: 0.5...3) { editing in
                    if !editing { model.restyleSelection() }
                }
            }

            HStack(spacing: 6) {
                Button("Undo") { model.undo() }
                    .controlSize(.small)
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { model.redo() }
                    .controlSize(.small)
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                Button("Delete") { model.deleteSelection() }
                    .controlSize(.small)
                    .disabled(model.selection == nil)
                Button("Clear") { model.clearAnnotations() }
                    .controlSize(.small)
                    .disabled(model.annotations.isEmpty)
            }

            if let binding = model.lastTextBinding, model.tool == .text || model.selection != nil {
                TextField("Text", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            Text(model.tool.hint)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isSelected = model.tool == tool
        return Button { model.tool = tool } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressableButtonStyle())
        .help(tool.rawValue)
    }

    private var backgroundSection: some View {
        section("Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                swatch(
                    colors: model.autoColors,
                    label: "Auto",
                    isSelected: model.settings.background == .auto
                ) { model.settings.background = .auto }

                ForEach(GradientPreset.all) { preset in
                    swatch(
                        colors: preset.colors,
                        label: preset.name,
                        isSelected: model.settings.background == .preset(preset)
                    ) { model.settings.background = .preset(preset) }
                }

                iconSwatch(
                    systemImage: "photo",
                    label: "Image file…",
                    isSelected: model.settings.background == .image && model.selectedWallpaper == nil
                ) { model.chooseBackgroundImage() }

                iconSwatch(
                    systemImage: "square.slash",
                    label: "Transparent",
                    isSelected: model.settings.background == .transparent
                ) { model.settings.background = .transparent }
            }
        }
    }

    private var wallpaperSection: some View {
        Group {
            if !model.wallpapers.isEmpty {
                section("macOS wallpapers") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.wallpapers) { wallpaper in
                                wallpaperThumb(wallpaper)
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 3)
                    }
                    .frame(height: 44)
                }
            }
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
            .frame(width: 58, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .overlay(selectionRing(isSelected: isSelected, radius: 6))
        }
        .buttonStyle(PressableButtonStyle())
        .help(wallpaper.name)
    }

    private var customColorSection: some View {
        section("Custom color") {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    ColorPicker("", selection: $model.customSolid, supportsOpacity: false)
                        .labelsHidden()
                    Text("Solid")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: model.customSolid) { model.applyCustomSolid() }

                Divider().frame(height: 18)

                HStack(spacing: 8) {
                    ColorPicker("", selection: $model.customGradientStart, supportsOpacity: false)
                        .labelsHidden()
                    ColorPicker("", selection: $model.customGradientEnd, supportsOpacity: false)
                        .labelsHidden()
                    Text("Gradient")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: model.customGradientStart) { model.applyCustomGradient() }
                .onChange(of: model.customGradientEnd) { model.applyCustomGradient() }
            }
        }
    }

    private var filterSection: some View {
        section("Effect") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(ImageFilter.allCases) { filter in
                    chip(filter.rawValue, isSelected: model.settings.filter == filter) {
                        model.settings.filter = filter
                    }
                }
            }
        }
    }

    private var cursorSection: some View {
        section("Cursor") {
            HStack(spacing: 6) {
                ForEach(CursorStyle.allCases) { style in
                    iconButton(
                        symbol: style.symbolName,
                        isSelected: model.settings.cursor == style,
                        help: style.rawValue
                    ) { model.settings.cursor = style }
                }
            }
            if model.settings.cursor != .none {
                Slider(value: $model.settings.cursorSize, in: 32...220)
                Text("Drag on the preview to position the cursor")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var paddingSection: some View {
        section("Padding", trailing: "\(Int(model.settings.paddingFraction * 100))%") {
            Slider(value: $model.settings.paddingFraction, in: 0.02...0.25)
        }
    }

    private var radiusSection: some View {
        section("Corner radius", trailing: "\(Int(model.settings.cornerRadius)) px") {
            Slider(value: $model.settings.cornerRadius, in: 0...80)
        }
    }

    private var shadowSection: some View {
        section("Shadow", trailing: "\(Int(model.settings.shadowOpacity * 100))%") {
            Slider(value: $model.settings.shadowOpacity, in: 0...0.9)
        }
    }

    private var canvasSection: some View {
        section("Canvas") {
            Picker("", selection: $model.settings.aspect) {
                ForEach(AspectPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var formatSection: some View {
        section("Format") {
            Picker("", selection: $model.settings.exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.outputSizeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let message = model.lastSaveMessage {
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }

            Button {
                model.copyToClipboard()
            } label: {
                Label(model.justCopied ? "Copied" : "Copy", systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: .command)

            HStack(spacing: 8) {
                Button("Save to Desktop") { model.saveToDesktop() }
                    .frame(maxWidth: .infinity)
                Button("Save…") { model.saveAs() }
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut("s", modifiers: .command)
            }

            HStack(spacing: 8) {
                Button {
                    model.uploadToDrive()
                } label: {
                    Label("Drive", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    showShare = true
                } label: {
                    Label("Post…", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    model.copyRecognizedText()
                } label: {
                    Label("Text", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .help("Copy recognized text (OCR)")
            }
        }
    }

    // MARK: Building blocks

    private func section(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    /// Ring drawn outside the element: radius grows with the offset so the
    /// corners stay concentric.
    private func selectionRing(isSelected: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius + 3)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-3)
            .opacity(isSelected ? 1 : 0)
    }

    private func iconButton(symbol: String, isSelected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 42, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func colorDot(_ rgb: RGB, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b)))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
                .padding(4) // widen the hit area
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func swatch(colors: [RGB], label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let gradient = LinearGradient(
            colors: colors.map { Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b)) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(gradient)
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .overlay(selectionRing(isSelected: isSelected, radius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressableButtonStyle())
        .help(label)
    }

    private func iconSwatch(systemImage: String, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 34)
                .overlay(Image(systemName: systemImage).font(.system(size: 13)).foregroundStyle(.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .overlay(selectionRing(isSelected: isSelected, radius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressableButtonStyle())
        .help(label)
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

/// Classic transparency checkerboard for the preview when the background is clear.
private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.05)))
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
