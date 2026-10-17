// Draws the app icon: the finder itself. A frosted focusing screen you can
// see through, the lens's vignetting, faint fresnel rings, the split-image
// circle (an out-of-focus post broken across it) in its microprism collar,
// the meter's scale as projected light with the needle nearly on its mark,
// and red LEDs on the black body below.
//
//   swiftc tools/make_icon.swift -o build/make_icon && build/make_icon Resources
//
// writes Resources/AppIcon-1024.png and Resources/AppIcon.icns.
import AppKit
import CoreImage

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let S: CGFloat = 1024

struct Grit {
    var state: UInt64
    mutating func unit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 1_000_000) / 1_000_000
    }
}

func draw(_ ctx: CGContext) {
    // Flipped: y down, as the game's views.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    var rng = Grit(state: 1977)

    // The camera's body around the eyepiece: black, faintly textured, a worn edge.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.05, alpha: 1)])?.draw(in: bodyPath, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    for _ in 0..<5000 {
        let r = 0.6 + 1.4 * rng.unit()
        NSColor(white: rng.unit() < 0.5 ? 0 : 0.3, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX + rng.unit() * body.width, y: body.minY + rng.unit() * body.height,
                                    width: r, height: r)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    bodyPath.lineWidth = 3
    NSColor(white: 0.32, alpha: 0.8).setStroke()
    bodyPath.stroke()

    // The focusing screen: 3:2, frosted, see-through.
    let screen = NSRect(x: 168, y: 236, width: 688, height: 459)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 34, yRadius: 34)
    NSGraphicsContext.saveGraphicsState()
    ctx.setBlendMode(.copy)
    NSColor(calibratedRed: 0.86, green: 0.83, blue: 0.74, alpha: 0.58).setFill()
    screenPath.fill()
    ctx.setBlendMode(.normal)
    screenPath.addClip()
    let c = NSPoint(x: screen.midX, y: screen.midY)
    // Something beyond, soft: a warm glow upper right, a dark mass lower left.
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.85, blue: 0.6, alpha: 0.35), NSColor(white: 1, alpha: 0)])?
        .draw(fromCenter: NSPoint(x: screen.maxX - 150, y: screen.minY + 110), radius: 0,
              toCenter: NSPoint(x: screen.maxX - 150, y: screen.minY + 110), radius: 260, options: [])
    NSGradient(colors: [NSColor(calibratedRed: 0.2, green: 0.15, blue: 0.1, alpha: 0.35), NSColor(white: 0, alpha: 0)])?
        .draw(fromCenter: NSPoint(x: screen.minX + 190, y: screen.maxY - 90), radius: 0,
              toCenter: NSPoint(x: screen.minX + 190, y: screen.maxY - 90), radius: 280, options: [])
    // The post, out of focus, through the whole screen.
    let postColour = NSColor(calibratedRed: 0.12, green: 0.09, blue: 0.07, alpha: 0.6)
    NSGradient(colors: [postColour.withAlphaComponent(0), postColour, postColour, postColour.withAlphaComponent(0)],
               atLocations: [0, 0.35, 0.65, 1], colorSpace: .deviceRGB)?
        .draw(in: NSRect(x: c.x - 40, y: screen.minY, width: 110, height: screen.height), angle: 0)
    // Ground glass tooth.
    for _ in 0..<9000 {
        let r = 0.7 + rng.unit()
        NSColor(white: rng.unit() < 0.5 ? 0 : 1, alpha: 0.05).setFill()
        NSBezierPath(ovalIn: NSRect(x: screen.minX + rng.unit() * screen.width, y: screen.minY + rng.unit() * screen.height,
                                    width: r, height: r)).fill()
    }
    // Fresnel rings.
    var rr: CGFloat = 20
    while rr < 480 {
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
        ring.lineWidth = 1.2
        NSColor(white: 0, alpha: 0.05).setStroke()
        ring.stroke()
        rr += 15
    }
    // Microprism collar: a scatter of tiny facets, light and dark.
    let outer: CGFloat = 158, inner: CGFloat = 92
    let cell: CGFloat = 5.5
    var gy = c.y - outer
    while gy < c.y + outer {
        var gx = c.x - outer
        while gx < c.x + outer {
            let d = hypot(gx + cell / 2 - c.x, gy + cell / 2 - c.y)
            if d > inner + 2, d < outer {
                NSColor(white: rng.unit() < 0.5 ? 0.05 : 1, alpha: 0.06 + 0.14 * rng.unit()).setFill()
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: gx, y: gy + cell))
                tri.line(to: NSPoint(x: gx + cell / 2, y: gy))
                tri.line(to: NSPoint(x: gx + cell, y: gy + cell))
                tri.close()
                tri.fill()
            }
            gx += cell
        }
        gy += cell
    }
    for r in [inner, outer] {
        let edge = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        edge.lineWidth = 2.5
        NSColor(white: 0, alpha: 0.4).setStroke()
        edge.stroke()
    }
    // The split image: the post, sharper, broken across the line.
    let split = NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
    NSGraphicsContext.saveGraphicsState()
    split.addClip()
    NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.79, alpha: 0.5).setFill()
    split.fill()
    let ink = NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.08, alpha: 0.85)
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: c.x - 26, y: c.y - inner, width: 34, height: inner), xRadius: 3, yRadius: 3).fill()
    NSBezierPath(roundedRect: NSRect(x: c.x + 18, y: c.y, width: 34, height: inner), xRadius: 3, yRadius: 3).fill()
    NSColor(white: 0, alpha: 0.55).setFill()
    NSRect(x: c.x - inner, y: c.y - 1.5, width: 2 * inner, height: 3).fill()
    NSGraphicsContext.restoreGraphicsState()
    // Grain and dust in the screen: it is seen, not drawn.
    for _ in 0..<26000 {
        let r = 0.8 + 1.6 * rng.unit()
        NSColor(white: rng.unit() < 0.5 ? 0 : 1, alpha: 0.07).setFill()
        NSBezierPath(ovalIn: NSRect(x: screen.minX + rng.unit() * screen.width, y: screen.minY + rng.unit() * screen.height,
                                    width: r, height: r)).fill()
    }
    for _ in 0..<14 {
        let r = 1.5 + 3 * rng.unit()
        NSColor(white: 0.1, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: screen.minX + rng.unit() * screen.width, y: screen.minY + rng.unit() * screen.height,
                                    width: r, height: r * 0.8)).fill()
    }
    // The lens's vignetting and the condenser's: darker toward the corners.
    NSGradient(colors: [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.05), NSColor(white: 0, alpha: 0.6)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: hypot(screen.width, screen.height) / 2, options: [])
    NSGraphicsContext.restoreGraphicsState()
    screenPath.lineWidth = 3
    NSColor(white: 0, alpha: 0.6).setStroke()
    screenPath.stroke()

    // The meter's scale, projected light inside the frame's left edge.
    let cream = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.80, alpha: 1)
    let red = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.30, alpha: 1)
    let plate = NSRect(x: screen.minX + 20, y: screen.minY + 46, width: 88, height: screen.height - 92)
    let pivot = NSPoint(x: body.minX - 30, y: plate.midY)
    let glow = NSShadow()
    glow.shadowBlurRadius = 9
    glow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    glow.shadowColor = cream.withAlphaComponent(0.5)
    glow.set()
    cream.withAlphaComponent(0.13).setFill()
    NSBezierPath(roundedRect: plate, xRadius: 10, yRadius: 10).fill()
    red.withAlphaComponent(0.7).setFill()
    NSBezierPath(roundedRect: NSRect(x: plate.minX, y: plate.minY, width: plate.width, height: 26), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: plate.minX, y: plate.maxY - 26, width: plate.width, height: 26), xRadius: 8, yRadius: 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    let speeds = ["1000", "500", "250", "125", "60", "30", "15"]
    let step = (plate.height - 64) / CGFloat(speeds.count)
    func rowY(_ i: CGFloat) -> CGFloat { plate.minY + 32 + (i + 0.5) * step }
    for (i, label) in speeds.enumerated() {
        let slow = i >= 5
        let colour = slow ? red : cream
        let y = rowY(CGFloat(i))
        let shadow = NSShadow()
        shadow.shadowColor = colour.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Futura-Medium", size: 21) ?? NSFont.systemFont(ofSize: 21, weight: .medium),
            .foregroundColor: colour.withAlphaComponent(0.92), .shadow: shadow,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: plate.maxX - sz.width - 6, y: y - sz.height / 2))
        // Ticks point at the needle's pivot.
        let p0 = NSPoint(x: plate.minX + 4, y: y)
        let dx = p0.x - pivot.x, dy = p0.y - pivot.y, len = hypot(dx, dy)
        let tick = NSBezierPath()
        tick.move(to: p0)
        tick.line(to: NSPoint(x: p0.x + dx / len * 12, y: p0.y + dy / len * 12))
        tick.lineWidth = 3
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        colour.withAlphaComponent(0.9).setStroke()
        tick.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    // The green tab at 1/125, the needle a hair off it.
    let ty = rowY(3)
    NSGraphicsContext.saveGraphicsState()
    let tabGlow = NSShadow()
    tabGlow.shadowColor = NSColor(calibratedRed: 0.45, green: 0.95, blue: 0.7, alpha: 0.6)
    tabGlow.shadowBlurRadius = 8
    tabGlow.set()
    NSColor(calibratedRed: 0.45, green: 0.95, blue: 0.70, alpha: 0.85).setFill()
    let tab = NSBezierPath()
    tab.move(to: NSPoint(x: plate.maxX - 2, y: ty - 16))
    tab.line(to: NSPoint(x: plate.maxX + 26, y: ty - 9))
    tab.line(to: NSPoint(x: plate.maxX + 26, y: ty + 9))
    tab.line(to: NSPoint(x: plate.maxX - 2, y: ty + 16))
    tab.close()
    tab.fill()
    NSGraphicsContext.restoreGraphicsState()
    let aim = NSPoint(x: plate.minX + 4, y: ty - 5)
    let reach = (plate.maxX + 34 - pivot.x) / (aim.x - pivot.x)
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: screen.minX - 4, y: pivot.y + (aim.y - pivot.y) * (screen.minX - 4 - pivot.x) / (aim.x - pivot.x)))
    needle.line(to: NSPoint(x: pivot.x + (aim.x - pivot.x) * reach, y: pivot.y + (aim.y - pivot.y) * reach))
    needle.lineWidth = 4.5
    needle.lineCapStyle = .round
    let needleShadow = NSShadow()
    needleShadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    needleShadow.shadowBlurRadius = 6
    needleShadow.shadowOffset = NSSize(width: 5, height: 6)
    NSGraphicsContext.saveGraphicsState()
    needleShadow.set()
    NSColor(white: 0.04, alpha: 0.92).setStroke()
    needle.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Red LEDs on the body below: aperture and speed.
    let ledRed = NSColor(calibratedRed: 1.0, green: 0.16, blue: 0.10, alpha: 1)
    let ledGlow = NSShadow()
    ledGlow.shadowColor = ledRed.withAlphaComponent(0.85)
    ledGlow.shadowBlurRadius = 14
    ledGlow.shadowOffset = .zero
    let led: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Menlo-Bold", size: 64) ?? NSFont.monospacedSystemFont(ofSize: 64, weight: .bold),
        .foregroundColor: ledRed, .shadow: ledGlow, .kern: 4,
    ]
    for (text, x) in [("F2", screen.minX + 120), ("125", screen.maxX - 250)] {
        NSAttributedString(string: text, attributes: led).draw(at: NSPoint(x: x, y: screen.maxY + 42))
    }
}

func png(_ size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    NSGraphicsContext.saveGraphicsState()
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    guard let sharp = ctx.makeImage() else { return nil }
    // Seen through an eyepiece: everything a touch soft.
    let ci = CIImage(cgImage: sharp)
    let soft = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.3 * CGFloat(size) / S])
        .cropped(to: ci.extent)
    guard let img = CIContext().createCGImage(soft, from: ci.extent) else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

let fm = FileManager.default
try? fm.createDirectory(at: out, withIntermediateDirectories: true)
let set = out.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base)?.write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2)?.write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024)?.write(to: out.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: set)
print("Wrote \(out.path)/AppIcon.icns")
