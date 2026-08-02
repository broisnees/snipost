# Snipost

A minimal, modern screenshot tool for macOS. **Snip → auto-beautify → post.**

Capture a screenshot and it appears already beautified: a background gradient derived
from the screenshot's own colors, auto-growing padding, rounded corners, and a soft
shadow. One click to copy or save. (See [PRODUCT.md](PRODUCT.md) for the full vision —
Google Drive sync and social posting are next.)

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- Swift toolchain (Xcode or Command Line Tools)

## Run it

```sh
# Dev run (menu bar icon appears; Ctrl-C to quit)
swift run Snipost

# Or build a proper app bundle
./Scripts/make-app.sh
open dist/Snipost.app
```

> **Screen Recording permission:** capture goes through ScreenCaptureKit. macOS
> attributes the permission to the invoking app — your terminal during `swift run`, or
> Snipost.app when bundled. Grant it in System Settings → Privacy & Security →
> Screen Recording if window contents come out black.

## Use it

| Action | Hotkey (remappable in Settings) | Also in menu bar |
|---|---|---|
| Capture area | ⌥⇧S | ✓ |
| Capture window | ⌥⇧W | ✓ |
| Capture full screen | ⌥⇧F | ✓ |
| Snip to clipboard (plain, no editing) | ⌥⇧C | ✓ |
| Scrolling capture (auto-scroll + stitch) | ⌥⇧R | ✓ |
| OCR snip (recognized text → clipboard) | ⌥⇧O | ✓ |

After a capture, the editor opens with the beautified result.

**Markup** — arrow, line, box, ellipse, freehand pen, highlighter, text, numbered step
badges, blur, pixelate, solid redaction, spotlight, and a measure line that stamps the
pixel distance. Everything stays editable: the Select tool picks a markup back up,
drags it, and resizes it by its handles; ⌫ deletes one, ⌘Z / ⇧⌘Z walk the whole
history, and picking a colour or weight restyles whatever is selected.

- **Hide text** — drag over a region and Vision finds the lines inside it, pixelating
  the words and nothing around them
- **Erase** — wipes something out using the colour of its surroundings; on the flat
  backgrounds UI screenshots are made of, it reads as if nothing was ever there
- **Paste over (⌘V)** — drops the clipboard's image on top as a movable overlay

**The capture itself** — crop (with thirds guides), resize, and *Add below* to put
another capture on the same canvas. *Pick* magnifies the pixels under the pointer and
copies the hex; *Pin* floats the render above every other window (drag to move, scroll
to resize, ⌘W to dismiss).

Tweak:

- **Background** — auto gradient from the screenshot's colors, 10 presets, your Mac's
  system wallpapers, custom solid color / two-color gradient pickers, any image file,
  or transparent
- **Effect** — Vivid, Warm, Cool, Mono, Pixel, Matrix, Comic
- **Cursor** — overlay a macOS cursor (arrow, hand, I-beam, crosshair); click the
  preview to place it, slider to resize
- **Padding / corner radius / shadow** and canvas aspect (16:9, 1:1, 4:5, 4:3)
- **Format** — export as PNG, JPEG, or HEIC

then **Copy (⌘C)**, save to your chosen folder (Settings → Save folder, Desktop by
default), or **Save… (⌘S)**. The **Text** button copies recognized text and any QR or
barcode payload.

## Headless render check (no UI)

```sh
swift build
.build/debug/Snipost --selftest /tmp/snipost-test.png     # synthetic screenshot
.build/debug/Snipost --beautify in.png out.png            # your own image
```

## Architecture

```
Sources/Snipost/
  main.swift                  entry point + headless CLI modes
  AppDelegate.swift           menu bar item, global hotkeys, editor windows
  Capture/CaptureService.swift    ScreenCaptureKit capture + window isolation
  Render/
    BeautifySettings.swift    settings model, gradient + aspect presets
    ColorAnalysis.swift       edge-color sampling → auto gradient
    BeautifyRenderer.swift    CoreGraphics compositor (bg → shadow → rounded image)
    AnnotationRenderer.swift  markup model + compositing onto the capture
    ImageOps.swift            scale and stack captures onto one canvas
    PixelMap.swift            per-pixel alpha and colour lookup
    HeadlessRender.swift      --beautify/--selftest CLI + PNG writer
  Editor/                     SwiftUI editor window
  Support/                    Carbon global hotkeys, clipboard, pinned windows
```

## Roadmap

- [x] Menu bar app, global hotkeys, area/window/screen capture
- [x] Auto-beautify: edge-color gradient, auto-grow padding, radius, shadow
- [x] Aspect presets, gradient gallery, image backgrounds, transparent export
- [x] Copy / Save / headless render mode
- [x] Screen Recording permission prompt on first launch
- [x] macOS cursor overlay (vector, drag-to-place), image filters, PNG/JPEG/HEIC
- [x] Floating post-capture thumbnail (Settings → After capture → Floating thumbnail)
- [x] Google Drive sync (`drive.file` OAuth + PKCE) with instant share link
- [x] Social posting: web intents (X/Threads/LinkedIn) + Bluesky & Mastodon APIs
- [x] Annotations: 15 tools, selection with move/resize handles, full undo/redo
- [x] Crop, resize, combine captures, pin to desktop, pixel loupe + colour picker
- [x] Hide-text redaction and colour-matched erase (Vision + surrounding-colour fill)
- [x] ScreenCaptureKit capture backend, OCR copy-text (Vision)
- [x] History library (menu bar → History…), hotkey customization
- [x] Scrolling capture (⌥⇧R — auto-scrolls and stitches; needs Accessibility permission)
- [ ] Sparkle updates + notarized DMG (needs a Developer ID certificate)
