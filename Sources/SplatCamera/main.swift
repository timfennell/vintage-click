import AppKit
import CSpirula
import Foundation
import UniformTypeIdentifiers
import simd
import MetalKit

// Splat Camera: a 1970s 35 mm SLR in a 3DGS scan.
// From Finder it asks for a scene (or opens a .ply dropped on it). From a shell:
//   SplatCamera [model.ply] [--inside] [--ev 12] [--res 1620x1080] [--fps 24] [--scale M_PER_UNIT]
//               [--cells 32] [--lens I] [--aperture F] [--film I] [--photo-res WxH]
//               [--bench FRAMES] [--pinhole] [--shoot out.png] [--demo-lights] ...

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
let sceneRadius = option("--scene-radius").flatMap { Float($0) }
// --inside: the scan is a place to stand in (start in the middle, eye height).
var inside = args.contains("--inside")
args.removeAll { $0 == "--inside" }
// --burst N: fire N frames a second apart while the finder keeps running.
let burst = Int(option("--burst") ?? "1") ?? 1
let photoRes = option("--photo-res").map { $0.split(separator: "x").compactMap { Int($0) } }
var sceneScale = option("--scale").flatMap { Float($0) }
var sceneEV = option("--ev").flatMap { Float($0) }
let cells = option("--cells").flatMap { Int($0) }
let lensChoice = option("--lens").flatMap { Int($0) }
let apertureChoice = option("--aperture").flatMap { Float($0) }
let filmChoice = option("--film").flatMap { Int($0) }
let openSheet = args.contains("--sheet")
args.removeAll { $0 == "--sheet" }
// --house night|dusk|...: the scan's own light to start with.
let house = option("--house")
let meterWait = Double(option("--meter-wait") ?? "1.5") ?? 1.5
// --comp STOPS: exposure compensation off the meter for scripted shots (-4 = 4 stops under).
let comp = Int(option("--comp") ?? "0") ?? 0
let flyLight = option("--fly").flatMap { Int($0) }
let focusChoice = option("--focus").flatMap { Float($0) }
// --turn YAW,PITCH (degrees, right and up): aim the camera for scripted checks.
let turn = option("--turn").map { $0.split(separator: ",").compactMap { Float($0) } }
let noShadows = args.contains("--no-shadows")
args.removeAll { $0 == "--no-shadows" }
// --menu / --controls: open with the game menu or the controls guide up (for checks).
let startMenu = args.contains("--menu"), startControls = args.contains("--controls")
let startFilm = args.contains("--film-menu")
let measureDemo = args.contains("--measure-demo")
args.removeAll { $0 == "--measure-demo" }
args.removeAll { $0 == "--menu" || $0 == "--controls" || $0 == "--film-menu" }
let lightingMode = args.contains("--lighting-mode")
args.removeAll { $0 == "--lighting-mode" }
let demoLights = args.contains("--demo-lights")
args.removeAll { $0 == "--demo-lights" }
let pinhole = args.contains("--pinhole")
args.removeAll { $0 == "--pinhole" }
// Play at a film cadence (18-24 fps feels like film); the bench runs uncapped.
let filmFPS = bench > 0 ? 0 : Double(option("--fps") ?? "24") ?? 24
// macOS adds -psn_... when launched from Finder; only real paths count.
let cliPath = args.first(where: { !$0.hasPrefix("-") })

// --guess FILE: print what the chooser would guess for a scan, quit.
if let i = args.firstIndex(of: "--guess"), i + 1 < args.count {
    let k = SceneKind.guess(args[i + 1])
    print("\(args[i + 1]): \(k.place ? "a place" : "an object"), EV \(Int(k.ev))")
    exit(0)
}

