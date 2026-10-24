import AppKit
import Metal
import UniformTypeIdentifiers

/// A sky for scans whose own sky was cut away: an equirectangular .hdr shown
/// wherever the scan leaves the view empty, turned and brightened to suit.
struct SkySetting: Codable, Equatable {
    var path: String
    var yawDegrees: Float = 0
    var stops: Float = 0

    var name: String { (path as NSString).lastPathComponent }

    /// Remembered with each scan.
    static func remembered(scene: String) -> SkySetting? {
        guard let d = UserDefaults.standard.data(forKey: "sky:" + scene) else { return nil }
        return try? JSONDecoder().decode(SkySetting.self, from: d)
    }
    static func remember(_ s: SkySetting?, scene: String) {
        if let s, let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "sky:" + scene) }
        else { UserDefaults.standard.removeObject(forKey: "sky:" + scene) }
    }

    static func choose() -> String? {
        let p = NSOpenPanel()
        p.title = "Choose a sky (.hdr, equirectangular)"
        p.allowedContentTypes = [UTType(filenameExtension: "hdr") ?? .data, UTType(filenameExtension: "exr") ?? .data]
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

/// The sky loaded on the GPU: half-float RGBA with mipmaps (the finder blurs
/// an out-of-focus sky by reading a smaller level), and `level`, the scale
/// that puts the sky's middle brightness where a scan's sky usually sits.
struct SkyTexture {
    let texture: MTLTexture
    let level: Float

    static func load(_ path: String, device: MTLDevice, queue: MTLCommandQueue) -> SkyTexture? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = min(img.width, 4096), h = max(1, w / 2)
        guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = ctx.data?.bindMemory(to: Float.self, capacity: w * h * 4) else { return nil }
        // The upper half's median brightness (CGContext rows run bottom up: the top is the first rows in memory).
        var lums: [Float] = []
        for y in stride(from: 0, to: h / 2, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let i = (y * w + x) * 4
                lums.append(0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2])
            }
        }
        lums.sort()
        let median = lums.isEmpty ? 1 : max(lums[lums.count / 2], 1e-4)
        var half = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            half[4 * i] = Float16(max(px[4 * i], 0)); half[4 * i + 1] = Float16(max(px[4 * i + 1], 0))
            half[4 * i + 2] = Float16(max(px[4 * i + 2], 0)); half[4 * i + 3] = 1
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        half.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        if let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: tex)
            b.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return SkyTexture(texture: tex, level: 0.75 / median)
    }
}
