import AppKit
import CSpirula
import Foundation
import MetalKit
import simd

/// The camera body in your hands: reads the controls, shows the newest finder
/// frame on the focusing screen at a film cadence, and fires the shutter. The
/// mirror blacks out the finder for the exposure; the frame itself is exposed
/// and developed by the render loop in the background, so you keep shooting.
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

final class Viewer: NSObject, MTKViewDelegate {
    let width: Int, height: Int
    let device: MTLDevice
    let loop: RenderLoop
    private let queue: MTLCommandQueue
    private let finderPSO: MTLRenderPipelineState
    private let meterPSO: MTLComputePipelineState
    private let flarePSO: MTLComputePipelineState
    private let flareVisBuf: MTLBuffer
    /// How much of each flaring light the camera saw in the last frame (eased).
    private var flareVis: [Float] = []
    private let wirePSO: MTLRenderPipelineState
    private let meterBuf: MTLBuffer
    private let probePSO: MTLComputePipelineState
    private let probeBuf: MTLBuffer
    /// The surface point under the crosshair (scene units), from the last finder frame.
    private var crosshairHit: SIMD3<Float>?

    /// Setting the scale by measuring: two points on the scan, then their real distance.
    enum MeasureStep { case first, second(SIMD3<Float>), entry(SIMD3<Float>, SIMD3<Float>) }
    private(set) var measure: MeasureStep?
    private var entryText = ""
    private var entryValue: Float = 1
    private var entryUnit = 2
    static let units: [(name: String, metres: Float)] = [("mm", 0.001), ("cm", 0.01), ("m", 1), ("in", 0.0254), ("ft", 0.3048)]
    /// A new scale was set (metres per scene unit): main remembers it for the file.
    var onScaleSet: ((Float) -> Void)?
    private static let meterGrid = (48, 32)
    private static let maxPending = 4

    var camera = FlyCamera()
    var body = CameraBody()
    private var home = FlyCamera()
    private let center: SIMD3<Float>
    private let radius: Float
    private lazy var input = GamepadInput()   // made on the main thread, at the first frame
    private var meterLum: Float = 0.18
    private var lastFinderKey = ""
    /// Which page of the game menu is showing.
    private enum MenuPage { case main, bag, lights, scene, photos, settings, finder }
    private var menuPage = MenuPage.main
    /// A refined frame eases in over the shells frame it replaces: that frame, held, and when the fade began.
    private var fadeFrom: (buf: MTLBuffer, off: Int, slot: Int)?
    private var fadeStart = 0.0
    private var shownSlot: (buf: MTLBuffer, off: Int, slot: Int)?
    static let fadeTime = 0.25
    private var lastFinderAsk = 0.0
    /// How bright (in the finder's light) a point must be for an effect filter
    /// to throw spikes or a halo: well above the scene's average. Photos use the
    /// same, so what stars in the finder stars on film.
    private var filterThreshold: Float { min(0.95, max(0.35, meterLum * 5)) }
    /// The eye's adaptation to a dark finder: gain that eases toward the
    /// metered level over a second or two (film sees the true exposure).
    private var finderGain: Float = 1
    private var tables: [String: [SIMD4<Float>]] = [:]
    private var lensOn = true
    private var displayFrame = 0
    private var mirrorUpUntil = 0.0
    var hud: ViewfinderHUD?
    var sheet: ContactSheetView?
    var wall: PrintWallView?
    var menu: MenuOverlay?
    /// The app's own jobs, wired by main: another scene, where rolls go, quit.
    var appActions: (openScene: () -> Void, chooseRolls: () -> Void, quit: () -> Void)?
    /// The scan's kind, and switching it (reopens the scene the other way).
    var sceneIsPlace = false
    var onSwitchKind: (() -> Void)?
    /// The scan's light changed in the menu: remember it with the file.
    var onSceneLight: ((Float) -> Void)?
    /// The scan's own middle tone (linear), measured when it loaded.
    private(set) var middleTone: Float = 0.18
    private var menuOpen = false
    private var menuStick: Float = 0
    private var focusTurned: Float = 0
    private var filmStickX: Float = 0

    /// What the controls are doing: the camera, placing lights, or the contact sheet.
    enum Mode { case camera, lighting, sheet }
    /// Flying a light only belongs to lighting: leaving it (by any way, the
    /// light table included) puts you back behind the camera, focusing aids and all.
    private(set) var mode = Mode.camera { didSet { if mode != .lighting { pov = nil } } }
    var lighting = LightingPlot()
    /// The light being flown (seen from), if any, and the view from its lens.
    private(set) var pov: Int?
    private var lightCam = FlyCamera()
    private var lastPointer: CGPoint?
    /// Keyboard and mouse share the pad's input (the view takes the mouse).
    func attachInput(to view: NSView) { input.view = view }

    /// Sub-pupils per exposure: more = truer bokeh, longer to develop.
    /// One run's values from the command line (tests), never saved as preferences.
    var cellsOverride: Int?
    var negativeOverride: Bool?
    var cellsPerExposure: Int {
        get { cellsOverride ?? max(8, UserDefaults.standard.integer(forKey: "subPupils").nonZero ?? 32) }
        set { UserDefaults.standard.set(newValue, forKey: "subPupils") }
    }
    /// Photos at this many times the finder's size (2: 3240 x 2160 ... 4: 6480 x 4320).
    var photoScale: Int {
        get { min(4, max(1, UserDefaults.standard.integer(forKey: "photoScale").nonZero ?? 2)) }
        set { UserDefaults.standard.set(newValue, forKey: "photoScale") }
    }
    /// Keep a digital negative (a high-dynamic-range DNG) with every print.
    var keepNegative: Bool {
        get { negativeOverride ?? UserDefaults.standard.bool(forKey: "keepNegative") }
        set { UserDefaults.standard.set(newValue, forKey: "keepNegative") }
    }
    var filmFPS: Double = 24
    /// Scripted runs: where the next developed frame goes, and who to tell.
    var scriptedPath: URL?
    /// The scan on the stage, for the enlarger's records.
    var scenePath: String?
    /// Proofs at the shutter, prints from the enlarger (else full prints at once).
    var proofsAtShutter: Bool {
        get { proofOverride ?? (!scripted && (UserDefaults.standard.object(forKey: "proofsAtShutter") as? Bool ?? true)) }
        set { UserDefaults.standard.set(newValue, forKey: "proofsAtShutter") }
    }
    var proofOverride: Bool?
    /// VC_SHELL_M: the near region's radius in metres, for tests.
    static let shellMetres = ProcessInfo.processInfo.environment["VC_SHELL_M"].flatMap(Float.init)
    /// The finder draws far splats from baked shells (places only).
    var distantShells: Bool {
        get { ProcessInfo.processInfo.environment["VC_SHELLS"] != "0"
              && (UserDefaults.standard.object(forKey: "distantShells") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "distantShells") }
    }
    /// Frames waiting for the enlarger (fed to the darkroom one at a time).
    private var enlargeQueue: [URL] = []
    private var enlargeTotal = 0, enlargeDone = 0
    /// Scripted runs ignore the controls (a pad left on the desk must not move the camera).
    var scripted = false
    var onSaved: ((String) -> Void)?

    // Timing (finder renders, which is what the GPU can keep up with)
    private var statStart = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()
    private var statRender: [Double] = []
    private var statsLine = ""
    /// Render speed above the frame: only when asked for (--stats).
    static let showStats = CommandLine.arguments.contains("--stats")
    var onStats: ((String) -> Void)?

    // Scripted benchmark: orbit for `benchFrames` finder renders, then report.
    var benchFrames = 0
    private var benchCount = 0
    private var benchRender: [Double] = []
    private var benchStart = 0.0
    var onBenchDone: ((String) -> Void)?

    private let inside: Bool
    private var standingSpot: (position: SIMD3<Float>, yaw: Float)?