// --photometry OUT.csv: trace every head, print its beams, write the curves, quit.
if let i = args.firstIndex(of: "--photometry"), i + 1 < args.count {
    var csv = "head,setting,theta_deg,green_cd,red_cd,blue_cd\n"
    for (h, kit) in lightKit.enumerated() {
        let t0 = CACurrentMediaTime()
        let tables = Photometry.tablesFor(h)
        print(String(format: "%@ (traced in %.1f s)", kit.name, CACurrentMediaTime() - t0))
        for (name, spot) in [("flood", Float(0)), ("mid", 0.5), ("spot", 1)] {
            let b = Photometry.table(head: h, spot: spot)
            let centre = b.centre, peak = b.peak
            print(String(format: "  %-5@ peak %7.0f cd  centre/peak %.2f  hot %4.1f°  beam %4.1f°  field %4.1f°",
                         name, peak, centre / max(peak, 1), b.angle(at: 0.9), b.angle(at: 0.5), b.angle(at: 0.1)))
            for t in 0..<BeamTable.thetaBins {
                var g: Float = 0, r: Float = 0, bl: Float = 0
                for p in 0..<BeamTable.phiBins {
                    let v = b.cd[t * BeamTable.phiBins + p] / Float(BeamTable.phiBins)
                    r += v.x; g += v.y; bl += v.z
                }
                csv += "\(kit.name),\(name),\(BeamTable.theta(Float(t)) * 180 / .pi),\(g),\(r),\(bl)\n"
            }
        }
        _ = tables
    }
    try? csv.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
    quit()
}

// Trace the light heads' optics in the background while the scan loads.
for head in lightKit.indices { DispatchQueue.global(qos: .userInitiated).async { _ = Photometry.tablesFor(head) } }

/// Exit, after the renderer has stopped (never mid-render), and without C++
/// teardown: the GPU device's destructors racing a render crashed the app.
func quit(_ code: Int32 = 0) -> Never {
    viewer?.loop.shutdown()
    UserDefaults.standard.synchronize()
    fflush(stdout)
    // Profiling reports at teardown; with the render thread stopped it is safe then.
    if ProcessInfo.processInfo.environment["SS_PROFILE"] != nil { exit(code) }
    _exit(code)
}

// AppKit would treat leftover arguments ("15" after --ev) as documents to open.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Exposures develop at their own (higher) resolution: twice the finder by default.
let photo = photoRes.map { ($0[0], $0[1]) } ?? (res[0] * 2, res[1] * 2)

/// Loads the scan and hands it to the renderer. The CPU copy lives only in
/// here, so its gigabytes are freed once the GPU has it.
func makeViewer(_ plyPath: String) -> Viewer {
    print("Loading \(plyPath)")
    let t0 = CACurrentMediaTime()
    let model: SplatModel
    do { model = try loadPLY(URL(fileURLWithPath: plyPath)) } catch {
        print("Cannot load the model: \(error)")
        DispatchQueue.main.sync {
            let a = NSAlert()
            a.messageText = "Cannot open \((plyPath as NSString).lastPathComponent)"
            a.informativeText = "\(error)"
            a.runModal()
        }
        exit(1)
    }
    print(String(format: "%d splats, SH degree %d, read in %.1f s", model.count, model.shDegree,
                 CACurrentMediaTime() - t0))
    // Scans have no scale: --scale (metres per unit) or --scene-radius (metres)
    // says how big it is; an object is a 60 cm still life, a place 30 m across.
    let radius = model.bounds().radius
    let scale = sceneScale ?? (sceneRadius ?? (inside ? 15 : 0.3)) / radius
    do {
        return try Viewer(model: model, width: res[0], height: res[1], photo: photo,
                          metresPerUnit: scale, inside: inside)
    } catch {
        print("\(error)")
        exit(1)
    }
}

var viewer: Viewer!
var window: NSWindow!

/// Opens the window with a loading note, loads the scan off the main thread,
/// then puts the camera in your hands.
func startSession(_ plyPath: String) {
    let screen = NSScreen.main!.visibleFrame
    let fit = min(1, min(screen.width * 0.9 / CGFloat(res[0]), screen.height * 0.9 / CGFloat(res[1])))
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(res[0]) * fit, height: CGFloat(res[1]) * fit),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Splat Camera — \((plyPath as NSString).deletingLastPathComponent.split(separator: "/").last ?? "")/\((plyPath as NSString).lastPathComponent)"
    window.contentAspectRatio = NSSize(width: res[0], height: res[1])
    window.backgroundColor = .black
    let note = NSTextField(labelWithString: "Loading the scan…  (a big place takes a minute)")
    note.textColor = NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 1)
    note.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
    note.translatesAutoresizingMaskIntoConstraints = false
    let holder = NSView()
    holder.addSubview(note)
    NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                                 note.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
    window.contentView = holder
    window.center()
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.global(qos: .userInitiated).async {
        let v = makeViewer(plyPath)
        DispatchQueue.main.async {
            viewer = v
            configureSession()
        }
    }
}

