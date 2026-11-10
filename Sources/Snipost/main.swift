import AVFoundation
import AppKit

// Headless modes (used for CI / render verification, no UI):
//   Snipost --beautify <input.png> <output.png>   render a file through the pipeline
//   Snipost --selftest <output.png>               render a synthetic screenshot
let arguments = CommandLine.arguments
if arguments.count >= 2 {
    switch arguments[1] {
    case "--beautify" where arguments.count == 4:
        HeadlessRender.beautify(inputPath: arguments[2], outputPath: arguments[3])
        exit(0)
    case "--selftest" where arguments.count == 3:
        HeadlessRender.selftest(outputPath: arguments[2])
        exit(0)
    case "--stitchtest" where arguments.count == 3:
        HeadlessRender.stitchTest(outputPath: arguments[2])
        exit(0)
    case "--ocrtest":
        HeadlessRender.ocrTest()
        exit(0)
    case "--watchtest" where arguments.count == 4:
        // Snipost --watchtest <image.png> <claude|codex|opencode|gemini|grok>
        guard let image = CaptureService.loadCGImage(at: URL(fileURLWithPath: arguments[2])),
              let agent = WatchAgent(rawValue: arguments[3]) else { print("bad args"); exit(2) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let o = try await AgentRunner.observe(agent: agent, image: image, condition: "a JSON document is visible", previousNote: nil)
                print("condition_met=\(o.conditionMet) summary=\(o.summary)")
            } catch {
                print("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    case "--editortest" where arguments.count == 4:
        // Snipost --editortest <in.png> <out.png>: render the editor window offscreen.
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            guard let image = CaptureService.loadCGImage(at: URL(fileURLWithPath: arguments[2])) else { exit(2) }
            let controller = EditorWindowController(image: image)
            controller.window?.setFrameOrigin(NSPoint(x: -4000, y: 0))
            controller.window?.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            if let view = controller.window?.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[3]))
                print("wrote \(arguments[3])")
            }
        }
        exit(0)
    case "--videotest" where arguments.count == 3:
        // Snipost --videotest <video.mp4>: trims to 1.0–3.0 s in place, then exports a GIF.
        let url = URL(fileURLWithPath: arguments[2])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await VideoExport.trim(url, to: CMTimeRange(
                    start: CMTime(seconds: 1, preferredTimescale: 600),
                    end: CMTime(seconds: 3, preferredTimescale: 600)))
                let trimmed = try await AVURLAsset(url: url).load(.duration).seconds
                print(String(format: "trimmed duration %.2fs", trimmed))
                let gif = try await VideoExport.gif(from: url, preset: .small)
                let source = CGImageSourceCreateWithURL(gif as CFURL, nil)
                print("gif frames \(source.map(CGImageSourceGetCount) ?? 0), \(gif.fileSize) bytes")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    case "--help", "-h":
        print("""
        Snipost — minimal screenshot beautifier for macOS
          (no arguments)                     run the menu bar app
          --beautify <in.png> <out.png>      beautify an existing image, headless
          --selftest <out.png>               render a synthetic test image, headless
        """)
        exit(0)
    default:
        break
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run() // never returns; `delegate` stays alive in this scope
}
