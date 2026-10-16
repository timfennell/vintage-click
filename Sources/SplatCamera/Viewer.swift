import AppKit
import CSpirula
import Foundation
import MetalKit
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    return o;
}

struct Params { uint w; uint h; uint pad0; uint pad1; float4 bg; };

// The splat frame as Spirula left it: W*H float3 premultiplied rgb, then W*H
// transmittance. The drawable is the frame's size, so pixels map 1:1.
fragment float4 composite(VOut in [[stage_in]], device const float* f [[buffer(0)]],
                          constant Params& P [[buffer(1)]]) {
    uint x = min(uint(in.pos.x), P.w - 1), y = min(uint(in.pos.y), P.h - 1);
    uint i = y * P.w + x;
    float3 c = float3(f[3 * i], f[3 * i + 1], f[3 * i + 2]);
    float T = f[P.w * P.h * 3 + i];
    return float4(saturate(c + T * P.bg.rgb), 1);
}
"""

struct SpirulaError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: sr_last_error()))" }
}

/// Real-time viewer: Spirula renders each frame into a GPU buffer that Metal
/// reads directly (no CPU readback), the pad flies the camera.
final class Viewer: NSObject, MTKViewDelegate {
    let width: Int, height: Int
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var frames: [(MTLBuffer, Int)] = []
    private let inFlight: DispatchSemaphore
    private var frameIndex = 0

    /// Frame cadence for play (the film look); 0 = as fast as it renders.
    var filmFPS: Double = 24
    var camera = FlyCamera()
    private var home = FlyCamera()
    private let center: SIMD3<Float>
    private let radius: Float
    private let fullDegree: Int32
    private var degree: Int32
    private let input = GamepadInput()
    private let background: SIMD4<Float> = [0.08, 0.08, 0.09, 1]

    // Timing
    private var lastTime = CACurrentMediaTime()
    private var statStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statRender: [Double] = []
    var onStats: ((String) -> Void)?

    // Scripted benchmark: orbit for `benchFrames` frames, then report and quit.
    var benchFrames = 0
    private var benchCount = 0
    private var benchRender: [Double] = []
    private var benchStart = 0.0
    var onBenchDone: ((String) -> Void)?

    init(model: SplatModel, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        fullDegree = Int32(model.shDegree)
        degree = fullDegree
        let b = model.bounds()
        center = b.center
        radius = b.radius

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

        let count = 2
        var bufs = [UnsafeMutableRawPointer?](repeating: nil, count: count)
        var offs = [Int](repeating: 0, count: count)
        if sr_shared_frames(Int32(width), Int32(height), Int32(count), &bufs, &offs) != 0 {
            throw SpirulaError("sharing frames with Metal")
        }
        for i in 0..<count {
            let buf = Unmanaged<MTLBuffer>.fromOpaque(bufs[i]!).takeUnretainedValue()
            frames.append((buf, offs[i]))
        }
        inFlight = DispatchSemaphore(value: count)
        // Draw on the GPU Spirula renders on, so the buffers are directly usable.
        device = frames[0].0.device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "fullscreen")
        pd.fragmentFunction = lib.makeFunction(name: "composite")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: pd)
        super.init()

        camera.moveSpeed = radius * 0.6
        resetView()
    }

    private func resetView() {
        let keepUp = camera.up
        let focal = camera.focalMM
        camera = FlyCamera()
        camera.up = keepUp
        camera.focalMM = focal
        camera.moveSpeed = radius * 0.6
        // Back off far enough to frame the subject, a little above it.
        let dist = radius * 1.2 * camera.focalMM / 36 + radius
        var c = FlyCamera()   // yaw 0, pitch 0: looking along the horizon
        c.up = keepUp
        let fwd = c.forward
        let eye = center - fwd * dist + keepUp * radius * 0.35
        camera.lookAt(center, from: eye)
        home = camera
    }

    private func cycleUp() {
        let axes: [SIMD3<Float>] = [[0, -1, 0], [0, 0, 1], [0, 1, 0], [0, 0, -1], [1, 0, 0], [-1, 0, 0]]
        let i = axes.firstIndex(of: camera.up) ?? 0
        camera.up = axes[(i + 1) % axes.count]
        resetView()
        print("Up axis: \(camera.up)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now

        if benchFrames > 0 {
            if benchCount == 0 { benchStart = now }
            // One full orbit around the subject, looking at it.
            let a = Float(benchCount) / Float(benchFrames) * 2 * .pi
            var c = FlyCamera()
            c.up = camera.up
            let a0 = c.forward, b0 = simd_cross(camera.up, a0)
            let dist = simd_distance(home.position, center)
            let around: SIMD3<Float> = cos(a) * -a0 + sin(a) * b0
            let lift: SIMD3<Float> = camera.up * (radius * 0.35)
            let eye = center + around * dist + lift
            camera.lookAt(center, from: eye)
        } else {
            let (fly, pressed) = input.poll()
            if pressed.contains(.reset) { camera = home }
            if pressed.contains(.cycleUp) { cycleUp() }
            if pressed.contains(.toggleSH) {
                degree = degree == fullDegree ? 0 : fullDegree
                sr_set_render_degree(degree)
                print("SH degree: \(degree)")
            }
            if pressed.contains(.faster) { camera.moveSpeed *= 1.5 }
            if pressed.contains(.slower) { camera.moveSpeed /= 1.5 }
            if pressed.contains(.still) { saveStill() }
            camera.update(fly, dt: dt)
        }

        inFlight.wait()
        let slot = frameIndex % frames.count
        frameIndex += 1
        let fx = camera.focalPixels(width: width)
        let t0 = CACurrentMediaTime()
        let rc = camera.viewMatrix.withUnsafeBufferPointer {
            sr_render_to_frame(Int32(slot), $0.baseAddress, fx, fx, Float(width) / 2,
                               Float(height) / 2, "3dgs")
        }
        let renderMs = (CACurrentMediaTime() - t0) * 1000
        if rc != 0 {
            inFlight.signal()
            print(SpirulaError("render"))
            return
        }

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            inFlight.signal()
            return
        }
        var params = (UInt32(width), UInt32(height), UInt32(0), UInt32(0), background)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(frames[slot].0, offset: frames[slot].1, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout.size(ofValue: params), index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        // A film cadence wants even frame spacing: hold each frame for its
        // full 1/fps (24 fps lands on every 5th refresh of a 120 Hz display).
        if filmFPS > 0 {
            cb.present(drawable, afterMinimumDuration: 1 / filmFPS)
        } else {
            cb.present(drawable)
        }
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()

        record(renderMs: renderMs, now: now)
    }

    private func record(renderMs: Double, now: Double) {
        statFrames += 1
        statRender.append(renderMs)
        if now - statStart >= 1 {
            let fps = Double(statFrames) / (now - statStart)
            let mean = statRender.reduce(0, +) / Double(statRender.count)
            let line = String(format: "%.1f fps | splat render %.1f ms (max %.1f) | %dx%d | %.0f mm | SH %d%@",
                              fps, mean, statRender.max() ?? 0, width, height, camera.focalMM, degree,
                              input.controllerName.map { " | \($0)" } ?? " | no controller")
            onStats?(line)
            statStart = now
            statFrames = 0
            statRender.removeAll()
        }
        if benchFrames > 0 {
            // Skip the first frames: shader pipelines and buffers warm up.
            if benchCount >= 10 { benchRender.append(renderMs) } else { benchStart = now }
            benchCount += 1
            if benchCount == benchFrames + 10 {
                let s = benchRender.sorted()
                let wall = now - benchStart
                let report = String(format: "bench %dx%d SH%d: %.1f fps wall | render mean %.2f ms, median %.2f, p95 %.2f, max %.2f (%d frames)",
                                    width, height, degree, Double(s.count) / wall,
                                    s.reduce(0, +) / Double(s.count), s[s.count / 2],
                                    s[Int(Double(s.count) * 0.95)], s.last!, s.count)
                benchFrames = 0
                onBenchDone?(report)
            }
        }
    }

    func setDegree(_ d: Int32) {
        degree = min(d, fullDegree)
        sr_set_render_degree(degree)
    }

    /// Full-quality still through the readback path, as a PNG.
    @discardableResult
    func saveStill(to url: URL? = nil) -> URL? {
        let w = width, h = height
        var rgb = [Float](repeating: 0, count: w * h * 3)
        var alpha = [Float](repeating: 0, count: w * h)
        let fx = camera.focalPixels(width: w)
        let rc = camera.viewMatrix.withUnsafeBufferPointer { vm in
            sr_render(vm.baseAddress, fx, fx, Float(w) / 2, Float(h) / 2, Int32(w), Int32(h),
                      "3dgs", &rgb, &alpha, nil)
        }
        guard rc == 0 else { print(SpirulaError("still")); return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = rgb[3 * i + c] + (1 - alpha[i]) * background[c]
                px[4 * i + c] = UInt8(max(0, min(1, v)) * 255 + 0.5)
            }
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Splat Camera")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = url ?? dir.appendingPathComponent("still-\(stamp).png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("Saved still: \(out.path)")
        return out
    }
}