func configureSession() {
    if let ev = sceneEV { viewer.body.sceneEV = ev }
    if let c = cells { viewer.cellsOverride = c }
    if args.contains("--dng") { viewer.negativeOverride = true }
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
    if noShadows { viewer.loop.shadowsOn = false }
    // Places are scanned in their own light; objects on the rig are lit from the camera.
    viewer.loop.daylightScan = inside || args.contains("--daylight-scan")
    args.removeAll { $0 == "--daylight-scan" }
    if let h = house { viewer.lighting.setHouseLights(h) }
    if lightingMode || flyLight != nil { viewer.startLighting() }
    if let k = flyLight { viewer.flyLight(k - 1) }
    if let m = focusChoice { viewer.body.focusM = m }
    DispatchQueue.main.async {
        if startMenu { viewer.openMenu() }
        if startControls { viewer.showControls() }
        if startFilm { viewer.openFilm() }
        if measureDemo { viewer.measureDemo() }
    }
    if let t = turn, t.count == 2 {
        viewer.camera.yaw -= t[0] * .pi / 180
        viewer.camera.pitch += t[1] * .pi / 180
    }
    if openSheet { DispatchQueue.main.async { viewer.openSheet() } }
    // Start with the shutter matched to the scene, as a photographer would.
    viewer.body.meterShutter(sceneLuminance: 0.18)
    print("Uploaded to the GPU")

    // The window shows the fixed-size render scaled to fit.
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
    viewer.attachInput(to: view)
    window.acceptsMouseMovedEvents = true
    let sheet = ContactSheetView(frame: view.bounds)
    sheet.autoresizingMask = [.width, .height]
    sheet.isHidden = true
    view.addSubview(sheet)
    viewer.sheet = sheet
    let menu = MenuOverlay(frame: view.bounds)
    menu.autoresizingMask = [.width, .height]
    menu.isHidden = true
    view.addSubview(menu)
    viewer.menu = menu
    viewer.sceneIsPlace = inside
    viewer.onScaleSet = { scale in
        // Remember it with the file, so it opens this size next time.
        let path = currentScene?.path ?? cliPath
        guard let path else { return }
        var k = SceneKind.remembered(path) ?? SceneKind(place: inside, ev: sceneEV ?? 12)
        k.scale = scale
        k.remember(path)
    }
    viewer.onSwitchKind = {
        // Remember the other answer for this file and reopen it that way.
        let path = currentScene?.path ?? cliPath
        guard let path else { return }
        var k = SceneKind.remembered(path) ?? SceneKind(place: inside, ev: sceneEV ?? 12)
        k.place.toggle()
        k.scale = nil          // a measured size belonged to the other reading
        k.ev = k.place ? max(k.ev, 15) : 12
        k.remember(path)
        delegate.relaunch(with: path)
    }
    viewer.appActions = (openScene: { delegate.relaunch(with: nil) },
                         chooseRolls: { delegate.chooseRollsFolder(nil) },
                         quit: { quit() })

    viewer.onStats = { line in
        print(line)
    }
    if bench > 0 {
        viewer.benchFrames = bench
        viewer.onBenchDone = { report in
            print(report)
            quit()
        }
    }

    if let p = shootPath {
        viewer.scripted = true
        var saved = 0
        viewer.onSaved = { path in
            print("Saved \(path)")
            saved += 1
            if saved == burst { quit() }
        }
        // Let the finder run a while, so the meter has read the scene.
        let wait = meterWait
        for k in 0..<burst {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + Double(k)) {
                if wait > 1.5 { viewer.meterNow() }
                if comp != 0 { viewer.body.changeShutter(-comp) }
                let url = URL(fileURLWithPath: p)
                viewer.scriptedPath = burst == 1 ? url
                    : url.deletingPathExtension().appendingPathExtension("\(k + 1).png")
                viewer.releaseShutter()
                viewer.scriptedPath = nil
            }
        }
    }
}

// MARK: choosing a scene

/// How a scan was made: an object on the rig (lit from the camera) or a place,
/// and how bright its light was. Remembered per file.
struct SceneKind {
    var place: Bool
    var ev: Float
    /// Metres per scene unit, once measured (otherwise from place/object).
    var scale: Float?

