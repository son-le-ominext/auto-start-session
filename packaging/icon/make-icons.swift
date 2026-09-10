//
//  make-icons.swift -- draws every icon this project ships, from source.
//
//  The mark is a clock reading seven o'clock: one hand straight up, one down
//  to the left. That angle is the whole point of the app, and it survives
//  being shrunk to sixteen pixels, which a sunrise or a wordmark would not.
//
//  Palette is the project's own: ink ground, slate bezel, amber hands, with a
//  warm glow low in the tile for the dawn the app exists to sit in front of.
//
//  Usage:  make-icons <output-directory>
//

import AppKit
import Foundation

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

enum Ink {
    static let top    = rgb(0x2B3547)
    static let bottom = rgb(0x131922)
    static let glow   = rgb(0xFFC178, 0.30)
    static let bezel  = rgb(0x5D6B82)
    static let hands  = rgb(0xF2A24A)
    static let pin    = rgb(0xF2F4F7)
    static let rim    = rgb(0xFFFFFF, 0.07)
    static let white  = rgb(0xFFFFFF)
}

enum State: String, CaseIterable {
    case ok, failed, working, never, notScheduled

    var colour: CGColor {
        switch self {
        case .ok:      return rgb(0x2E9E63)
        case .failed:  return rgb(0xD8483F)
        case .working: return rgb(0xE08A2E)
        case .never, .notScheduled: return rgb(0x74829A)
        }
    }
}

// MARK: - Geometry

/// Apple's rounded rectangle is a superellipse, not a circle-cornered rect.
/// Tracing one keeps the tile from looking subtly wrong beside system icons.
func superellipse(in rect: CGRect, n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * CGFloat(sign(ct)) * pow(abs(ct), 2 / n)
        let y = cy + b * CGFloat(sign(st)) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

/// A clock hand, measured clockwise from twelve.
func hand(_ ctx: CGContext, centre: CGPoint, degrees: CGFloat,
          length: CGFloat, width: CGFloat, colour: CGColor) {
    let r = degrees * .pi / 180
    let end = CGPoint(x: centre.x + sin(r) * length, y: centre.y + cos(r) * length)
    ctx.setStrokeColor(colour)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: centre)
    ctx.addLine(to: end)
    ctx.strokePath()
}

// MARK: - The drawings

/// The application icon: a tile for the Dock, Launchpad and the installer.
func drawAppTile(_ ctx: CGContext, side: CGFloat) {
    let s = side / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = superellipse(in: tile)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    if let g = CGGradient(colorsSpace: space,
                          colors: [Ink.top, Ink.bottom] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    }
    // Dawn, low in the tile.
    if let glow = CGGradient(colorsSpace: space,
                             colors: [Ink.glow, rgb(0xF0A14E, 0)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 150), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 150), endRadius: 540, options: [])
    }
    ctx.restoreGState()

    // Rim light, so the tile has an edge on a dark desktop.
    ctx.addPath(shape)
    ctx.setStrokeColor(Ink.rim)
    ctx.setLineWidth(3)
    ctx.strokePath()

    let centre = CGPoint(x: 512, y: 512)
    ctx.setStrokeColor(Ink.bezel)
    ctx.setLineWidth(30)
    ctx.addArc(center: centre, radius: 272, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    hand(ctx, centre: centre, degrees: 0,   length: 196, width: 34, colour: Ink.hands)
    hand(ctx, centre: centre, degrees: 210, length: 140, width: 42, colour: Ink.hands)

    ctx.setFillColor(Ink.pin)
    ctx.addArc(center: centre, radius: 26, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    ctx.restoreGState()
}

/// A notification-area icon: the same clock, knocked out of a state-coloured
/// disc. At sixteen pixels a filled disc reads where a drawn bezel does not.
func drawStateDisc(_ ctx: CGContext, side: CGFloat, state: State) {
    let s = side / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    let centre = CGPoint(x: 512, y: 512)
    ctx.setFillColor(state.colour)
    ctx.addArc(center: centre, radius: 496, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Heavier than the tile's hands on purpose: at sixteen pixels these are
    // barely more than a pixel wide, and anything finer disappears.
    hand(ctx, centre: centre, degrees: 0,   length: 288, width: 98, colour: Ink.white)
    hand(ctx, centre: centre, degrees: 210, length: 208, width: 110, colour: Ink.white)

    ctx.restoreGState()
}

// MARK: - Encoding

func bitmap(_ side: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(side))
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! data.write(to: url)
}

/// A Windows .ico holding PNG-compressed entries, which every Windows since
/// Vista reads. Keeps the file small and the edges clean.
func ico(sizes: [Int], _ draw: @escaping (CGContext, CGFloat) -> Void) -> Data {
    let images = sizes.map { png(bitmap($0, draw)) }
    var out = Data()
    var n = UInt16(0)
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

    u16(0); u16(1); n = UInt16(sizes.count); u16(n)
    var offset = UInt32(6 + 16 * sizes.count)
    for (i, size) in sizes.enumerated() {
        out.append(UInt8(size >= 256 ? 0 : size))     // 0 means 256
        out.append(UInt8(size >= 256 ? 0 : size))
        out.append(0)                                  // palette
        out.append(0)                                  // reserved
        u16(1)                                         // colour planes
        u16(32)                                        // bits per pixel
        u32(UInt32(images[i].count))
        u32(offset)
        offset += UInt32(images[i].count)
    }
    for image in images { out.append(image) }
    return out
}

// MARK: - Main

let root = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

// macOS iconset, handed to iconutil by the shell wrapper.
let iconset = root.appending(path: "packaging/icon/build/AppIcon.iconset")
let appleSizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in appleSizes {
    write(png(bitmap(size) { c, s in drawAppTile(c, side: s) }),
          iconset.appending(path: "\(name).png"))
}

// Windows application icon.
write(ico(sizes: [16, 24, 32, 48, 64, 128, 256]) { c, s in drawAppTile(c, side: s) },
      root.appending(path: "windows/icons/app.ico"))

// Windows notification area, one per state, at every DPI Windows asks for.
for state in State.allCases {
    write(ico(sizes: [16, 20, 24, 32, 40, 48, 64]) { c, s in drawStateDisc(c, side: s, state: state) },
          root.appending(path: "windows/icons/\(state.rawValue).ico"))
}

// Sheets to look at while designing.
write(png(bitmap(512) { c, s in drawAppTile(c, side: s) }),
      root.appending(path: "packaging/icon/build/preview-app-512.png"))
write(png(bitmap(128) { c, s in drawAppTile(c, side: s) }),
      root.appending(path: "packaging/icon/build/preview-app-128.png"))
write(png(bitmap(32) { c, s in drawAppTile(c, side: s) }),
      root.appending(path: "packaging/icon/build/preview-app-32.png"))
for state in State.allCases {
    write(png(bitmap(128) { c, s in drawStateDisc(c, side: s, state: state) }),
          root.appending(path: "packaging/icon/build/preview-\(state.rawValue)-128.png"))
    write(png(bitmap(16) { c, s in drawStateDisc(c, side: s, state: state) }),
          root.appending(path: "packaging/icon/build/preview-\(state.rawValue)-16.png"))
}

print("icons written under \(root.path)")
