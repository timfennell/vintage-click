import AppKit
import CSpirula
import Foundation
import MetalKit

// Stage 1 spike: fly through a 3DGS scan with a game controller.
//   SplatCamera [model.ply] [--res 1620x1080] [--fps 24] [--scale M_PER_UNIT] [--ev 12]
//               [--cells 32] [--lens I] [--aperture F] [--film I]
//               [--photo-res WxH] [--bench FRAMES] [--pinhole] [--shoot out.png]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let res = (option("--res") ?? "1620x1080").split(separator: "x").compactMap { Int($0) }
let bench = Int(option("--bench") ?? "0") ?? 0
let shootPath = option("--shoot")
// --burst N: fire N frames a second apart while the finder keeps running.
let burst = Int(option("--burst") ?? "1") ?? 1
let photoRes = option("--photo-res").map { $0.split(separator: "x").compactMap { Int($0) } }
let sceneScale = option("--scale").flatMap { Float($0) }
let sceneEV = option("--ev").flatMap { Float($0) }
let cells = option("--cells").flatMap { Int($0) }
let lensChoice = option("--lens").flatMap { Int($0) }
let apertureChoice = option("--aperture").flatMap { Float($0) }
let filmChoice = option("--film").flatMap { Int($0) }
let lightingMode = args.contains("--lighting-mode")
args.removeAll { $0 == "--lighting-mode" }
let demoLights = args.contains("--demo-lights")
args.removeAll { $0 == "--demo-lights" }
let pinhole = args.contains("--pinhole")
args.removeAll { $0 == "--pinhole" }
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
// Exposures develop at their own (higher) resolution: twice the finder by default.
let photo = photoRes.map { ($0[0], $0[1]) } ?? (res[0] * 2, res[1] * 2)
do { viewer = try Viewer(model: model, width: res[0], height: res[1], photo: photo, metresPerUnit: sceneScale) } catch {
    print("\(error)")
    exit(1)
}
if let ev = sceneEV { viewer.body.sceneEV = ev }
if let c = cells { viewer.cellsPerExposure = c }
if let i = lensChoice {
    while viewer.body.lensIndex != i % lensBag.count { viewer.body.nextLens() }
    viewer.resetView()
}
if let n = apertureChoice {
    let stops = viewer.body.lens.apertureStops
    viewer.body.apertureIndex = stops.enumerated().min(by: { abs($0.1 - n) < abs($1.1 - n) })!.offset
}
if let i = filmChoice { viewer.body.stockIndex = i % filmStocks.count }
if pinhole { viewer.setBenchLens(false) }
if demoLights { viewer.demoLights() }
if lightingMode { viewer.startLighting() }
// Start with the shutter matched to the scene, as a photographer would.
viewer.body.meterShutter(sceneLuminance: 0.18)
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
let hud = ViewfinderHUD(frame: view.bounds)
hud.autoresizingMask = [.width, .height]
view.addSubview(hud)
viewer.hud = hud
let sheet = ContactSheetView(frame: view.bounds)
sheet.autoresizingMask = [.width, .height]
sheet.isHidden = true
view.addSubview(sheet)
viewer.sheet = sheet
window.center()
window.makeKeyAndOrderFront(nil)

viewer.onStats = { line in
    print(line)
}
if bench > 0 {
    viewer.benchFrames = bench
    viewer.onBenchDone = { report in
        print(report)
        exit(0)
    }
}

if let p = shootPath {
    var saved = 0
    viewer.onSaved = { path in
        print("Saved \(path)")
        saved += 1
        if saved == burst { exit(0) }
    }
    for k in 0..<burst {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(k)) {
            let url = URL(fileURLWithPath: p)
            viewer.scriptedPath = burst == 1 ? url
                : url.deletingPathExtension().appendingPathExtension("\(k + 1).png")
            viewer.releaseShutter()
            viewer.scriptedPath = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