    static func remembered(_ path: String) -> SceneKind? {
        guard let d = UserDefaults.standard.dictionary(forKey: "scene:" + path) else { return nil }
        return SceneKind(place: d["place"] as? Bool ?? false, ev: Float(d["ev"] as? Double ?? 12),
                         scale: (d["scale"] as? Double).map(Float.init))
    }
    /// A guess from the scan's shape, from a quick sample of the file: a place
    /// is dominated by its ground (flat: its thinnest spread a small share of
    /// its widest; the skate park 0.06), an object on the rig is a rounder blob
    /// (the bee 0.26). Places get bright sun, objects shade.
    static func guess(_ path: String) -> SceneKind {
        guard let flat = flatness(path) else { return SceneKind(place: false, ev: 12) }
        return flat < 0.15 ? SceneKind(place: true, ev: 15) : SceneKind(place: false, ev: 12)
    }

    private static func flatness(_ path: String) -> Float? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              let end = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var n = 0, props: [String] = [], inVertex = false
        for line in header.split(separator: "\n") {
            let w = line.split(separator: " ")
            if w.first == "element" { inVertex = w.count > 2 && w[1] == "vertex"; if inVertex { n = Int(w[2]) ?? 0 } }
            else if w.first == "property", inVertex, w.count == 3 { props.append(String(w[2])) }
        }
        guard n > 100, let ix = props.firstIndex(of: "x"), let iy = props.firstIndex(of: "y"),
              let iz = props.firstIndex(of: "z") else { return nil }
        let stride = props.count * 4, body = end.upperBound
        var pts: [SIMD3<Float>] = []
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: body)
            let step = max(1, n / 20000)
            for i in Swift.stride(from: 0, to: n, by: step) {
                let v = base.advanced(by: i * stride)
                pts.append(SIMD3(v.loadUnaligned(fromByteOffset: ix * 4, as: Float.self),
                                 v.loadUnaligned(fromByteOffset: iy * 4, as: Float.self),
                                 v.loadUnaligned(fromByteOffset: iz * 4, as: Float.self)))
            }
        }
        // Trim the far tail (floaters), then the spread along the principal axes.
        let c = pts.reduce(SIMD3<Float>(repeating: 0), +) / Float(pts.count)
        let d = pts.map { simd_distance($0, c) }.sorted()
        let cut = d[Int(Float(d.count - 1) * 0.9)]
        var cov = simd_float3x3(0)
        var m = 0
        for p in pts where simd_distance(p, c) <= cut {
            let q = p - c
            cov += simd_float3x3(columns: (q * q.x, q * q.y, q * q.z))
            m += 1
        }
        cov = cov * (1 / Float(max(m, 1)))
        // Eigenvalues of a symmetric 3x3 (Jacobi sweeps).
        var a = cov
        for _ in 0..<12 {
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                let apq = a[q][p]
                if abs(apq) < 1e-12 { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * apq)
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
                let cs = 1 / sqrt(t * t + 1), sn = t * cs
                var r = matrix_identity_float3x3
                r[p][p] = cs; r[q][q] = cs; r[q][p] = sn; r[p][q] = -sn
                a = r.transpose * a * r
            }
        }
        let ev = [a[0][0], a[1][1], a[2][2]].sorted()
        return ev[2] > 0 ? ev[0] / ev[2] : nil
    }

    func remember(_ path: String) {
        var d: [String: Any] = ["place": place, "ev": Double(ev)]
        if let scale { d["scale"] = Double(scale) }
        UserDefaults.standard.set(d, forKey: "scene:" + path)
        UserDefaults.standard.set(path, forKey: "lastScene")
    }
}

private let evChoices: [(String, Float)] = [("Indoors / room light (EV 9)", 9), ("Shade or overcast (EV 12)", 12),
                                            ("Bright sun (EV 15)", 15)]

/// The two questions, as popups for a panel or an alert.
/// The popups, how to read them, and how to set them (for a newly chosen file).
func kindAccessory(_ k: SceneKind) -> (NSView, () -> SceneKind, (SceneKind) -> Void) {
    let kind = NSPopUpButton()
    kind.addItems(withTitles: ["An object (scanned on the rig, lit from the camera)", "A place to stand in"])
    kind.selectItem(at: k.place ? 1 : 0)
    let light = NSPopUpButton()
    light.addItems(withTitles: evChoices.map(\.0))
    light.selectItem(at: evChoices.firstIndex(where: { $0.1 == k.ev }) ?? 1)
    let grid = NSGridView(views: [[NSTextField(labelWithString: "This scan is:"), kind],
                                  [NSTextField(labelWithString: "Its light was:"), light]])
    grid.rowSpacing = 8
    grid.frame = NSRect(x: 0, y: 0, width: 520, height: 64)
    return (grid, { SceneKind(place: kind.indexOfSelectedItem == 1, ev: evChoices[light.indexOfSelectedItem].1) },
            { k in
                kind.selectItem(at: k.place ? 1 : 0)
                light.selectItem(at: evChoices.firstIndex(where: { $0.1 == k.ev }) ?? 1)
            })
}

