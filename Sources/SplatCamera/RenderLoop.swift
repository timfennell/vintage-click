import AppKit
import CSpirula
import Foundation
import Metal
import simd

struct SpirulaError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: sr_last_error()))" }
}

/// A finder frame to render: the camera at this moment through the lens wide open.
struct FinderJob {
    var view: [Float]
    var fx: Float
    var lens: [SIMD4<Float>]?
    var body: CameraBody
}

/// One exposure on its way through the camera: the scene as it was when the
/// shutter fired, added up sub-pupil by sub-pupil, then developed.
final class ExposureJob {
    let camera: FlyCamera
    let body: CameraBody          // settings at the moment of release
    let frameNumber: Int
    let cells: [SIMD2<Float>]
    var next = 0
    let accum: MTLBuffer
    let started = CACurrentMediaTime()
    var outputPath: URL?

    init(camera: FlyCamera, body: CameraBody, frameNumber: Int, cells: [SIMD2<Float>], accum: MTLBuffer) {
        self.camera = camera
        self.body = body
        self.frameNumber = frameNumber
        self.cells = cells
        self.accum = accum
    }
}

/// Owns Spirula: one thread does every render, alternating the live finder
/// with the next sub-pupil of the oldest exposure still on the film, so the
/// camera stays in your hands while frames develop behind it.
final class RenderLoop {
    let device: MTLDevice
    let finderSize: (w: Int, h: Int)
    let photoSize: (w: Int, h: Int)
    let background: SIMD4<Float>

    private let queue: MTLCommandQueue
    private let accumulatePSO: MTLComputePipelineState
    private let developPSO: MTLComputePipelineState
    private var finderSlots: [(buf: MTLBuffer, off: Int, index: Int32)] = []
    private let photoSlot: (buf: MTLBuffer, off: Int, index: Int32)

    // Shared with the main thread, under `cond`.
    private let cond = NSCondition()
    private var finderRequest: FinderJob?
    private var exposures: [ExposureJob] = []
    private var latest: (slot: Int, job: FinderJob)?
    private var displaying = [Int](repeating: 0, count: 4)

    /// Called on the main thread.
    var onFinderRendered: ((Double) -> Void)?
    var onDeveloped: ((ExposureJob, CGImage, Double) -> Void)?

