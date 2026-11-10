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

> **Screen Recording permission:** capture uses the system `screencapture` tool. macOS
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
| Scrolling capture (auto-scroll or scroll yourself; sticky bars kept once) | ⌥⇧R | ✓ |
| Full screen to clipboard (plain) | ⌥⇧G | ✓ |
| Capture bar (all modes) | ⌥⇧X | ✓ |
| Repeat last area | ⌥⇧L | |
| OCR snip (recognized text → clipboard) | ⌥⇧O | ✓ |
| Record a screen region (.mp4 → Movies/Snipost) | ⌥⇧V | ✓ |
| Watch a region with AI (Claude) | ⌥⇧A | ✓ |

**Default screenshot app:** Settings → General → *Make Snipost the default screenshot
app* turns off macOS's screenshot shortcuts and binds ⌘⇧3 (screen), ⌘⇧4 (area),
⌃⌘⇧3 / ⌃⌘⇧4 (screen / area → clipboard) and ⌘⇧5 (capture bar: every screenshot
mode plus recording and AI watch) to Snipost. They're handed back to macOS
when Snipost quits.

**While selecting an area:** Space switches to window capture (like macOS) · Return
recalls your last area · arrow keys nudge it, ⇧+arrows resize, ⌥ moves 10 pt · Return
captures. *Repeat last area* (⌥⇧L) re-captures it with no overlay. A **self-timer**
(3/5/10 s, in the ⌘⇧5 bar or Settings → Capture) counts down before the screen is
frozen — open a menu or hover something first.

**Recordings:** the preview window trims in place (QuickTime-style handles) and exports a
looping GIF — Small 480 px/10 fps for Slack, Medium 720 px/12 fps for GitHub, Large
960 px/15 fps — copied to the clipboard and shown in Finder.

**Quick Look:** every capture and recording lands as a floating card (bottom-right).
Drag it into any app, click it or press Space for a full Quick Look (videos play),
or use the Copy / Save / Edit buttons.

**Watch with AI:** drag a region, optionally type a condition ("tell me when the build
finishes"). Snipost samples the region every few seconds, only asks the agent when the
pixels change, and sends a notification when the condition is met. It uses an agent
CLI you already have signed in — Claude Code, Codex, OpenCode, Gemini CLI or Grok —
run read-only (pick it in Settings → AI Watch). An Anthropic API key is an optional
fallback.

After a capture, the editor opens with the beautified result. Tweak:

- **Background** — auto gradient from the screenshot's colors, 10 presets, your Mac's
  system wallpapers, custom solid color / two-color gradient pickers, any image file,
  or transparent
- **Effect** — Vivid, Warm, Cool, Mono, Pixel, Matrix, Comic
- **Cursor** — overlay a macOS cursor (arrow, hand, I-beam, crosshair); click the
  preview to place it, slider to resize
- **Padding / corner radius / shadow** and canvas aspect (16:9, 1:1, 4:5, 4:3)
- **Format** — export as PNG, JPEG, or HEIC

then **Copy (⌘C)**, **Save to Desktop**, or **Save… (⌘S)**.

## Headless render check (no UI)

```sh
swift build
.build/debug/Snipost --selftest /tmp/snipost-test.png     # synthetic screenshot
.build/debug/Snipost --beautify in.png out.png            # your own image
.build/debug/Snipost --stitchtest out.png                 # scrolling-capture stitcher
.build/debug/Snipost --videotest clip.mp4                 # trim (in place) + GIF export
.build/debug/Snipost --watchtest shot.png claude          # AI-watch agent round trip
.build/debug/Snipost --editortest in.png out.png          # render the editor window
```

## Architecture

```
Sources/Snipost/
  main.swift                  entry point + headless CLI modes
  AppDelegate.swift           menu bar item, global hotkeys, editor windows
  Capture/CaptureService.swift    system screencapture wrapper (ScreenCaptureKit later)
  Render/
    BeautifySettings.swift    settings model, gradient + aspect presets
    ColorAnalysis.swift       edge-color sampling → auto gradient
    BeautifyRenderer.swift    CoreGraphics compositor (bg → shadow → rounded image)
    HeadlessRender.swift      --beautify/--selftest CLI + PNG writer
  Editor/                     SwiftUI editor window
  Support/                    Carbon global hotkeys, clipboard
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
- [x] Annotations: arrow, box, text, blur/redact with colors and undo
- [x] ScreenCaptureKit capture backend, OCR copy-text (Vision)
- [x] History library (menu bar → History…), hotkey customization
- [x] Scrolling capture (⌥⇧R — auto-scrolls and stitches; needs Accessibility permission)
- [ ] Sparkle updates + notarized DMG (needs a Developer ID certificate)