final class PanelWatcher: NSObject, NSOpenSavePanelDelegate {
    let changed: (URL) -> Void
    init(_ changed: @escaping (URL) -> Void) { self.changed = changed }
    func panelSelectionDidChange(_ sender: Any?) {
        if let url = (sender as? NSOpenPanel)?.url, url.pathExtension.lowercased() == "ply" { changed(url) }
    }
}

/// The scene being shown and how it was taken (for switching it from the menu).
var currentScene: (path: String, kind: SceneKind)?

func begin(_ path: String, _ k: SceneKind) {
    var k = k
    if k.scale == nil { k.scale = SceneKind.remembered(path)?.scale }
    k.remember(path)
    currentScene = (path, k)
    if let s = k.scale { sceneScale = sceneScale ?? s }
    inside = k.place
    sceneEV = sceneEV ?? k.ev
    startSession(path)
}

/// From Finder: pick a .ply (and say what it is).
func chooseScene() {
    let panel = NSOpenPanel()
    panel.title = "Choose a 3DGS scan"
    panel.message = "A Gaussian splat .ply (as trained, with or without SH)"
    panel.allowedContentTypes = [UTType(filenameExtension: "ply") ?? .data]
    if let last = UserDefaults.standard.string(forKey: "lastScene") {
        panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
    }
    let (view, read, set) = kindAccessory(SceneKind(place: false, ev: 12))
    panel.accessoryView = view
    panel.isAccessoryViewDisclosed = true
    // Choosing a file fills in its answers: as last time, or a guess from its shape.
    let watcher = PanelWatcher { url in set(SceneKind.remembered(url.path) ?? SceneKind.guess(url.path)) }
    panel.delegate = watcher
    guard panel.runModal() == .OK, let url = panel.url else { exit(0) }
    begin(url.path, read())
}

/// A .ply dropped on the app or double-clicked: ask only if it is new.
func open(_ path: String) {
    if let k = SceneKind.remembered(path) { begin(path, k); return }
    let alert = NSAlert()
    alert.messageText = "What is \((path as NSString).lastPathComponent)?"
    let (view, read, _) = kindAccessory(SceneKind.guess(path))
    alert.accessoryView = view
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }
    begin(path, read())
}

// MARK: the app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var opened = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { quit() }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Started from a shell with a scene: that scene (and its flags) is the one;
        // AppKit also hands over command-line words as files, which are not.
        if cliPath != nil { return true }
        guard !opened else { relaunch(with: filename); return true }
        opened = true
        DispatchQueue.main.async { open(filename) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        // Give a Finder "open with" a moment to arrive before asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !self.opened else { return }
            self.opened = true
            if let p = cliPath { startSession(p) } else { chooseScene() }
        }
    }

    /// Another scene: start afresh (the renderer holds one scene per process).
    func relaunch(with path: String?) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        if let path, let k = SceneKind.remembered(path) {
            config.arguments = [path, "--ev", String(k.ev)] + (k.place ? ["--inside"] : [])
                + (k.scale.map { ["--scale", String($0)] } ?? [])
        } else if let path {
            config.arguments = [path]
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func openScene(_ sender: Any?) { relaunch(with: nil) }

    /// Where developed rolls go (each roll its own folder inside).
    @objc func chooseRollsFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Where should rolls be kept?"
        panel.message = "Each roll gets its own folder here: frames as PNG, with how each was taken."
        panel.prompt = "Keep Rolls Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = ContactSheetView.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "rollsFolder")
    }

    @objc func showRolls(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: ContactSheetView.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ContactSheetView.root)
    }

    @objc func showControls(_ sender: Any?) { viewer?.showControls() }

    func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Splat Camera", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Splat Camera", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Splat Camera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Scene…", action: #selector(openScene(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Choose Where Rolls Are Kept…", action: #selector(chooseRollsFolder(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Show Rolls in Finder", action: #selector(showRolls(_:)), keyEquivalent: "r").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Controls", action: #selector(showControls(_:)), keyEquivalent: "?").target = self
        helpItem.submenu = helpMenu
        NSApp.mainMenu = main
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