    init(model: SplatModel, width: Int, height: Int, photo: (Int, Int), metresPerUnit: Float,
         inside: Bool = false) throws {
        self.inside = inside

        self.width = width
        self.height = height
        let b = model.bounds()
        center = b.center
        radius = b.radius
        if inside {
            standingSpot = Self.findOpenSpot(model, centre: b.center, radius: b.radius,
                                             metresPerUnit: metresPerUnit, up: FlyCamera().up)
        }
        loop = try RenderLoop(model: model, finder: (width, height), photo: photo,
                              background: [0.08, 0.08, 0.09, 1])
        device = loop.device
        queue = device.makeCommandQueue()!
        meterBuf = device.makeBuffer(length: Self.meterGrid.0 * Self.meterGrid.1 * 4,
                                     options: .storageModeShared)!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "fullscreen")
        pd.fragmentFunction = lib.makeFunction(name: "viewfinder")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        finderPSO = try device.makeRenderPipelineState(descriptor: pd)
        let wd = MTLRenderPipelineDescriptor()
        wd.vertexFunction = lib.makeFunction(name: "wire_vertex")
        wd.fragmentFunction = lib.makeFunction(name: "wire_fragment")
        wd.colorAttachments[0].pixelFormat = .bgra8Unorm
        wd.colorAttachments[0].isBlendingEnabled = true
        // Added light, not paint: the wireframes are projected into the finder.
        wd.colorAttachments[0].sourceRGBBlendFactor = .one
        wd.colorAttachments[0].destinationRGBBlendFactor = .one
        wirePSO = try device.makeRenderPipelineState(descriptor: wd)
        meterPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "meter")!)
        probePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "probe")!)
        probeBuf = device.makeBuffer(length: 16, options: .storageModeShared)!
        flarePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "flare_probe")!)
        flareVisBuf = device.makeBuffer(length: 4 * Flare.maxLights, options: .storageModeShared)!
        super.init()

        body.metresPerUnit = metresPerUnit
        // Calibrate the scan against mid grey: its middle tone to 0.18.
        middleTone = model.middleTone()
        body.calibration = max(-4, min(4, log2(0.18 / middleTone)))
        print(String(format: "Calibrated against mid grey: the scan's middle tone %.3f, %+.2f stops", middleTone,
                     body.calibration))
        print(String(format: "Scene scale: %.4g m per unit (subject radius %.2f m); photos %dx%d",
                     body.metresPerUnit, radius * body.metresPerUnit, photo.0, photo.1))
        // A new session loads a new roll after the ones already in the darkroom.
        body.rollNumber = 1
        pickGait()
        loop.onFinderRendered = { [weak self] ms in self?.record(renderMs: ms) }
        loop.onDeveloped = { [weak self] job, image, seconds in self?.developed(job, image, seconds) }
        resetView()
    }

    // MARK: view

    func resetView() {
        let keepUp = camera.up
        camera = FlyCamera()
        camera.up = keepUp
        camera.focalMM = body.lens.focalMM
        // Back off far enough to frame the subject, beyond the lens's closest focus.
        let dist = max(radius * 1.2 * camera.focalMM / 36 + radius,
                       body.lens.minFocusM * 1.15 / body.metresPerUnit)
        var c = FlyCamera()   // yaw 0, pitch 0: looking along the horizon
        c.up = keepUp
        if inside {
            // Standing in the middle of the place at eye height, looking level.
            camera.position = center + keepUp * (1.6 / body.metresPerUnit)
            if let spot = standingSpot, keepUp == FlyCamera().up {
                camera.position = spot.position
                camera.yaw = spot.yaw
            }
            home = camera
            body.focusM = max(body.lens.minFocusM, 5)
            return
        }
        let eye = center - c.forward * dist + keepUp * radius * 0.35
        camera.lookAt(center, from: eye)
        home = camera
        body.focusM = max(body.lens.minFocusM, simd_distance(eye, center) * body.metresPerUnit)
    }

    /// Somewhere to stand in a scanned place: near the middle, at eye height
    /// above the ground there, nothing within arm's reach and a clear view of a
    /// few metres ahead (scans have no record of where the photographer stood).
    private static func findOpenSpot(_ m: SplatModel, centre: SIMD3<Float>, radius: Float,
                                     metresPerUnit: Float, up: SIMD3<Float>) -> (position: SIMD3<Float>, yaw: Float)? {
        let unit = 1 / metresPerUnit
        let stride = max(1, m.count / 400_000)
        var pts: [SIMD3<Float>] = []
        for i in Swift.stride(from: 0, to: m.count, by: stride) {
            pts.append(SIMD3(m.means[3 * i], m.means[3 * i + 1], m.means[3 * i + 2]))
        }
        var cam = FlyCamera()
        cam.up = up
        let a = cam.forward, b = simd_cross(up, a)
        var best: (score: Float, pos: SIMD3<Float>, yaw: Float)?
        for gx in -3...3 {
            for gy in -3...3 {
                let foot = centre + (a * Float(gx) + b * Float(gy)) * (radius * 0.12)
                // The ground: the lowest well-populated level within a metre around the spot.
                var heights: [Float] = []
                for p in pts {
                    let d = p - foot
                    let h = simd_dot(d, up)
                    let side = d - h * up
                    if simd_length_squared(side) < unit * unit { heights.append(h) }
                }
                guard heights.count > 30 else { continue }
                heights.sort()
                let ground = heights[heights.count / 20]
                let eye = foot + up * (ground + 1.6 * unit)
                var near = 0
                for p in pts where simd_distance_squared(p, eye) < 1.0 * unit * unit { near += 1 }
                for k in 0..<8 {
                    let yaw = Float(k) * .pi / 4
                    let f = cos(yaw) * a + sin(yaw) * b
                    var blocked = 0, seen = 0
                    for p in pts {
                        let d = p - eye
                        let along = simd_dot(d, f)
                        guard along > 0.3 * unit else { continue }
                        let off = simd_length(d - along * f)
                        if along < 4 * unit && off < 0.6 * unit { blocked += 1 }
                        if along < 25 * unit && off < along * 0.4 { seen += 1 }
                    }
                    let score = Float(near * 20 + blocked * 5) - Float(min(seen, 5000)) * 0.05
                    if best == nil || score < best!.score { best = (score, eye, yaw) }
                }
            }
        }
        return best.map { ($0.pos, $0.yaw) }
    }

    private func cycleUp() {
        let axes: [SIMD3<Float>] = [[0, -1, 0], [0, 0, 1], [0, 1, 0], [0, 0, -1], [1, 0, 0], [-1, 0, 0]]
        let i = axes.firstIndex(of: camera.up) ?? 0
        camera.up = axes[(i + 1) % axes.count]
        resetView()
    }

    private func table(_ b: CameraBody, _ n: Float) -> [SIMD4<Float>] {
        let key = "\(b.lensIndex)@\(n)"
        if let t = tables[key] { return t }
        let t = CameraBody.pupilTable(lens: b.lens, fNumber: n)
        tables[key] = t
        return t
    }

    func setBenchLens(_ on: Bool) { lensOn = on }

    // MARK: frame loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        if benchFrames > 0 { benchOrbit() } else if !scripted { handleInput(dt: dt) }

        // Looking at prints: the finder rests and the darkroom gets the GPU.
        if mode == .sheet {
            if let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
               let cb = queue.makeCommandBuffer() {
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
                present(cb, drawable)
                cb.commit()
            }
            sheet?.pending = (rollFolder(body), loop.pendingFrames(roll: body.rollNumber))
            return
        }

        // Ask for the next finder frame: from the camera, or from the light being flown
        // (a plain wide view down its beam: no lens to speak of, no focusing screen).
        let n = body.viewingAperture
        var job: FinderJob
        if pov != nil {
            job = (FinderJob(
                view: lightCam.viewMatrix, position: lightCam.position, fx: lightCam.focalPixels(width: width),
                lens: nil, body: body, lighting: lighting, fromLight: pov))
        } else {
            let fx = body.focalPixels(width: width, height: height)
            let carried = carriedCamera
            let fisheye = body.lens.isFisheye
            job = FinderJob(
                view: carried.viewMatrix, position: carried.position, fx: fx,
                lens: lensOn && !fisheye ? body.lensParams(
                    fNumber: n, focalPx: fx, cells: 1, table: table(body, n),
                    axis: SIMD2(Float(width), Float(height)) / 2 + body.axisOffset(width: width),
                    fieldRadius: simd_length(SIMD2(Float(width), Float(height))) / 2) : nil,
                body: body, lighting: lighting, fisheye: fisheye)
            // Distant splats from baked shells: in a place, up to a short tele
            // (longer lenses magnify the shells' parallax and texels).
            job.shells = distantShells && sceneIsPlace && body.lens.focalMM <= 85
            job.smoothBlur = !UserDefaults.standard.bool(forKey: "classicBlur")
        }
        loop.metresPerUnit = body.metresPerUnit
        loop.shellRadius = Self.shellMetres.map { $0 / body.metresPerUnit } ?? 4 / body.metresPerUnit
        // Render only a view that changed (or once a second, in case something
        // outside this key did): a still camera leaves the GPU to the darkroom.
        let key = "\(job.view)|\(job.fx)|\(job.lens ?? [])|\(job.fromLight ?? -1)|\(job.fisheye)|\(lighting)|\(body.sceneEV)|\(body.metresPerUnit)"
        if key != lastFinderKey || now - lastFinderAsk > 1 {
            job.refresh = key == lastFinderKey
            loop.requestFinder(job)
            lastFinderKey = key
            lastFinderAsk = now
        }

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        displayFrame += 1
        // Mirror up: no image reaches the screen while the shutter is open
        // (the frame and its glow go black); the finder's own readouts stay.
        let mirrorUp = now < mirrorUpUntil
        guard let frame = loop.acquireLatest() else {
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            present(cb, drawable)
            cb.commit()
            return
        }
        // Eyes adapt, but not all the way: night stays night in the finder,
        // and a dim interior looks dimmer than a sunlit street (the scene's
        // real light, EV 13 as the reference, felt about a third as strongly).
        let light = pow(2, (body.sceneEV + body.calibration - 13) * 0.35)
        let want = max(1, min(24, 0.06 / max(meterLum, 1e-6))) * max(0.2, min(1.6, light))
        finderGain *= pow(want / finderGain, min(1, Float(dt) * 0.8))
        var o = finderOptics(frame.job, seed: UInt32(displayFrame))
        o[5].y *= finderGain
        if mirrorUp { o[8].y = 1 }
        var f = frame.job.body.developed.packed

        let ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(meterPSO)
        ce.setBuffer(frame.buf, offset: frame.off, index: 0)
        ce.setBytes(&o, length: o.count * 16, index: 1)
        ce.setBuffer(meterBuf, offset: 0, index: 2)
        ce.dispatchThreads(MTLSize(width: Self.meterGrid.0, height: Self.meterGrid.1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        ce.setComputePipelineState(probePSO)
        ce.setBuffer(probeBuf, offset: 0, index: 2)
        ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        // Lens flare: which lights shine into the lens, and how much of each the camera sees.
        let fj = frame.job
        let size = SIMD2(Float(width), Float(height))
        let fAxis: SIMD2<Float> = size / 2 + fj.body.axisOffset(width: width)
        let sources: [Flare.Source] = fj.fromLight == nil
            ? Flare.sources(plot: fj.lighting, view: fj.view, position: fj.position, fx: fj.fx, axis: fAxis,
                            width: width, height: height, fisheye: fj.fisheye, body: fj.body,
                            fNumber: fj.body.viewingAperture) : []
        if !sources.isEmpty {
            var probes = Flare.probes(sources, diag: simd_length(SIMD2(Float(width), Float(height))))
            var count = UInt32(probes.count)
            ce.setComputePipelineState(flarePSO)
            ce.setBytes(&probes, length: probes.count * 16, index: 2)
            ce.setBuffer(flareVisBuf, offset: 0, index: 3)
            ce.setBytes(&count, length: 4, index: 4)
            ce.dispatchThreads(MTLSize(width: probes.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: probes.count, height: 1, depth: 1))
        }
        ce.endEncoding()
        if flareVis.count != sources.count { flareVis = [Float](repeating: 1, count: sources.count) }
        let seenNow: [Float] = mirrorUp ? [Float](repeating: 0, count: sources.count) : flareVis
        var flareRows = Flare.uniforms(sources, visibility: seenNow, lens: fj.body.lens, fNumber: fj.body.viewingAperture,
                                       filter: fj.body.filter,
                                       axisUV: fAxis / size, aspect: size.x / size.y)

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(finderPSO)
        enc.setFragmentBuffer(frame.buf, offset: frame.off, index: 0)
        enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
        enc.setFragmentBytes(&f, length: f.count * 16, index: 2)
        var m = meterUniforms()
        enc.setFragmentBytes(&m, length: m.count * 16, index: 3)
        enc.setFragmentTexture(meterTexture ?? blankTexture, index: 0)
        // A new frame: if it refines the one on show, hold that one and fade from it.
        if shownSlot?.slot != frame.slot {
            if frame.job.refined, let s = shownSlot {
                if let old = fadeFrom { loop.release(slot: old.slot) }
                loop.hold(slot: s.slot)
                fadeFrom = s
                fadeStart = now
            }
            shownSlot = (frame.buf, frame.off, frame.slot)
        }
        var fade: Float = 0
        if let from = fadeFrom {
            let t = (now - fadeStart) / Self.fadeTime
            if t >= 1 || from.slot == frame.slot {
                loop.release(slot: from.slot)
                fadeFrom = nil
            } else {
                fade = Float(1 - t)
                enc.setFragmentBuffer(from.buf, offset: from.off, index: 4)
            }
        }
        if fadeFrom == nil { enc.setFragmentBuffer(frame.buf, offset: frame.off, index: 4) }
        enc.setFragmentBytes(&fade, length: 4, index: 5)
        enc.setFragmentBytes(&flareRows, length: flareRows.count * 16, index: 6)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if !mirrorUp { drawWireframes(enc, frame: frame, optics: &o) }
        enc.endEncoding()
        present(cb, drawable)
        let loop = self.loop, slot = frame.slot, meter = meterBuf, probe = probeBuf
        // The centre ray of that frame: from its camera, along its view axis.
        let V = frame.job.view
        let eye = frame.job.position, axis = SIMD3<Float>(V[8], V[9], V[10])
        let fromCamera = frame.job.fromLight == nil
        let flareCount = sources.count, visBuf = flareVisBuf
        cb.addCompletedHandler { [weak self] _ in
            loop.release(slot: slot)
            let v = visBuf.contents().bindMemory(to: Float.self, capacity: Flare.maxLights)
            let seen = (0..<flareCount).map { v[$0] }
            DispatchQueue.main.async {
                guard let self, self.flareVis.count == seen.count else { return }
                for k in seen.indices { self.flareVis[k] += (seen[k] - self.flareVis[k]) * 0.5 }
            }
            let lum = Self.centreWeighted(meter)
            let p = probe.contents().bindMemory(to: Float.self, capacity: 2)
            let hit: SIMD3<Float>? = p[0] > 0 && fromCamera ? eye + axis * p[0] : nil
            DispatchQueue.main.async {
                self?.meterLum = lum
                self?.crosshairHit = hit
            }
        }
        cb.commit()
        updateHUD(mirrorUp: mirrorUp)
    }

    /// Optics for the focusing screen (layout in Shaders.swift).
    private func finderOptics(_ job: FinderJob, seed: UInt32) -> [SIMD4<Float>] {
        let b = job.body, l = b.lens
        var o: [SIMD4<Float>] = [
            SIMD4(Float(width), Float(height), job.fx, job.fx),
            SIMD4<Float>(lowHalf: SIMD2(Float(width), Float(height)) / 2 + b.axisOffset(width: width), highHalf: SIMD2(b.metresPerUnit, b.focusM)),
            SIMD4(l.focalMM / 1000, b.viewingAperture, l.maxAperture, Float(l.blades)),
            SIMD4(l.catsEye, l.soapBubble, l.bladeRotation, l.vignette),
            loop.background,
            // Stopping down for the depth-of-field preview darkens the screen.
            SIMD4(Float(height) * 0.065, pow(l.maxAperture / b.viewingAperture, 2) * exp2(-b.closeFocusLoss), Float(seed),
                  b.exposureStops),
            SIMD4(l.lateralCA, l.axialCA, l.projection == .circularFisheye ? Float(height) / 2 : 0, l.obstruction),
            Self.finderInset(width: width, height: height),
            SIMD4(l.squeeze, 0, 0, 0),
        ] + b.filter.optics(threshold: filterThreshold)
        if job.fromLight != nil {
            o.replaceSubrange(9...11, with: lensFilters[0].optics(threshold: 1))     // no filter on a light's view
            o[5].x = 0          // no focusing aids
            o[6].x = 0          // no lens colour
            o[3].w = 0
            o[2].y = l.maxAperture
        }
        return o
    }

    /// The camera on its tripod, for seeing where it is from a light.
    private func cameraWireframe(_ scale: Float) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let s = 1 / scale
        let p = camera.position, f = camera.forward, r = camera.right, u = -camera.down
        let w = 0.14 * s, h = 0.09 * s, d = 0.07 * s
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        let c: [(Float, Float, Float)] = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                                          (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
        let v = c.map { p + r * ($0.0 * w / 2) + u * ($0.1 * h / 2) + f * ($0.2 * d / 2) }
        for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
            segs.append((v[a], v[b]))
        }
        // The lens, and where it looks.
        let lc = p + f * (d / 2)
        for k in 0..<12 {
            let a0 = Float(k) / 12 * 2 * .pi, a1 = Float(k + 1) / 12 * 2 * .pi
            let e0: SIMD3<Float> = (r * cos(a0) + u * sin(a0)) * (h * 0.4)
            let e1: SIMD3<Float> = (r * cos(a1) + u * sin(a1)) * (h * 0.4)
            segs.append((lc + e0, lc + e1))
        }
        segs.append((lc, lc + f * (body.focusM / scale)))
        // Tripod legs down to the ground, about 1.5 m.
        for a in [0.0, 2.1, 4.2] as [Float] {
            let top: SIMD3<Float> = p - u * (h / 2)
            let spread: SIMD3<Float> = (r * cos(a) + f * sin(a)) * (0.35 * s)
            let foot: SIMD3<Float> = p - u * (1.5 * s) + spread
            segs.append((top, foot))
        }
        return segs
    }

    /// Where the finder's image sits in the window, as fractions: a 3:2 window
    /// inset in the black surround, room below for the LED readouts. The HUD
    /// lays out against the same rectangle.
    static let finderImage = (x: CGFloat(0.09), y: CGFloat(0.045), scale: CGFloat(0.82))

    // MARK: the meter in the finder

    private var meterTexture: MTLTexture?
    private var meterKey: ViewfinderHUD.MeterShape?
    private lazy var blankTexture: MTLTexture = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)!
    }()

    /// The meter for the finder's shader: where its scale and needle are, in
    /// drawable pixels, and its scale drawn (again only when it changes).
    private func meterUniforms() -> [SIMD4<Float>] {
        guard let hud, let shape = hud.meterShape, shape.bounds.width > 0 else { return [.zero, .zero, .zero] }
        let sx = CGFloat(width) / shape.bounds.width, sy = CGFloat(height) / shape.bounds.height
        let pr = shape.plateRect
        var still = shape
        still.tip = .zero
        if meterKey != still || meterTexture == nil {
            meterKey = still
            meterTexture = Self.drawMeterTexture(shape, sx: sx, sy: sy, device: device)
        }
        func px(_ p: NSPoint) -> SIMD2<Float> { SIMD2(Float(p.x * sx), Float(p.y * sy)) }
        return [SIMD4(Float(pr.minX * sx), Float(pr.minY * sy), Float(pr.width * sx), Float(pr.height * sy)),
                SIMD4(lowHalf: px(shape.pivot), highHalf: px(shape.tip)),
                SIMD4(1, Float(shape.u * sy), 0, 0)]
    }

    private static func drawMeterTexture(_ shape: ViewfinderHUD.MeterShape, sx: CGFloat, sy: CGFloat,
                                         device: MTLDevice) -> MTLTexture? {
        let pr = shape.plateRect
        let w = max(1, Int((pr.width * sx).rounded(.up))), h = max(1, Int((pr.height * sy).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flipped, in the HUD's points: the HUD draws the scale as it lays it out.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: sx, y: -sy)
        ctx.translateBy(x: -pr.minX, y: -pr.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ViewfinderHUD.drawPlate(shape)
        NSGraphicsContext.restoreGraphicsState()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: d), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }

    static func finderInset(width: Int, height: Int) -> SIMD4<Float> {
        let f = finderImage
        return SIMD4(Float(f.x) * Float(width), Float(f.y) * Float(height), Float(f.scale), Float(height) * 0.025)
    }

    /// The light heads as wireframes on the screen, over the frame they belong to.
    private func drawWireframes(_ enc: MTLRenderCommandEncoder,
                                frame: (buf: MTLBuffer, off: Int, slot: Int, job: FinderJob),
                                optics o: inout [SIMD4<Float>]) {
        let plot = frame.job.lighting
        let V = frame.job.view, fx = frame.job.fx
        let scale = frame.job.body.metresPerUnit
        var shapes: [(segs: [(SIMD3<Float>, SIMD3<Float>)], chosen: Bool)] = []
        let focusUnits = frame.job.body.focusM / scale
        for (i, light) in plot.lights.enumerated() where i != frame.job.fromLight {
            let chosen = mode == .lighting && i == plot.selected && frame.job.fromLight == nil
            let target = simd_distance(light.position, camera.position + camera.forward * focusUnits)
            shapes.append((light.wireframe(up: camera.up, metresPerUnit: scale, beamTo: chosen ? target : nil), chosen))
        }
        // Seen from a light, the camera is there too.
        if frame.job.fromLight != nil { shapes.append((cameraWireframe(scale), true)) }
        guard !shapes.isEmpty else { return }
        func cam(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(V[0] * p.x + V[1] * p.y + V[2] * p.z + V[3],
                  V[4] * p.x + V[5] * p.y + V[6] * p.z + V[7],
                  V[8] * p.x + V[9] * p.y + V[10] * p.z + V[11])
        }
        let near = 0.02 / scale
        // Where the render puts things: the same principal point, and through a
        // fisheye its equidistant projection (radius = f x angle off the axis).
        let fisheye = frame.job.fisheye && frame.job.fromLight == nil
        let centre = SIMD2(Float(width), Float(height)) / 2 + (frame.job.fromLight == nil ? frame.job.body.axisOffset(width: width) : .zero)
        func onScreen(_ q: SIMD3<Float>) -> SIMD2<Float> {
            if fisheye {
                let r = simd_length(SIMD2(q.x, q.y)), th = atan2(r, q.z)
                return centre + (r > 1e-9 ? SIMD2(q.x, q.y) / r : .zero) * (fx * th)
            }
            return centre + SIMD2(q.x, q.y) / q.z * fx
        }
        for (segs, chosen) in shapes {
            var verts: [SIMD4<Float>] = []
            for (a, b) in segs {
                var pa = cam(a), pb = cam(b)
                if fisheye {
                    // Straight edges bow through a fisheye: in short pieces, each kept
                    // while it is within the lens's field (a little past 90 degrees).
                    let n = 12
                    var prev: SIMD3<Float>? = nil
                    for i in 0...n {
                        let q = pa + (pb - pa) * (Float(i) / Float(n))
                        let ok = atan2(simd_length(SIMD2(q.x, q.y)), q.z) < 1.65 && simd_length(q) > near
                        if ok, let pq = prev {
                            for w in [pq, q] { let s2 = onScreen(w); verts.append(SIMD4(s2.x, s2.y, max(w.z, near) * scale, 1)) }
                        }
                        prev = ok ? q : nil
                    }
                    continue
                }
                if pa.z < near && pb.z < near { continue }
                // Clip to just in front of the lens.
                if pa.z < near { pa = pb + (pa - pb) * ((pb.z - near) / (pb.z - pa.z)) }
                if pb.z < near { pb = pa + (pb - pa) * ((pa.z - near) / (pa.z - pb.z)) }
                for q in [pa, pb] {
                    let s2 = onScreen(q)
                    verts.append(SIMD4(s2.x, s2.y, q.z * scale, 1))
                }
            }
            guard !verts.isEmpty,
                  let vb = device.makeBuffer(bytes: verts, length: verts.count * 16, options: .storageModeShared)
            else { continue }
            // Warm cream light, as framelines are; the light being placed a little brighter, warmer.
            let colour: SIMD4<Float> = chosen ? [1.0, 0.80, 0.55, 0.75] : [1.0, 0.92, 0.80, 0.42]
            enc.setRenderPipelineState(wirePSO)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: o.count * 16, index: 1)
            enc.setFragmentBuffer(frame.buf, offset: frame.off, index: 0)
            enc.setFragmentBytes(&o, length: o.count * 16, index: 1)
            // A faint wide glow, then the fine core.
            let segments = verts.count / 2
            for (half, gain) in [(Float(9), Float(0.16)), (Float(2.4), Float(1))] {
                var w = SIMD4<Float>(half * Float(height) / 1080, 0, 0, 0)
                var c = SIMD4<Float>(colour.x, colour.y, colour.z, colour.w * gain)
                enc.setVertexBytes(&w, length: 16, index: 2)
                enc.setFragmentBytes(&c, length: 16, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: segments * 6)
            }
        }
    }

    private func present(_ cb: MTLCommandBuffer, _ drawable: MTLDrawable) {
        // A film cadence wants even frame spacing: hold each frame for its
        // full 1/fps (24 fps lands on every 5th refresh of a 120 Hz display).
        if filmFPS > 0 && benchFrames == 0 {
            cb.present(drawable, afterMinimumDuration: 1 / filmFPS)
        } else {
            cb.present(drawable)
        }
    }

    private static func centreWeighted(_ buf: MTLBuffer) -> Float {
        let (gw, gh) = meterGrid
        let v = buf.contents().bindMemory(to: Float.self, capacity: gw * gh)
        var sum: Float = 0, wsum: Float = 0
        for y in 0..<gh {
            for x in 0..<gw {
                let u = (Float(x) + 0.5) / Float(gw) - 0.5, w2 = (Float(y) + 0.5) / Float(gh) - 0.5
                let w = 0.25 + exp(-(u * u + w2 * w2) / 0.03)   // centre-weighted
                sum += w * v[y * gw + x]
                wsum += w
            }
        }
        return sum / wsum
    }

    private func handleInput(dt: Float) {
        var entering = false
        if case .entry = measure { entering = true }
        input.keyMode = menuOpen ? .menu : entering ? .entry
            : (mode == .sheet ? .sheet : (mode == .lighting ? .lighting : .camera))
        let s = input.poll()
        let p = s.pressed
        if menuOpen {
            menuInput(s)
            return
        }
        if p.contains(.menu) {
            openMenu()
            return
        }
        if measure != nil {
            measureInput(s, dt: dt)
            return
        }
        if p.contains(.cycleUp) { cycleUp() }
        switch mode {
        case .sheet:
            sheetInput(s, dt: dt)
            return
        case .camera:
            let stop = body.apertureIndex
            if p.contains(.left) { body.changeAperture(-1) }
            if p.contains(.right) { body.changeAperture(1) }
            if body.apertureIndex != stop { Sounds.shared.play(.aperture, volume: 0.6) }
            let speed = body.shutterIndex
            if p.contains(.up) { body.changeShutter(1) }
            if p.contains(.down) { body.changeShutter(-1) }
            if body.shutterIndex != speed { Sounds.shared.play(.shutterDial, volume: 0.7) }
            if p.contains(.x) { openLenses() }
            if p.contains(.filters) { openFilters() }
            if p.contains(.y) { openFilm() }
            if p.contains(.l3) { changeGait(gait == Self.gaits.count - 1 ? -gait : 1) }
            body.dofPreview = s.bHeld
            let wasFocus = body.focusM
            body.turnFocus(s.triggers, dt: dt)
            // The wheel is the focus ring: away from you focuses farther.
            if s.wheel != 0 { body.focusM = max(body.lens.minFocusM, min(200, body.focusM * exp(s.wheel * 0.03))) }
            // The ring's grease and detents: a soft tick every so far of turn.
            focusTurned += abs(log(body.focusM / wasFocus))
            if focusTurned > 0.12 { focusTurned = 0; Sounds.shared.play(.focus, volume: 0.35) }
            // M + arrows tilt or shift a lens that can; N squares it up again.
            if s.movement != .zero {
                if body.move(s.movement * dt) {
                    hud?.flash(movementLabel)
                } else {
                    hud?.flash("THIS LENS DOES NOT TILT OR SHIFT")
                }
            }
            if s.centreMovement && (body.tilt != .zero || body.shift != .zero) {
                body.tilt = .zero
                body.shift = .zero
                hud?.flash(movementLabel)
            }
            // Number keys: that lens of the mounted lens's collection.
            if let d = s.digit, d >= 1, let shelf = lensCollections.firstIndex(where: { $0.name == body.lens.collection }) {
                let start = lensCollections.prefix(shelf).reduce(0) { $0 + $1.lenses.count }
                if d <= lensCollections[shelf].lenses.count { mount(start + d - 1) }
            }
        case .lighting:
            lightingInput(s, dt: dt)
            body.dofPreview = false
        }
        if p.contains(.view) { openSheet() }
        if p.contains(.r3) {
            mode = mode == .lighting ? .camera : .lighting
            pov = nil
        }
        if p.contains(.faster) { changeGait(1) }
        if p.contains(.slower) { changeGait(-1) }
        // The controls drive whichever you are looking through: the camera or a light,
        // at the chosen pace in real metres per second (Shift: three times that).
        let input = FlyInput(move: s.move, look: s.look, rise: s.shoulders, zoom: 0)
        let pace = Self.gaits[gait].metres / body.metresPerUnit * (s.run ? 3 : 1)
        camera.moveSpeed = pace
        lightCam.moveSpeed = pace
        stride(input, dt: dt, running: s.run)
        lighting.up = camera.up
        if let i = pov, lighting.lights.indices.contains(i) {
            lightCam.turn(s.mouseLook)
            lightCam.update(input, dt: dt)
            lighting.lights[i].position = lightCam.position
            lighting.lights[i].aim = lightCam.forward
        } else {
            camera.turn(s.mouseLook)
            camera.update(input, dt: dt)
        }
        camera.focalMM = body.lens.focalMM
        if mode == .camera && p.contains(.a) { releaseShutter() }
    }

    /// Lighting: choose a light and you see from it, down its beam, and the
    /// same controls fly and aim it. The camera waits where you left it.
    private func lightingInput(_ s: GamepadInput.State, dt: Float) {
        let p = s.pressed
        if p.contains(.gels) { openGels(); return }
        if p.contains(.modifiers) { openModifiers(); return }
        if p.contains(.flare) || p.contains(.view), !lighting.lights.isEmpty {
            let k = pov ?? min(lighting.selected, lighting.lights.count - 1)
            lighting.lights[k].flare = !lighting.lights[k].flareOn
            hud?.flash("LENS FLARE FROM LIGHT \(k + 1): \(lighting.lights[k].flareOn ? "ON" : "OFF")")
        }
        if p.contains(.patternFocus), !lighting.lights.isEmpty {
            let k = pov ?? min(lighting.selected, lighting.lights.count - 1)
            let steps: [Float] = [0, 0.25, 0.5, 1]
            let now = lighting.lights[k].patternFocus
            let next = steps.first { $0 > now + 0.01 } ?? steps[0]
            lighting.lights[k].patternFocus = next
            let gobo = lighting.lights[k].kit.kind == .ellipsoidal
            hud?.flash(gobo ? String(format: "GOBO FOCUS: %@", next == 0 ? "SHARP" : next < 0.5 ? "A TOUCH SOFT" : next < 1 ? "SOFT" : "VERY SOFT")
                            : String(format: "COOKIE: %@", next == 0 ? "CLOSE TO THE LAMP (SOFT)" : next < 1 ? "FURTHER OUT" : "FAR OUT (CRISP)"))
        }
        var plot = lighting
        let n = plot.lights.count
        if p.contains(.x) && plot.lights.count < RenderLoop.maxLights {
            // A new head where you are looking from, aimed the same way.
            let from = pov.map { _ in lightCam } ?? camera
            plot.lights.append(PlacedLight(head: plot.kitChoice, position: from.position, aim: from.forward))
            lighting = plot
            fly(plot.lights.count - 1)
            plot = lighting
        }
        if let d = s.digit {
            if d == 0 { pov = nil } else if d <= plot.lights.count { fly(d - 1); plot = lighting }
        }
        if n > 0 {
            if p.contains(.left) { fly(((pov ?? plot.selected) + n - 1) % n); plot = lighting }
            if p.contains(.right) { fly(((pov ?? plot.selected) + 1) % n); plot = lighting }
        }
        if p.contains(.b) { pov = nil }
        if p.contains(.y) {
            plot.kitChoice = (plot.kitChoice + 1) % lightKit.count
            if let i = pov {
                plot.lights[i].head = plot.kitChoice
                if !plot.lights[i].fits(lightModifiers[plot.lights[i].modifier]) { plot.lights[i].modifier = 0 }
            }
        }
        if let i = pov, plot.lights.indices.contains(i) {
            if p.contains(.removeLight) {
                plot.lights.remove(at: i)
                plot.selected = max(0, i - 1)
                pov = nil
            } else {
                var l = plot.lights[i]
                if p.contains(.up) { l.dimmerStops = min(0, l.dimmerStops + 0.5) }
                if p.contains(.down) { l.dimmerStops = max(-4, l.dimmerStops - 0.5) }
                l.spot = max(0, min(1, l.spot + s.triggers * dt * 0.8 + s.wheel * 0.01))
                plot.lights[i] = l
            }
        }
        if p.contains(.l3) { plot.cycleHouseLights() }
        lighting = plot
    }

    func flyLight(_ i: Int) { fly(i) }

    /// Sets the shutter speed by the finder's meter (scripted runs).
    func meterNow() { body.meterShutter(sceneLuminance: meterLum) }

    /// Climbs into light `i`: the view from its lens, looking down the beam.
    private func fly(_ i: Int) {
        guard lighting.lights.indices.contains(i) else { return }
        let l = lighting.lights[i]
        lighting.selected = i
        pov = i
        lightCam = FlyCamera()
        lightCam.up = camera.up
        lightCam.focalMM = 28
        lightCam.lookAt(l.position + l.aim, from: l.position)
    }

    /// A classic setup for scripted runs: a hard Fresnel key high at 45 degrees,
    /// a broad softlight fill from the other side, house lights down.
    func startLighting() { mode = .lighting }

    /// A Fresnel ahead and a little to the side, aimed back at the lens (flare tests).
    func flareTestLight() {
        let m = 1 / body.metresPerUnit
        let pos = camera.position + camera.forward * (7 * m) + camera.right * (1.2 * m) - camera.down * (0.4 * m)
        // Aimed a little past the lens (VC_FLARE_AIM degrees; 0 straight in).
        let off = (Float(ProcessInfo.processInfo.environment["VC_FLARE_AIM"] ?? "0") ?? 0) * .pi / 180
        let at = simd_normalize(camera.position - pos)
        let aim = simd_normalize(at * cos(off) + camera.right * sin(off))
        let head = Int(ProcessInfo.processInfo.environment["VC_FLARE_HEAD"] ?? "2") ?? 2
        lighting.lights.append(PlacedLight(head: head, position: pos, aim: aim))
    }

    func demoLights() {
        var subject = camera.position + camera.forward * (body.focusM / body.metresPerUnit)
        if inside {
            // In a place, light the ground where the camera looks, not the air.
            let flat = simd_normalize(camera.forward - simd_dot(camera.forward, camera.up) * camera.up)
            subject = camera.position + flat * (5 / body.metresPerUnit) - camera.up * (1.6 / body.metresPerUnit)
        }
        func place(_ head: Int, side: Float, up: Float, metres: Float, spot: Float) -> PlacedLight {
            let toCam = simd_normalize(camera.position - subject)
            let dir = simd_normalize(toCam * cos(side) + camera.right * sin(side) + camera.up * up)
            let pos = subject + dir * (metres / body.metresPerUnit)
            var l = PlacedLight(head: head, position: pos, aim: simd_normalize(subject - pos))
            l.spot = spot
            return l
        }
        if inside {
            // A night set in a place: two hard Fresnels crossing, a softlight fill.
            // On stands about 3 m up: a hard key and a back-cross, a softlight fill.
            lighting.lights = [place(2, side: -0.9, up: 0.55, metres: 6, spot: 0.5),
                               place(2, side: 2.4, up: 0.5, metres: 6, spot: 0.7),
                               place(3, side: 0.6, up: 0.6, metres: 4, spot: 0)]
            lighting.setHouseLights("city night")
            return
        }
        lighting.lights = [place(2, side: -0.8, up: 0.7, metres: 2.0, spot: 0.6),
                           place(3, side: 0.9, up: 0.2, metres: 2.2, spot: 0)]
        lighting.ambient = 0.1
    }

    // MARK: pace

    /// How fast you move, in real metres per second: from a macro focusing
    /// rail to a run. The scene's scale turns it into scene units.
    static let gaits: [(name: String, metres: Float)] = [
        ("rail", 0.005), ("creep", 0.02), ("inch", 0.08), ("step", 0.3),
        ("stroll", 0.8), ("walk", 1.4), ("jog", 3), ("run", 6),
    ]
    private(set) var gait = 5
    private var bobPhase: Float = 0, bobAmount: Float = 0

    /// The pace that suits the scene's real size: walking in a place; for an
    /// object, about half its size a second (a bee: a crawl; a car: a stroll).
    func pickGait() {
        if inside {
            gait = 5
        } else {
            let want = radius * body.metresPerUnit * 0.5
            gait = Self.gaits.indices.min(by: { abs(log(Self.gaits[$0].metres / want)) < abs(log(Self.gaits[$1].metres / want)) }) ?? 5
        }
        print("Pace: \(Self.gaits[gait].name) (\(Self.gaits[gait].metres) m/s) for a subject \(radius * body.metresPerUnit) m across-ish")
    }

    private func changeGait(_ d: Int) {
        gait = max(0, min(Self.gaits.count - 1, gait + d))
        let g = Self.gaits[gait]
        hud?.flash(g.metres < 0.1 ? String(format: "%@ %.0f MM/S", g.name.uppercased(), g.metres * 1000)
                   : String(format: "%@ %.1f M/S", g.name.uppercased(), g.metres))
    }

    /// A step's bob and sway when walking or running at human scale.
    private func stride(_ input: FlyInput, dt: Float, running: Bool) {
        let moving = min(1, simd_length(input.move))
        let g = Self.gaits[gait].metres * (running ? 3 : 1)
        let onFoot: Float = g >= 1.0 ? 1 : 0
        bobAmount += (moving * onFoot - bobAmount) * min(1, dt * 6)
        // Steps a second rise with pace: about 1.8 walking, 2.8 running.
        bobPhase += dt * .pi * 2 * (1.4 + 0.25 * min(g, 6)) * (moving > 0.05 ? 1 : 0)
    }

    /// The camera as it is carried: the step's bob added to where you are.
    var carriedCamera: FlyCamera {
        guard bobAmount > 0.001 else { return camera }
        let g = Self.gaits[gait].metres
        let amp = min(0.05, 0.01 * g) / body.metresPerUnit * bobAmount
        var c = camera
        c.position += camera.up * (amp * abs(sin(bobPhase))) + camera.right * (amp * 0.5 * sin(bobPhase * 0.5))
        return c
    }

    // MARK: setting the scale

    /// Scripted check: pick a point, turn a little, pick another (then the entry panel shows).
    func measureDemo() {
        startMeasure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if let h = crosshairHit { measure = .second(h) }
            camera.yaw -= 8 * .pi / 180
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
            if case .second(let a) = measure, let h = crosshairHit {
                let metres = simd_distance(a, h) * body.metresPerUnit
                measure = .entry(a, h)
                entryUnit = metres < 0.1 ? 0 : metres < 1 ? 1 : 2
                entryValue = metres / Self.units[entryUnit].metres
            }
        }
        // Then say it is really 4.5 mm (a bee's head), as typing it would.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self] in
            if case .entry(let a, let b) = measure {
                let now = simd_distance(a, b) * body.metresPerUnit
                print(String(format: "measured %.4f m, setting 0.0045 m: scale %.5g -> %.5g", now, body.metresPerUnit,
                             body.metresPerUnit * 0.0045 / now))
                applyScale(body.metresPerUnit * 0.0045 / now)
                measure = nil
            }
        }
    }

    /// Measure two points on the scan and say how far apart they really are.
    func startMeasure() {
        closeMenu()
        if mode != .camera { switchTo(.camera) }
        measure = .first
    }

    private func measureInput(_ s: GamepadInput.State, dt: Float) {
        let p = s.pressed
        switch measure {
        case .first, .second:
            // Walk and look as usual to aim the crosshair.
            camera.turn(s.mouseLook)
            camera.update(FlyInput(move: s.move, look: s.look, rise: s.shoulders, zoom: 0), dt: dt)
            if p.contains(.b) { measure = nil; return }
            guard p.contains(.a) else { return }
            guard let hit = crosshairHit else {
                hud?.flash("NOTHING UNDER THE CROSSHAIR")
                return
            }
            if case .second(let a) = measure {
                let metres = simd_distance(a, hit) * body.metresPerUnit
                guard metres > 0 else { return }
                measure = .entry(a, hit)
                // Start the dial on the length it measures now, in a sensible unit.
                entryUnit = metres < 0.1 ? 0 : metres < 1 ? 1 : 2
                entryValue = metres / Self.units[entryUnit].metres
                entryText = ""
            } else {
                measure = .second(hit)
            }
        case .entry(let a, let b):
            if p.contains(.b) { measure = .second(a); return }
            // Typing: digits and a unit (2.5 m, 30cm, 6 ft).
            if s.erase > 0 { entryText = String(entryText.dropLast(s.erase)) }
            entryText += s.typed.replacingOccurrences(of: ",", with: ".")
            if !s.typed.isEmpty || s.erase > 0 {
                let letters = entryText.filter(\.isLetter).lowercased()
                if let u = Self.units.firstIndex(where: { $0.name == letters }) { entryUnit = u }
                if let v = Float(entryText.filter { "0123456789.".contains($0) }) { entryValue = v }
            }
            // The pad: dial the value, step the unit.
            if p.contains(.up) { entryValue *= 1.1; entryText = "" }
            if p.contains(.down) { entryValue /= 1.1; entryText = "" }
            entryValue *= exp(s.triggers * dt * 0.8)
            if p.contains(.left) || p.contains(.right) {
                let metres = entryValue * Self.units[entryUnit].metres
                entryUnit = (entryUnit + (p.contains(.right) ? 1 : Self.units.count - 1)) % Self.units.count
                entryValue = metres / Self.units[entryUnit].metres
                entryText = ""
            }
            if p.contains(.a) {
                let real = entryValue * Self.units[entryUnit].metres
                let now = simd_distance(a, b) * body.metresPerUnit
                guard real > 0, now > 0 else { return }
                applyScale(body.metresPerUnit * real / now)
                measure = nil
            }
        case nil:
            break
        }
    }

    /// The scan's new size: metres per scene unit. Distances in metres that are
    /// pinned to the scene (where you focus) keep their place; paces follow.
    private func applyScale(_ scale: Float) {
        let ratio = scale / body.metresPerUnit
        body.metresPerUnit = scale
        body.focusM = max(body.lens.minFocusM, body.focusM * ratio)
        pickGait()
        tables.removeAll()
        hud?.flash(String(format: "SCALE SET: %.3g M PER UNIT", scale))
        onScaleSet?(scale)
    }

    /// The measuring overlay for the HUD: crosshair, the line, the question.
    private func measureInfo() -> ViewfinderHUD.Measure? {
        guard let m = measure else { return nil }
        let fx = camera.focalPixels(width: width)
        func project(_ p: SIMD3<Float>) -> CGPoint? {
            let V = camera.viewMatrix
            let c = SIMD3(V[0] * p.x + V[1] * p.y + V[2] * p.z + V[3], V[4] * p.x + V[5] * p.y + V[6] * p.z + V[7],
                          V[8] * p.x + V[9] * p.y + V[10] * p.z + V[11])
            guard c.z > 0 else { return nil }
            return CGPoint(x: CGFloat((fx * c.x / c.z + Float(width) / 2) / Float(width)),
                           y: CGFloat((fx * c.y / c.z + Float(height) / 2) / Float(height)))
        }
        func metres(_ d: Float) -> String {
            d < 0.1 ? String(format: "%.1f mm", d * 1000) : d < 1 ? String(format: "%.1f cm", d * 100) : String(format: "%.2f m", d)
        }
        var info = ViewfinderHUD.Measure()
        switch m {
        case .first:
            info.prompt = "SET THE SCALE · aim at one end of something you know the size of · A / click · B / right button cancels"
        case .second(let a):
            info.a = project(a)
            if let hit = crosshairHit {
                info.b = project(hit)
                info.label = "now " + metres(simd_distance(a, hit) * body.metresPerUnit)
            }
            info.prompt = "aim at the other end · A / click · B back"
        case .entry(let a, let b):
            info.a = project(a)
            info.b = project(b)
            info.crosshair = false
            info.label = "now " + metres(simd_distance(a, b) * body.metresPerUnit)
            let shown = entryText.isEmpty ? String(format: "%.3g", entryValue) : entryText.filter { "0123456789.".contains($0) }
            info.entry = "\(shown) \(Self.units[entryUnit].name)"
            info.prompt = "How long is it really?  type it (2.5 m, 30 cm, 6 ft) · or ▲▼ / L2 R2 dial, ◀▶ unit · Enter / A set · B re-aim"
        }
        return info
    }

    // MARK: where pictures go

    /// This sitting's folder: the day, then the time it began and the scene
    /// ("2026-10-17/09.14 Skate park"). Made when the first frame is saved.
    var sceneName = "scene"
    /// This session's day and time (fixed when it starts) ...
    private lazy var sessionName: (day: String, sitting: String) = {
        let now = Date()
        let day = DateFormatter(), time = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH.mm"
        return (day.string(from: now), "\(time.string(from: now)) \(sceneName)")
    }()
    /// ... under wherever rolls are kept now (it can be changed mid-session).
    private var sessionFolder: URL {
        ContactSheetView.root.appendingPathComponent(sessionName.day).appendingPathComponent(sessionName.sitting)
    }

    func rollFolder(_ b: CameraBody) -> URL {
        sessionFolder.appendingPathComponent(String(format: "Roll %02d - %@", b.rollNumber, b.rollName))
    }

    // MARK: the menu

    private var modeName: String {
        switch mode {
        case .camera: return "camera"
        case .lighting: return pov.map { "lighting · flying light \($0 + 1)" } ?? "lighting"
        case .sheet: return "light table"
        }
    }

    /// The controls guide, straight away (Help menu).
    func showControls() {
        openMenu()
        menu?.showingHelp = true
    }

    func openMenu() {
        guard let menu else { return }
        menuOpen = true
        menu.currentMode = modeName
        menu.showingHelp = false
        menu.showingFilm = false
        menu.showingLenses = false
        menu.showingList = false
        menu.items = menuItems(menuPage)
        menu.selected = 0
        menu.isHidden = false
    }

    /// Opens a page of the menu (on its first item after Back).
    private func go(_ page: MenuPage) {
        menuPage = page
        openMenu()
        if page != .main { menu?.selected = 1 }
    }

    /// The game menu, page by page: the modes and a few headings at the top,
    /// the settings under them.
    private func menuItems(_ page: MenuPage) -> [MenuOverlay.Item] {
        typealias Item = MenuOverlay.Item
        func back(to parent: MenuPage, _ name: String = "Back to the menu") -> Item {
            .init(title: name, detail: "") { [weak self] in self?.go(parent) }
        }
        let k = lighting.lights.isEmpty ? nil : min(lighting.selected, lighting.lights.count - 1)
        switch page {
        case .main:
            return [
                .init(title: "Back to the \(mode == .sheet ? "light table" : mode == .lighting ? "lights" : "camera")",
                      detail: "carry on where you were") { [weak self] in self?.closeMenu() },
                .init(title: "Camera", detail: "frame, focus and expose") { [weak self] in
                    self?.closeMenu(); self?.switchTo(.camera) },
                .init(title: "Lighting", detail: "place and fly the lights, set the house lights") { [weak self] in
                    self?.closeMenu(); self?.switchTo(.lighting) },
                .init(title: "Light table", detail: "your rolls, through a loupe") { [weak self] in
                    self?.closeMenu(); self?.switchTo(.sheet) },
                .init(title: "Camera bag…", detail: "lens, filter and film: \(body.lens.name) · \(body.rollName)") { [weak self] in
                    self?.go(.bag) },
                .init(title: "Lights…", detail: k.map { "light \($0 + 1): gel, modifier, lens flare" } ?? "add a light first (lighting mode)") {
                    [weak self] in self?.go(.lights) },
                .init(title: "Scene…", detail: "its light, sky and size; reset the view; open another scan") { [weak self] in
                    self?.go(.scene) },
                .init(title: "Photos…", detail: "proofs or prints, size, quality, negatives, where rolls are kept") { [weak self] in
                    self?.go(.photos) },
                .init(title: "Settings…", detail: "viewfinder graphics, camera sounds, controls") { [weak self] in
                    self?.go(.settings) },
                .init(title: "Quit", detail: "") { [weak self] in self?.appActions?.quit() },
            ]
        case .bag:
            return [
                back(to: .main),
                .init(title: "Change lens…", detail: "now: \(body.lens.name) (\(body.lens.collection))") { [weak self] in
                    self?.openLenses() },
                .init(title: "Lens filter: " + body.filter.name, detail: "ND, colour, star, soft and mist (V)") { [weak self] in
                    self?.openFilters() },
                .init(title: "Load film…", detail: "now: \(body.rollName), frame \(body.framesShot + 1) of \(body.stock.exposures)") {
                    [weak self] in self?.openFilm() },
            ]
        case .lights:
            var items: [Item] = [back(to: .main)]
            guard let k else {
                items.append(.init(title: "No lights yet", detail: "add one in lighting mode (F / X)") { [weak self] in
                    self?.closeMenu(); self?.switchTo(.lighting) })
                return items
            }
            let l = lighting.lights[k]
            items += [
                .init(title: "Gel on light \(k + 1): " + gels[l.gel].name,
                      detail: "colour correction and effect colours for the light (C in lighting)") { [weak self] in self?.openGels() },
                .init(title: "Modifier on light \(k + 1): " + lightModifiers[l.modifier].name,
                      detail: "barn doors, flags, cookies; gobos in an ellipsoidal (M in lighting, K focus)") { [weak self] in
                    self?.openModifiers() },
                .init(title: "Lens flare from light \(k + 1): \(l.flareOn ? "on" : "off")",
                      detail: "ghosts, glare and a starburst when it shines into the lens (P / Select in lighting)") { [weak self] in
                    guard let self else { return }
                    self.lighting.lights[k].flare = !self.lighting.lights[k].flareOn
                    self.reopenMenu() },
            ]
            if mode == .lighting, let i = pov {
                items.append(.init(title: "Remove light \(i + 1)", detail: "the one you are flying") { [weak self] in
                    guard let self else { return }
                    self.lighting.lights.remove(at: i)
                    self.lighting.selected = max(0, i - 1)
                    self.pov = nil
                    self.closeMenu()
                })
            }
            return items
        case .scene:
            return [
                back(to: .main),
                .init(title: "Scene light: " + (sceneLightChoices.first { $0.1 == body.sceneEV }?.0
                                                ?? String(format: "EV %.0f", body.sceneEV)),
                      detail: String(format: "the light on the scene's middle tone (calibrated: the scan's %.2f → mid grey, %+.1f stops) · select to change",
                                     middleTone, body.calibration)) { [weak self] in
                    guard let self else { return }
                    let i = sceneLightChoices.firstIndex { $0.1 == self.body.sceneEV } ?? -1
                    let next = sceneLightChoices[(i + 1) % sceneLightChoices.count].1
                    self.body.sceneEV = next
                    self.onSceneLight?(next)
                    self.reopenMenu() },
                .init(title: loop.sky.map { "Sky: \($0.name)" } ?? "Sky: the scan's own",
                      detail: loop.sky == nil ? "choose an equirectangular .hdr to fill where the scan is empty"
                                              : "select to remove it") { [weak self] in
                    guard let self else { return }
                    self.setSky(self.loop.sky == nil ? SkySetting.choose().map { SkySetting(path: $0) } : nil)
                    self.reopenMenu() },
                .init(title: String(format: "Sky turn: %.0f°  ·  brightness %+.0f stops", loop.sky?.yawDegrees ?? 0, loop.sky?.stops ?? 0),
                      detail: "select to turn the sky 30° (Shift-select: brightness)") { [weak self] in
                    guard let self, var s = self.loop.sky else { return }
                    if NSEvent.modifierFlags.contains(.shift) { s.stops = s.stops >= 2 ? -2 : s.stops + 1 }
                    else { s.yawDegrees = (s.yawDegrees + 30).truncatingRemainder(dividingBy: 360) }
                    self.setSky(s)
                    self.reopenMenu() },
                .init(title: sceneIsPlace ? "Treat this scan as an object" : "Treat this scan as a place",
                      detail: sceneIsPlace ? "now: a place to stand in, about 30 m across — wrong size? switch"
                                           : "now: an object about 60 cm across — wrong size? switch") { [weak self] in
                    self?.onSwitchKind?() },
                .init(title: "Set the scale (measure)…",
                      detail: String(format: "now %.3g m per unit: aim at two points, say how far apart they are", body.metresPerUnit)) {
                    [weak self] in self?.startMeasure() },
                .init(title: "Reset the view", detail: "back to where you started") { [weak self] in
                    guard let self else { return }
                    self.camera = self.home
                    self.closeMenu() },
                .init(title: "Open another scene…", detail: "a .ply scan") { [weak self] in self?.appActions?.openScene() },
            ]
        case .photos:
            return [
                back(to: .main),
                .init(title: "Shutter makes: \(proofsAtShutter ? "proofs (enlarge at the light table)" : "full prints")",
                      detail: "proofs keep the finder fast; at the light table Y / P sends the marked frames (or all) to the enlarger") {
                    [weak self] in
                    guard let self else { return }
                    self.proofsAtShutter.toggle()
                    self.reopenMenu() },
                .init(title: "Photo size: \(width * photoScale) × \(height * photoScale)",
                      detail: "\(photoScale)× the finder · bigger takes longer to develop (select to change)") { [weak self] in
                    guard let self else { return }
                    self.photoScale = self.photoScale % 4 + 1 == 1 ? 2 : self.photoScale % 4 + 1
                    self.reopenMenu() },
                .init(title: "Exposure quality: \(cellsPerExposure) lens samples",
                      detail: "more: truer bokeh, smoother blur, slower; 64+ adds coloured bokeh fringes (select to change)") { [weak self] in
                    guard let self else { return }
                    self.cellsPerExposure = self.cellsPerExposure >= 128 ? 32 : self.cellsPerExposure * 2
                    self.reopenMenu() },
                .init(title: "Digital negative (DNG): \(keepNegative ? "on" : "off")",
                      detail: "a high-dynamic-range linear DNG beside each print, for a raw developer") { [weak self] in
                    guard let self else { return }
                    self.keepNegative.toggle()
                    self.reopenMenu() },
                .init(title: "Where rolls are kept…", detail: ContactSheetView.root.path) { [weak self] in
                    self?.appActions?.chooseRolls()
                    self?.reopenMenu() },
            ]
        case .settings:
            return [
                back(to: .main),
                .init(title: "Viewfinder graphics…", detail: "how the finder draws: blur, distant shells") { [weak self] in
                    self?.go(.finder) },
                .init(title: "Camera sounds: " + (Sounds.shared.enabled ? "on" : "off"),
                      detail: "shutter, film advance, lens and dial: a real Nikon (select to turn \(Sounds.shared.enabled ? "off" : "on"))") {
                    [weak self] in
                    Sounds.shared.enabled.toggle()
                    self?.reopenMenu() },
                .init(title: "Controls", detail: "every button, pad and keyboard") { [weak self] in
                    self?.menu?.showingHelp = true },
            ]
        case .finder:
            return [
                back(to: .settings, "Back to settings"),
                .init(title: "Finder blur: \(UserDefaults.standard.bool(forKey: "classicBlur") ? "classic" : "smooth")",
                      detail: "smooth: rendered sharp, blurred like a print; classic: each splat blurred by the renderer") { [weak self] in
                    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "classicBlur"), forKey: "classicBlur")
                    self?.reopenMenu() },
                .init(title: "Finder focus (classic): \(UserDefaults.standard.bool(forKey: "fastFocus") ? "fast" : "smooth")",
                      detail: "fast draws strong blur from fewer splats: quicker far out of focus, a little coarser") { [weak self] in
                    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "fastFocus"), forKey: "fastFocus")
                    self?.reopenMenu() },
                .init(title: "Distant shells: \(distantShells ? "on" : "off")",
                      detail: "in a place, far splats drawn from a baked panorama: a faster finder (prints always draw everything)") {
                    [weak self] in
                    guard let self else { return }
                    self.distantShells.toggle()
                    self.reopenMenu() },
            ]
        }
    }

    /// The camera bag: collections and their lenses (the pad's left button, B, or the menu).
    func openLenses() {
        if !menuOpen { openMenu() }
        guard let menu else { return }
        let shelf = lensCollections.firstIndex { $0.name == body.lens.collection } ?? 0
        menu.lensShelf = shelf
        menu.lensChoice = lensCollections[shelf].lenses.firstIndex { $0.name == body.lens.name } ?? 0
        menu.mountedLens = body.lensIndex
        menu.onMountLens = { [weak self] i in
            self?.mount(i)
            self?.closeMenu()
        }
        menu.mountedFilter = body.filterIndex
        menu.filterFits = { [weak self] i in self.map { $0.body.fits(lensFilters[i]) } ?? true }
        menu.onMountFilter = { [weak self] i in
            guard let self else { return }
            guard self.body.fits(lensFilters[i]) else {
                self.hud?.flash("THIS LENS TAKES ONLY COLOUR AND ND FILTERS, AT THE BACK")
                return
            }
            self.body.filterIndex = i
            self.body.meterShutter(sceneLuminance: self.meterLum)
            self.hud?.flash(i == 0 ? "FILTER OFF" : lensFilters[i].name.uppercased())
            self.closeMenu()
        }
        menu.showingLenses = true
    }

    /// The camera bag, open at its Filters shelf (V, or the menu).
    func openFilters() {
        openLenses()
        guard let menu else { return }
        menu.lensShelf = menu.filterShelf
        menu.lensChoice = body.filterIndex
    }

    /// What goes on or in front of the light being flown (or the one chosen):
    /// barn doors, flags, cookies; gobos for an ellipsoidal. M in lighting, or the menu.
    func openModifiers() {
        guard !lighting.lights.isEmpty else {
            hud?.flash("ADD A LIGHT FIRST (LIGHTING MODE)")
            return
        }
        if !menuOpen { openMenu() }
        guard let menu else { return }
        let k = pov ?? min(lighting.selected, lighting.lights.count - 1)
        let light = lighting.lights[k]
        let choices = lightModifiers.indices.filter { light.fits(lightModifiers[$0]) }
        menu.listTitle = "MODIFIERS · LIGHT \(k + 1)"
        menu.listAbout = light.kit.kind == .ellipsoidal
            ? "\(light.kit.name): a metal gobo in the gate (K: focus, sharp to soft)"
            : "\(light.kit.name): barn doors, flags and cookies (K: how far the cookie stands from the lamp)"
        menu.listRows = choices.map { (lightModifiers[$0].name, lightModifiers[$0].about) }
        menu.listMarked = choices.firstIndex(of: light.modifier) ?? 0
        menu.listChoice = menu.listMarked
        menu.onChooseList = { [weak self] row in
            guard let self, self.lighting.lights.indices.contains(k) else { return }
            let m = choices[row]
            self.lighting.lights[k].modifier = m
            self.hud?.flash(m == 0 ? "OPEN BEAM" : lightModifiers[m].name.uppercased())
            self.closeMenu()
        }
        menu.showingList = true
    }

    /// The gel book, for the light being flown (or the one chosen): C in lighting, or the menu.
    func openGels() {
        guard !lighting.lights.isEmpty else {
            hud?.flash("ADD A LIGHT FIRST (LIGHTING MODE)")
            return
        }
        if !menuOpen { openMenu() }
        guard let menu else { return }
        let k = pov ?? min(lighting.selected, lighting.lights.count - 1)
        menu.listTitle = "GELS · LIGHT \(k + 1)"
        menu.listAbout = "\(lighting.lights[k].kit.name): a sheet of colour in front of the lens"
        menu.listRows = gels.map { g in
            let stops = -log2(max(simd_dot(g.transmission, SIMD3<Float>(0.2126, 0.7152, 0.0722)), 1e-4))
            return (g.name, g.about + (stops < 0.05 ? "" : String(format: " · %.1f stops", stops)))
        }
        menu.listMarked = lighting.lights[k].gel
        menu.listChoice = lighting.lights[k].gel
        menu.onChooseList = { [weak self] g in
            guard let self, self.lighting.lights.indices.contains(k) else { return }
            self.lighting.lights[k].gel = g
            self.hud?.flash(g == 0 ? "GEL OFF" : gels[g].name.uppercased())
            self.closeMenu()
        }
        menu.showingList = true
    }

    private var movementLabel: String {
        switch body.lens.movement {
        case .tilt: return String(format: "TILT %+.1f° ACROSS  %+.1f° UP", body.tilt.x, body.tilt.y)
        case .shift: return String(format: "SHIFT %+.1f MM RIGHT  %+.1f MM UP", body.shift.x, body.shift.y)
        case .none: return ""
        }
    }

    private func mount(_ i: Int) {
        guard lensBag.indices.contains(i), i != body.lensIndex else { return }
        body.chooseLens(i)
        Sounds.shared.play(.lensChange)
        camera.focalMM = body.lens.focalMM
        switch body.lens.movement {
        case .tilt: hud?.flash(body.lens.name.uppercased() + " · TILT: HOLD Y + RIGHT STICK (M + ARROWS)")
        case .shift: hud?.flash(body.lens.name.uppercased() + " · SHIFT: HOLD Y + RIGHT STICK (M + ARROWS)")
        case .none: hud?.flash(body.lens.name.uppercased())
        }
    }

    /// Straight to loading a roll (the pad's top button, R, or the menu).
    func openFilm() {
        if !menuOpen { openMenu() }
        guard let menu else { return }
        menu.filmChoice = body.stockIndex
        menu.filmPush = body.push
        menu.onLoadFilm = { [weak self] stock, push in
            guard let self else { return }
            if Sounds.shared.has(.filmChange) {
                Sounds.shared.play(.filmChange)          // rewind, open the back, load, wind on
            } else {
                if self.body.framesShot > 0 { Sounds.shared.play(.rewind) }
                Sounds.shared.play(.back, after: self.body.framesShot > 0 ? 2.5 : 0)
            }
            self.body.loadRoll(stock: stock, push: push)
            self.body.meterShutter(sceneLuminance: self.meterLum)
            self.hud?.flash("LOADED \(self.body.rollName.uppercased())")
            self.closeMenu()
        }
        menu.showingFilm = true
    }

    /// Redraws the menu with fresh values, keeping the selection.
    private func reopenMenu() {
        let keep = menu?.selected ?? 0
        openMenu()
        menu?.selected = keep
    }

    private func closeMenu() {
        menuOpen = false
        menuPage = .main
        menu?.isHidden = true
    }

    private func switchTo(_ m: Mode) {
        guard m != mode else { return }
        if mode == .sheet { closeSheet() }
        pov = nil
        switch m {
        case .sheet: openSheet()
        case .lighting: mode = .lighting
        case .camera: mode = .camera
        }
    }

    private func menuInput(_ s: GamepadInput.State) {
        guard let menu else { return }
        let p = s.pressed
        if menu.showingHelp {
            if !p.isDisjoint(with: [.a, .b, .menu]) { menu.showingHelp = false }
            return
        }
        if menu.showingLenses {
            let y = s.move.y + s.look.y, x = s.move.x + s.look.x
            if abs(y) > 0.5 && abs(menuStick) <= 0.5 { menu.moveLens(y > 0 ? -1 : 1) }
            menuStick = y
            if p.contains(.up) { menu.moveLens(-1) }
            if p.contains(.down) { menu.moveLens(1) }
            if p.contains(.left) || (x < -0.5 && filmStickX >= -0.5) { menu.moveShelf(-1) }
            if p.contains(.right) || (x > 0.5 && filmStickX <= 0.5) { menu.moveShelf(1) }
            filmStickX = x
            if p.contains(.a) { menu.mountLens() }
            if p.contains(.b) || p.contains(.menu) { menu.showingLenses = false }
            return
        }
        if menu.showingList {
            let y = s.move.y + s.look.y
            if abs(y) > 0.5 && abs(menuStick) <= 0.5 { menu.moveList(y > 0 ? -1 : 1) }
            menuStick = y
            if p.contains(.up) { menu.moveList(-1) }
            if p.contains(.down) { menu.moveList(1) }
            if p.contains(.a) { menu.onChooseList?(menu.listChoice) }
            if p.contains(.b) || p.contains(.menu) { menu.showingList = false }
            return
        }
        if menu.showingFilm {
            let y = s.move.y + s.look.y, x = s.move.x + s.look.x
            if abs(y) > 0.5 && abs(menuStick) <= 0.5 { menu.moveFilm(y > 0 ? -1 : 1) }
            menuStick = y
            if p.contains(.up) { menu.moveFilm(-1) }
            if p.contains(.down) { menu.moveFilm(1) }
            if p.contains(.left) || (x < -0.5 && filmStickX >= -0.5) { menu.changePush(-1) }
            if p.contains(.right) || (x > 0.5 && filmStickX <= 0.5) { menu.changePush(1) }
            filmStickX = x
            if p.contains(.a) { menu.loadFilm() }
            if p.contains(.b) || p.contains(.menu) { menu.showingFilm = false }
            return
        }
        // A stick steps once per push, like the d-pad.
        let y = s.move.y + s.look.y
        if abs(y) > 0.5 && abs(menuStick) <= 0.5 { menu.move(y > 0 ? -1 : 1) }
        menuStick = y
        if p.contains(.up) { menu.move(-1) }
        if p.contains(.down) { menu.move(1) }
        if p.contains(.a) { menu.choose() }
        // B / Escape go back up a level; Start (or Menu) closes it from anywhere.
        if p.contains(.b) {
            switch menuPage {
            case .main: closeMenu()
            case .finder: go(.settings)
            default: go(.main)
            }
        }
        if p.contains(.menu) && !p.contains(.b) { closeMenu() }
    }

    // MARK: contact sheet

    func openSheet() {
        guard let sheet else { return }
        mode = .sheet
        sheet.reload(showRoll: rollFolder(body))
        sheet.pending = (rollFolder(body), loop.pendingFrames(roll: body.rollNumber))
        sheet.isHidden = false
        hud?.isHidden = true
    }

    private func closeSheet() {
        wall?.isHidden = true
        mode = .camera
        sheet?.isHidden = true
        hud?.isHidden = false
    }

    private func sheetInput(_ s: GamepadInput.State, dt: Float) {
        guard let sheet else { return }
        if let wall, !wall.isHidden { wallInput(wall, s, dt: dt); return }
        let p = s.pressed
        // X / G: the print wall, this session's enlarged prints.
        if p.contains(.x) { openWall(); return }
        // Either stick slides the loupe over the table; the triggers turn its power.
        let v = s.move + s.look
        let speed = CGFloat(sheet.bounds.height) * 0.9
        sheet.handleLoupe(move: CGVector(dx: CGFloat(v.x) * speed, dy: CGFloat(-v.y) * speed),
                          power: CGFloat(s.triggers) * 1.2, dt: CGFloat(dt))
        // With a mouse, the loupe is wherever the pointer is.
        if let ptr = s.pointer, ptr != lastPointer { sheet.putLoupe(at: ptr) }
        lastPointer = s.pointer
        if s.wheel != 0 { sheet.turnLoupe(CGFloat(s.wheel)) }
        let dx = (p.contains(.right) ? 1 : 0) - (p.contains(.left) ? 1 : 0)
        let dy = (p.contains(.down) ? 1 : 0) - (p.contains(.up) ? 1 : 0)
        if dx != 0 || dy != 0 { sheet.move(dx: dx, dy: dy) }
        if p.contains(.l1) { sheet.changeRoll(-1) }
        if p.contains(.r1) { sheet.changeRoll(1) }
        if p.contains(.a) { sheet.toggleMark() }
        if p.contains(.y) { enlarge(sheet.enlargeCandidates()) }
        feedEnlarger()
        let printing = enlargeQueue.count + loop.pendingExposures
        if printing == 0 { enlargeTotal = 0; enlargeDone = 0 }
        sheet.enlargerStatus = enlargeTotal == 0 ? "" : "ENLARGING \(enlargeDone) of \(enlargeTotal)"
        if p.contains(.b) || p.contains(.view) { closeSheet() }
        if loop.pendingFrames(roll: body.rollNumber) != sheet.pending.frames { sheet.reload(showRoll: nil) }
    }


    // MARK: the print wall

    /// The print wall over the light table, on the table's session (or the latest with prints).
    func openWall() {
        guard let wall, let sheet else { return }
        wall.frame = sheet.frame
        wall.reload(session: sheet.currentSessionName)
        wall.isHidden = false
    }

    private func wallInput(_ wall: PrintWallView, _ s: GamepadInput.State, dt: Float) {
        let p = s.pressed
        let v = s.move + s.look
        wall.update(move: CGVector(dx: CGFloat(v.x), dy: CGFloat(-v.y)), zoomBy: CGFloat(s.triggers), dt: CGFloat(dt))
        if s.wheel != 0 { wall.wheel(CGFloat(s.wheel), at: s.pointer) }
        let dx = (p.contains(.right) ? 1 : 0) - (p.contains(.left) ? 1 : 0)
        let dy = (p.contains(.down) ? 1 : 0) - (p.contains(.up) ? 1 : 0)
        if dx != 0 || dy != 0 { wall.step(dx: dx, dy: dy) }
        if p.contains(.a) { wall.toggleCloseUp() }
        if p.contains(.l1) { wall.changeSession(-1) }
        if p.contains(.r1) { wall.changeSession(1) }
        if p.contains(.b) || p.contains(.x) || p.contains(.view) { wall.isHidden = true; sheet?.needsDisplay = true }
    }

    // MARK: the sky

    func setSky(_ s: SkySetting?) {
        loop.setSky(s)
        if let scene = scenePath { SkySetting.remember(loop.sky, scene: scene) }
        if s != nil && loop.sky == nil { hud?.flash("COULD NOT READ THAT SKY") }
    }

    // MARK: lens flare

    /// The flare as the photo takes it: the lights as the finder last saw
    /// them (how much of each was visible), through the taking aperture.
    private func photoFlare(body b: CameraBody, camera c: FlyCamera) -> [SIMD4<Float>] {
        let fx = b.focalPixels(width: width, height: height)
        let axis = SIMD2(Float(width), Float(height)) / 2 + b.axisOffset(width: width)
        let s = Flare.sources(plot: lighting, view: c.viewMatrix, position: c.position, fx: fx, axis: axis,
                              width: width, height: height, fisheye: b.lens.isFisheye, body: b, fNumber: b.takingAperture)
        guard !s.isEmpty else { return [] }
        return Flare.uniforms(s, visibility: flareVis.count == s.count ? flareVis : [Float](repeating: 1, count: s.count),
                              lens: b.lens, fNumber: b.takingAperture, filter: b.filter,
                              axisUV: axis / SIMD2(Float(width), Float(height)), aspect: Float(width) / Float(height))
    }

    // MARK: the enlarger

    /// Queues proofs for full prints, from their records (only this scan's:
    /// the stage holds one scan at a time).
    func enlarge(_ frames: [URL]) {
        var queued = 0, elsewhere = 0
        for u in frames where !enlargeQueue.contains(u) {
            guard let r = ShotRecord.load(for: u), isProof(u) else { continue }
            if r.scene != scenePath { elsewhere += 1; continue }
            enlargeQueue.append(u)
            queued += 1
            enlargeTotal += 1
        }
        var msg = queued == 0 ? "NOTHING TO ENLARGE" : "ENLARGING \(queued) FRAME\(queued == 1 ? "" : "S")"
        if elsewhere > 0 { msg += " · \(elsewhere) from another scan: open it to enlarge them" }
        hud?.flash(msg)
    }

    private func isProof(_ u: URL) -> Bool {
        guard let d = try? Data(contentsOf: u.deletingPathExtension().appendingPathExtension("json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return o["proof"] as? Bool ?? false
    }

    /// One print at a time: each needs a big accumulator.
    func feedEnlarger() {
        guard !enlargeQueue.isEmpty, loop.pendingExposures == 0 else { return }
        let u = enlargeQueue.removeFirst()
        enlargeDone += 1
        guard let r = ShotRecord.load(for: u), let accum = loop.makeAccumulator(r.width, r.height) else { return }
        let job = ExposureJob(camera: r.camera, body: r.body, lighting: r.lighting, frameNumber: r.frameNumber,
                              cells: r.body.lens.isFisheye ? [.zero] : r.body.cellCentres(r.cells),
                              accum: accum, size: (r.width, r.height), wantsNegative: r.negative)
        job.outputPath = u
        job.filterThreshold = r.filterThreshold
        job.flare = r.flare ?? []
        if r.sky != loop.sky { loop.setSky(r.sky) }
        job.record = r
        loop.expose(job)
    }

    // MARK: shutter

    /// Fires: the mirror swings up for the exposure, the film advances, and
    /// the frame is exposed and developed in the background.
    func releaseShutter() {
        guard body.framesLeft > 0 else {
            hud?.flash("END OF ROLL — load a new one")
            return
        }
        // Big photos take a lot of memory while they develop: fewer at once.
        let proof = proofsAtShutter
        let size = proof ? (w: width, h: height) : (w: width * photoScale, h: height * photoScale)
        let room = !proof && photoScale >= 3 ? 2 : Self.maxPending
        guard loop.pendingExposures < room, let accum = loop.makeAccumulator(size.w, size.h) else {
            hud?.flash("BUFFER FULL")
            return
        }
        let job = ExposureJob(camera: carriedCamera, body: body, lighting: lighting, frameNumber: body.framesShot + 1,
                              cells: body.lens.isFisheye ? [.zero] : body.cellCentres(proof ? min(8, cellsPerExposure) : cellsPerExposure),
                              accum: accum, size: size, wantsNegative: keepNegative && !proof)
        job.outputPath = scriptedPath
        job.filterThreshold = filterThreshold
        job.flare = photoFlare(body: body, camera: carriedCamera)
        if proof, let scene = scenePath {
            job.isProof = true
            job.record = ShotRecord(scene: scene, camera: carriedCamera, body: body, lighting: lighting,
                                    frameNumber: body.framesShot + 1, cells: cellsPerExposure,
                                    width: width * photoScale, height: height * photoScale,
                                    negative: keepNegative, filterThreshold: filterThreshold, sky: loop.sky,
                                    flare: job.flare)
        }
        loop.expose(job)
        Sounds.shared.fire(shutterSeconds: body.shutter.seconds)
        body.framesShot += 1
        // Mirror travel (~1/15 s round trip) plus the shutter time.
        mirrorUpUntil = CACurrentMediaTime() + 0.07 + Double(body.shutter.seconds)
        print("Shutter: frame \(job.frameNumber), \(body.lens.name) f/\(body.takingAperture) " +
              "1/\(body.shutter.label), focus \(String(format: "%.2f", body.focusM)) m")
    }

    private func developed(_ job: ExposureJob, _ image: CGImage, _ seconds: Double) {
        let b = job.body
        let url: URL
        if let p = job.outputPath {
            url = p
        } else {
            let dir = rollFolder(b)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(String(format: "frame-%02d.png", job.frameNumber))
        }
        print(String(format: "Developed frame %d in %.1f s", job.frameNumber, seconds))
        let shotAt = Date().addingTimeInterval(-seconds)
        let meta: [String: Any] = [
            "camera": b.model.fullName, "camera_serial": b.model.serial, "camera_year": b.model.year,
            "shot_at": PhotoMetadata.exifDate(shotAt),
            "lens": b.lens.name, "lens_inspired_by": b.lens.inspiredBy, "filter": b.filter.name,
            "filter_stops": b.filter.stops,
            "aperture": b.takingAperture, "shutter": "1/\(b.shutter.label)",
            "film": b.stock.name, "iso": b.stock.iso, "rated_ei": b.ratedEI, "push": b.push, "focus_m": b.focusM,
            "exposure_stops": b.exposureStops, "reciprocity_loss_stops": b.reciprocityLoss,
            "magnification": b.magnification, "close_focus_loss_stops": b.closeFocusLoss,
            "scene_ev": b.sceneEV, "mid_grey_calibration_stops": b.calibration, "sub_pupils": job.cells.count,
            "metres_per_unit": b.metresPerUnit, "width": image.width, "height": image.height,
            "proof": job.isProof,
            "negative": job.negative == nil ? "" : url.deletingPathExtension().appendingPathExtension("dng").lastPathComponent,
        ]
        let negative = job.negative
        let (nw, nh) = job.size
        job.record?.save(for: url)
        // Writing a big PNG takes a moment: off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let description = "\(b.rollName), frame \(job.frameNumber)"
            _ = PhotoMetadata.writePNG(image, to: url,
                                       properties: PhotoMetadata.properties(b, shotAt: shotAt, description: description))
            if let negative {
                try? DNG.write(negative, width: nw, height: nh, to: url.deletingPathExtension().appendingPathExtension("dng"),
                               description: "\(b.rollName), frame \(job.frameNumber): linear light before the film",
                               body: b, shotAt: shotAt)
            }
            if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
            DispatchQueue.main.async {
                self?.onSaved?(url.path)
                if self?.mode == .sheet { self?.sheet?.reload(showRoll: nil) }
            }
        }
    }

    // MARK: HUD and stats

    private func updateHUD(mirrorUp: Bool) {
        guard let hud else { return }
        let b = body
        var i = ViewfinderHUD.Info()
        let g = Self.gaits[gait]
        i.lens = b.lens.name + (b.filterIndex == 0 ? "" : "  +  " + b.filter.name) + "  ·  " + (g.metres < 0.1 ? String(format: "%@ %.0f mm/s", g.name, g.metres * 1000)
                                           : String(format: "%@ %.1f m/s", g.name, g.metres))
        i.aperture = String(format: b.takingAperture < 10 ? "%.1f" : "%.0f", b.takingAperture)
        i.shutter = b.shutter.seconds >= 1 ? "\(b.shutter.label)\"" : b.shutter.label
        i.shutterIndex = b.shutterIndex
        i.stock = b.rollName
        i.iso = Int(b.ratedEI)
        i.counter = b.framesLeft > 0 ? "\(b.framesShot + 1)" : "E"
        i.focus = b.focusM >= 100 ? "∞" : String(format: "%.2f m", b.focusM)
        i.meterStops = b.exposureStops + log2(max(meterLum, 1e-4) / 0.18)
        var modes: [String] = []
        if b.dofPreview { modes.append("DOF PREVIEW") }
        if mode == .lighting { modes.append("LIGHTING") }
        // Nearer than the lens can focus: back off, or fit a closer-focusing lens.
        if pov == nil, let hit = crosshairHit,
           simd_distance(hit, camera.position) * b.metresPerUnit < b.lens.minFocusM * 0.85 {
            modes.append(String(format: "TOO CLOSE TO FOCUS (%.2g M MIN)", b.lens.minFocusM))
        }
        let pending = loop.pendingExposures
        if pending > 0 { modes.append("DEVELOPING \(pending)") }
        i.mode = modes.joined(separator: "  ")
        if Self.showStats { i.stats = statsLine }
        i.mirrorUp = mirrorUp
        i.measure = measureInfo()
        if mode == .lighting {
            var lines = lighting.lights.enumerated().map { k, l -> String in
                let mark = k == pov ? "◉" : " "
                return String(format: "%@ %d %@  beam %.0f°  %@%@", mark, k + 1, l.kit.name, l.beamAngle,
                              l.dimmerStops == 0 ? "full" : String(format: "%+.1f stop", l.dimmerStops),
                              (l.gel == 0 ? "" : "  · " + gels[l.gel].name) + (l.modifier == 0 ? "" : "  · " + lightModifiers[l.modifier].name)
                                + (l.flareOn ? "  · flare" : ""))
            }
            lines.append(String(format: "House lights: %@ (%.2f%%)   ·   next light: %@", lighting.ambientName,
                                lighting.ambient * 100, lightKit[lighting.kitChoice].name))
            if pov != nil {
                lines.append("Flying the light: WASD / sticks move it, mouse / right stick aims it · wheel or L2/R2 flood/spot · - = or ▲▼ dimmer · T / Y head · P / Select lens flare")
                lines.append("Backspace (or the menu) removes it · 0 or B back to the camera · 1-9 or ◀▶ another light · F / X add one · G / L3 house lights · L / R3 done")
            } else {
                lines.append("1-9 or ◀▶ fly a light from its own view · F / X add one at your view · G / L3 house lights · P / Select lens flare")
                lines.append("L / R3 back to the camera controls")
            }
            i.lines = lines
            if let k = pov, lighting.lights.indices.contains(k) {
                let l = lighting.lights[k]
                let beam = l.beam
                let toRad: Float = .pi / 360
                // On screen: tan(angle) over tan(half the view), half the width. The
                // light's view is 28 mm on 36 mm film: tan(half view) = 18 / 28.
                func r(_ a: Float) -> CGFloat {
                    let ratio: Float = tan(min(a, 1.4)) / (18 / 28)
                    return CGFloat(ratio * 0.5)
                }
                i.beam = (r(beam.angle(at: 0.9) * toRad), r(beam.angle(at: 0.5) * toRad), r(beam.angle(at: 0.1) * toRad))
                i.title = "LIGHT \(k + 1) · \(l.kit.name)"
            }
        }
        hud.info = i
    }

    private func benchOrbit() {
        let a = Float(benchCount) / Float(benchFrames) * 2 * .pi
        var c = FlyCamera()
        c.up = camera.up
        let a0 = c.forward, b0 = simd_cross(camera.up, a0)
        let dist = simd_distance(home.position, center)
        let around: SIMD3<Float> = cos(a) * -a0 + sin(a) * b0
        let lift: SIMD3<Float> = camera.up * (radius * 0.35)
        let eye = center + around * dist + lift
        camera.lookAt(center, from: eye)
        body.focusM = simd_distance(eye, center) * body.metresPerUnit
    }

    private func record(renderMs: Double) {
        let now = CACurrentMediaTime()
        statRender.append(renderMs)
        if now - statStart >= 1 {
            let fps = Double(statRender.count) / (now - statStart)
            let mean = statRender.reduce(0, +) / Double(statRender.count)
            statsLine = String(format: "finder %.1f renders/s | render %.1f ms (max %.1f) | %dx%d%@",
                               fps, mean, statRender.max() ?? 0, width, height,
                               input.controllerName.map { " | \($0)" } ?? " | no controller")
            onStats?(statsLine)
            statStart = now
            statRender.removeAll()
        }
        guard benchFrames > 0 else { return }
        // Skip the first renders: shader pipelines and buffers warm up.
        if benchCount >= 10 { benchRender.append(renderMs) } else { benchStart = now }
        benchCount += 1
        if benchCount == benchFrames + 10 {
            let s = benchRender.sorted()
            let report = String(format: "bench %dx%d %@ f/%.1f: %.1f renders/s wall | render mean %.2f ms, median %.2f, p95 %.2f, max %.2f (%d frames)",
                                width, height, lensOn ? body.lens.name : "pinhole",
                                body.viewingAperture, Double(s.count) / (now - benchStart),
                                s.reduce(0, +) / Double(s.count), s[s.count / 2],
                                s[Int(Double(s.count) * 0.95)], s.last!, s.count)
            benchFrames = 0
            onBenchDone?(report)
        }
    }
}
