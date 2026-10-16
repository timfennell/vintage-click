import AppKit
import CSpirula
import Foundation
import MetalKit

// Stage 1 spike: fly through a 3DGS scan with a game controller.
//   SplatCamera [model.ply] [--res WxH] [--fps 24] [--bench FRAMES] [--sh DEGREE] [--still out.png]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let res = (option("--res") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
let bench = Int(option("--bench") ?? "0") ?? 0
let shOverride = option("--sh").flatMap { Int32($0) }
let stillPath = option("--still")
// Play at a film cadence (18-24 fps feels like film); the bench runs uncapped.
let filmFPS = bench > 0 ? 0 : Double(option("--fps") ?? "24") ?? 24
let plyPath = args.first ?? NSString(string: "~/Desktop/bee/bee-final.ply").expandingTildeInPath

let app = NSApplication.shared
app.setActivationPolicy(.regular)

print("Loading \(plyPath)")
let t0 = CACurrentMediaTime()
let model: SplatModel
do { model = try loadPLY(URL(fileURLWithPath: plyPath)) } catch {
    print("Cannot load the model: \(error)")
    exit(1)
}
print(String(format: "%d splats, SH degree %d, read in %.1f s", model.count, model.shDegree,
             CACurrentMediaTime() - t0))

let viewer: Viewer
do { viewer = try Viewer(model: model, width: res[0], height: res[1]) } catch {
    print("\(error)")
    exit(1)
}
if let d = shOverride { viewer.setDegree(d) }
print(String(format: "Uploaded to the GPU in %.1f s total", CACurrentMediaTime() - t0))

// The window shows the fixed-size render scaled to fit.
let screen = NSScreen.main!.visibleFrame
let scale = min(1, min(screen.width * 0.9 / CGFloat(res[0]), screen.height * 0.9 / CGFloat(res[1])))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(res[0]) * scale,
                                          height: CGFloat(res[1]) * scale),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
window.title = "Splat Camera"
window.contentAspectRatio = NSSize(width: res[0], height: res[1])
let view = MTKView(frame: window.contentLayoutRect, device: viewer.device)
view.colorPixelFormat = .bgra8Unorm
view.autoResizeDrawable = false
view.drawableSize = CGSize(width: res[0], height: res[1])
view.preferredFramesPerSecond = filmFPS > 0 ? Int(filmFPS.rounded()) : 120
viewer.filmFPS = filmFPS
view.delegate = viewer
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)

viewer.onStats = { line in
    window.title = "Splat Camera — \(line)"
    print(line)
}
if bench > 0 {
    viewer.benchFrames = bench
    viewer.onBenchDone = { report in
        print(report)
        if let p = stillPath { viewer.saveStill(to: URL(fileURLWithPath: p)) }
        sr_shutdown()
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { sr_shutdown() }
}
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
