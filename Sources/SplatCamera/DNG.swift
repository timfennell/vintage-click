import Foundation

/// Writes a digital negative: a DNG 1.4 "LinearRaw" image (already in RGB,
/// no mosaic) of 16-bit floating-point linear light, so highlights past white
/// survive for the raw developer. The colour matrix says the RGB is linear
/// Rec.709 / sRGB primaries under D65, which is what the renderer works in.
enum DNG {
    /// `pixels`: width x height x 3 half floats (little-endian), linear light.
    static func write(_ pixels: Data, width: Int, height: Int, to url: URL,
                      description: String, lens: String, iso: Float, shutterSeconds: Float, fNumber: Float,
                      focalMM: Float) throws {
        var ifd: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])] = []
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func short(_ tag: UInt16, _ vals: [UInt16]) { ifd.append((tag, 3, UInt32(vals.count), vals.flatMap(le16))) }
        func long(_ tag: UInt16, _ vals: [UInt32]) { ifd.append((tag, 4, UInt32(vals.count), vals.flatMap(le32))) }
        func byte(_ tag: UInt16, _ vals: [UInt8]) { ifd.append((tag, 1, UInt32(vals.count), vals)) }
        func ascii(_ tag: UInt16, _ s: String) {
            let b = Array(s.utf8) + [0]
            ifd.append((tag, 2, UInt32(b.count), b))
        }
        func rational(_ tag: UInt16, _ vals: [Double], signed: Bool) {
            var bytes: [UInt8] = []
            for v in vals {
                let den: Int32 = 1_000_000
                let num = Int32((v * Double(den)).rounded())
                bytes += signed ? le32(UInt32(bitPattern: num)) : le32(UInt32(max(0, num)))
                bytes += le32(UInt32(den))
            }
            ifd.append((tag, signed ? 10 : 5, UInt32(vals.count), bytes))
        }

        let imageBytes = width * height * 6
        // Layout: header (8) | image data | IFD | values that do not fit in 4 bytes.
        let dataOffset: UInt32 = 8

        long(254, [0])                                   // NewSubFileType: the main image
        long(256, [UInt32(width)])
        long(257, [UInt32(height)])
        short(258, [16, 16, 16])                         // BitsPerSample
        short(259, [1])                                  // Compression: none
        short(262, [34892])                              // PhotometricInterpretation: LinearRaw
        ascii(270, description)                          // ImageDescription
        ascii(271, "Splat Camera")                       // Make
        ascii(272, lens)                                 // Model
        long(273, [dataOffset])                          // StripOffsets
        short(274, [1])                                  // Orientation
        short(277, [3])                                  // SamplesPerPixel
        long(278, [UInt32(height)])                      // RowsPerStrip
        long(279, [UInt32(imageBytes)])                  // StripByteCounts
        short(284, [1])                                  // PlanarConfiguration: chunky
        ascii(305, "Splat Camera")                       // Software
        short(339, [3, 3, 3])                            // SampleFormat: IEEE float
        rational(33434, [Double(shutterSeconds)], signed: false)   // ExposureTime
        rational(33437, [Double(fNumber)], signed: false)          // FNumber
        short(34855, [UInt16(min(65535, max(1, iso)))])            // ISOSpeedRatings
        rational(37386, [Double(focalMM)], signed: false)          // FocalLength
        byte(50706, [1, 4, 0, 0])                        // DNGVersion 1.4
        byte(50707, [1, 4, 0, 0])                        // DNGBackwardVersion 1.4
        ascii(50708, "Splat Camera")                     // UniqueCameraModel
        // ColorMatrix1: XYZ (D65) to the camera's RGB, which is linear sRGB.
        long(50717, [1, 1, 1])                           // WhiteLevel: 1.0 is white for float data (brighter is kept)
        rational(50721, [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570], signed: true)
        rational(50728, [1, 1, 1], signed: false)        // AsShotNeutral: already balanced
        rational(50730, [0], signed: true)               // BaselineExposure
        short(50778, [21])                               // CalibrationIlluminant1: D65
        ifd.sort { $0.tag < $1.tag }

        var out = Data()
        out.append(contentsOf: [0x49, 0x49, 42, 0])      // "II", 42: little-endian TIFF
        let ifdOffset = 8 + imageBytes + (imageBytes % 2)
        out.append(contentsOf: le32(UInt32(ifdOffset)))
        out.append(pixels.prefix(imageBytes))
        if imageBytes % 2 == 1 { out.append(0) }
        // The IFD, then the out-of-line values.
        let ifdSize = 2 + ifd.count * 12 + 4
        var extra = Data()
        var entries = Data()
        entries.append(contentsOf: le16(UInt16(ifd.count)))
        for e in ifd {
            entries.append(contentsOf: le16(e.tag))
            entries.append(contentsOf: le16(e.type))
            entries.append(contentsOf: le32(e.count))
            if e.value.count <= 4 {
                entries.append(contentsOf: e.value + [UInt8](repeating: 0, count: 4 - e.value.count))
            } else {
                let off = UInt32(ifdOffset + ifdSize + extra.count)
                entries.append(contentsOf: le32(off))
                extra.append(contentsOf: e.value)
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }
        entries.append(contentsOf: le32(0))              // no next IFD
        out.append(entries)
        out.append(extra)
        try out.write(to: url)
    }
}