    init(model: SplatModel, finder: (Int, Int), photo: (Int, Int), background: SIMD4<Float>,
         library: MTLLibrary? = nil) throws {
        finderSize = (finder.0, finder.1)
        photoSize = (photo.0, photo.1)
        self.background = background
        let ok = model.means.withUnsafeBufferPointer { m in
            model.quats.withUnsafeBufferPointer { q in
                model.scales.withUnsafeBufferPointer { s in
                    model.opacities.withUnsafeBufferPointer { o in
                        model.dc.withUnsafeBufferPointer { dc in
                            model.sh.withUnsafeBufferPointer { sh in
                                sr_set_splats(Int64(model.count), Int32(model.shDegree), m.baseAddress,
                                              q.baseAddress, s.baseAddress, o.baseAddress,
                                              dc.baseAddress, model.shDegree > 0 ? sh.baseAddress : nil)
                            }}}}}}
        if ok != 0 { throw SpirulaError("loading splats") }

        func frames(_ w: Int, _ h: Int, _ n: Int) throws -> [(MTLBuffer, Int, Int32)] {
            var bufs = [UnsafeMutableRawPointer?](repeating: nil, count: n)
            var offs = [Int](repeating: 0, count: n)
            var first: Int32 = 0
            if sr_add_shared_frames(Int32(w), Int32(h), Int32(n), &bufs, &offs, &first) != 0 {
                throw SpirulaError("sharing frames with Metal")
            }
            return (0..<n).map {
                (Unmanaged<MTLBuffer>.fromOpaque(bufs[$0]!).takeUnretainedValue(), offs[$0], first + Int32($0))
            }
        }
        // Four finder frames: the newest, up to two being displayed, one being rendered.
        finderSlots = try frames(finder.0, finder.1, 4).map { ($0.0, $0.1, $0.2) }
        let p = try frames(photo.0, photo.1, 1)[0]
        photoSlot = (p.0, p.1, p.2)
        // Draw on the GPU Spirula renders on, so the buffers are directly usable.
        device = p.0.device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        accumulatePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "accumulate")!)
        developPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "develop")!)

        let t = Thread { [weak self] in self?.run() }
        t.name = "Spirula render"
        t.qualityOfService = .userInteractive
        t.start()
    }

    // MARK: main-thread side

    /// Asks for a finder frame of this view (replacing any not yet started).
    func requestFinder(_ job: FinderJob) {
        cond.lock()
        finderRequest = job
        cond.signal()
        cond.unlock()
    }

    /// The newest finder frame, held for display until `release` is called.
    func acquireLatest() -> (buf: MTLBuffer, off: Int, slot: Int, job: FinderJob)? {
        cond.lock()
        defer { cond.unlock() }
        guard let l = latest else { return nil }
        displaying[l.slot] += 1
        let s = finderSlots[l.slot]
        return (s.buf, s.off, l.slot, l.job)
    }

    func release(slot: Int) {
        cond.lock()
        displaying[slot] -= 1
        cond.unlock()
    }

    var pendingExposures: Int {
        cond.lock()
        defer { cond.unlock() }
        return exposures.count
    }

    func makeAccumulator() -> MTLBuffer? {
        device.makeBuffer(length: photoSize.w * photoSize.h * 16, options: .storageModePrivate)
    }

    func expose(_ job: ExposureJob) {
        cond.lock()
        exposures.append(job)
        cond.signal()
        cond.unlock()
    }

    // MARK: render thread

    private func run() {
        while true {
            cond.lock()
            while finderRequest == nil && exposures.isEmpty { cond.wait() }
            let finder = finderRequest
            finderRequest = nil
            let exposure = exposures.first
            cond.unlock()
            if let finder { renderFinder(finder) }
            if let exposure { step(exposure) }
        }
    }

    private func setLens(_ params: [SIMD4<Float>]?) {
        let rc: Int32
        if let p = params {
            rc = p.withUnsafeBytes { sr_set_lens($0.baseAddress!.assumingMemoryBound(to: Float.self), Int32(p.count)) }
        } else {
            rc = sr_set_lens(nil, 0)
        }
        if rc != 0 { print(SpirulaError("lens")) }
    }

    private func render(_ index: Int32, view: [Float], fx: Float, cx: Float, cy: Float) -> Bool {
        let rc = view.withUnsafeBufferPointer {
            sr_render_to_frame(index, $0.baseAddress, fx, fx, cx, cy, "3dgs")
        }
        if rc != 0 { print(SpirulaError("render")) }
        return rc == 0
    }

    private func renderFinder(_ job: FinderJob) {
        cond.lock()
        let slot = (0..<finderSlots.count).first { $0 != latest?.slot && displaying[$0] == 0 }
        cond.unlock()
        guard let slot else { return }
        setLens(job.lens)
        let t0 = CACurrentMediaTime()
        let ok = render(finderSlots[slot].index, view: job.view, fx: job.fx,
                        cx: Float(finderSize.w) / 2, cy: Float(finderSize.h) / 2)
        let ms = (CACurrentMediaTime() - t0) * 1000
        guard ok else { return }
        cond.lock()
        latest = (slot, job)
        cond.unlock()
        DispatchQueue.main.async { [weak self] in self?.onFinderRendered?(ms) }
    }

    /// Optics for the shaders at photo size (layout in Shaders.swift).
    private func photoOptics(_ e: ExposureJob, fx: Float) -> [SIMD4<Float>] {
        let b = e.body, l = b.lens, n = b.takingAperture
        let (w, h) = photoSize
        return [
            SIMD4(Float(w), Float(h), fx, fx),
            SIMD4(Float(w) / 2, Float(h) / 2, b.metresPerUnit, b.focusM),
            SIMD4(l.focalMM / 1000, n, l.maxAperture, Float(l.blades)),
            SIMD4(l.catsEye, l.soapBubble, l.bladeRotation, l.vignette),
            background,
            SIMD4(0, 0, Float(b.rollNumber * 100 + e.frameNumber), b.exposureStops),
        ]
    }

    /// One sub-pupil of the exposure: render the view sheared to that lens
    /// point (focus plane fixed), add it to the film; develop after the last.
    private func step(_ e: ExposureJob) {
        let b = e.body
        let (w, h) = photoSize
        let n = b.takingAperture
        let fx = e.camera.focalPixels(width: w)
        let radiusUnits = b.lens.focalMM / 1000 / n / 2 / b.metresPerUnit
        let invFocus = b.metresPerUnit / b.focusM
        setLens(b.lensParams(fNumber: n, focalPx: fx, cells: e.cells.count, table: nil))

        let c = e.cells[e.next]
        let d = c * radiusUnits
        var vm = e.camera.viewMatrix
        vm[3] -= d.x
        vm[7] -= d.y
        guard render(photoSlot.index, view: vm, fx: fx, cx: Float(w) / 2 + fx * d.x * invFocus,
                     cy: Float(h) / 2 + fx * d.y * invFocus),
              let cb = queue.makeCommandBuffer() else {
            finish(e)
            return
        }
        var o = photoOptics(e, fx: fx)
        var l = SIMD4<Float>(c.x, c.y, 1, e.next == 0 ? 1 : 0)
        let grid = MTLSize(width: w, height: h, depth: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(accumulatePSO)
        ce.setBuffer(photoSlot.buf, offset: photoSlot.off, index: 0)
        ce.setBytes(&o, length: o.count * 16, index: 1)
        ce.setBuffer(e.accum, offset: 0, index: 2)
        ce.setBytes(&l, length: 16, index: 3)
        ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        e.next += 1
        let done = e.next == e.cells.count
        var print: MTLBuffer?
        if done, let out = device.makeBuffer(length: w * h * 4, options: .storageModeShared) {
            print = out
            // Light through the unclipped centre of the frame sets the scale.
            let full = e.cells.reduce(Float(0)) { $0 + pupilWeight($1, q: .zero, lens: b.lens, fNumber: n) }
            var dv = SIMD4<Float>(1 / max(full, 1e-6), 0, 0, 0)
            var f = b.stock.packed
            ce.setComputePipelineState(developPSO)
            ce.setBuffer(e.accum, offset: 0, index: 0)
            ce.setBytes(&o, length: o.count * 16, index: 1)
            ce.setBytes(&f, length: f.count * 16, index: 2)
            ce.setBytes(&dv, length: 16, index: 3)
            ce.setBuffer(out, offset: 0, index: 4)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        }
        ce.endEncoding()
        cb.commit()
        // The photo frame is rendered into again next step: let this read finish.
        cb.waitUntilCompleted()
        if done {
            finish(e)
            if let print, let image = makeImage(print, w, h) {
                let seconds = CACurrentMediaTime() - e.started
                DispatchQueue.main.async { [weak self] in self?.onDeveloped?(e, image, seconds) }
            }
        }
    }

    private func finish(_ e: ExposureJob) {
        cond.lock()
        exposures.removeAll { $0 === e }
        cond.unlock()
    }

    private func makeImage(_ buf: MTLBuffer, _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(bytes: buf.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
