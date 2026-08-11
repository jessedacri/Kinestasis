#!/usr/bin/env swift
// Renders 5 Kinestasis app-icon concepts at 1024 px into
// build/icon-concepts/ plus dock-size previews. Brand: KineTheme
// near-black #18161B, panel #1E1C22, amber #F0A030.

import AppKit
import CoreGraphics

let S: CGFloat = 1024
let outDir = URL(fileURLWithPath: "build/icon-concepts", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ink = color(0x18161B)
let inkTop = color(0x232028)
let panel = color(0x1E1C22)
let amber = color(0xF0A030)
let amberDeep = color(0xC97F1E)
let offWhite = color(0xEDE8E0)

func ctx1024() -> CGContext {
    let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return c
}

/// Big Sur canvas: 824 pt squircle centered, soft drop shadow.
func squircleBase(_ c: CGContext, gradientTop: CGColor = ink, gradientBottom: CGColor? = nil) -> CGRect {
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: box, cornerWidth: 184, cornerHeight: 184, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.45))
    c.addPath(path)
    c.setFillColor(ink)
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path)
    c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [inkTop, gradientBottom ?? ink] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: S/2, y: box.maxY), end: CGPoint(x: S/2, y: box.minY), options: [])
    c.restoreGState()
    return box
}

func clipSquircle(_ c: CGContext, _ box: CGRect) {
    c.addPath(CGPath(roundedRect: box, cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.clip()
}

func playTriangle(_ c: CGContext, center: CGPoint, r: CGFloat, fill: CGColor) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x + r, y: center.y))
    p.addLine(to: CGPoint(x: center.x - r * 0.5, y: center.y + r * 0.866))
    p.addLine(to: CGPoint(x: center.x - r * 0.5, y: center.y - r * 0.866))
    p.closeSubpath()
    c.addPath(p)
    c.setFillColor(fill)
    c.fillPath()
}

func save(_ c: CGContext, _ name: String) {
    let img = c.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

// ── 1. Strip: diagonal filmstrip, dot walking frame to frame ─────────
func concept1() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState()
    clipSquircle(c, box)

    c.translateBy(x: S/2, y: S/2)
    c.rotate(by: -.pi / 8)
    let stripW: CGFloat = 340
    let frameH: CGFloat = 252
    c.setFillColor(panel)
    c.fill(CGRect(x: -stripW/2, y: -900, width: stripW, height: 1800))
    // Sprocket columns.
    c.setFillColor(color(0x0E0D10))
    var y: CGFloat = -900
    while y < 900 {
        c.fill(CGRect(x: -stripW/2 + 22, y: y, width: 34, height: 52))
        c.fill(CGRect(x: stripW/2 - 56, y: y, width: 34, height: 52))
        y += 92
    }
    // Frames with a dot advancing: stills becoming motion.
    let frames: [CGFloat] = [-2, -1, 0, 1, 2]
    for (i, row) in frames.enumerated() {
        let fy = row * (frameH + 26) - frameH/2
        let frame = CGRect(x: -stripW/2 + 74, y: fy, width: stripW - 148, height: frameH)
        c.setFillColor(color(0x141216))
        c.fill(frame)
        c.setStrokeColor(color(0x2A2730))
        c.setLineWidth(4)
        c.stroke(frame)
        let t = CGFloat(i) / CGFloat(frames.count - 1)
        let dotX = frame.minX + 44 + t * (frame.width - 88)
        let dotY = frame.midY - 26 + t * 52
        c.setFillColor(i == 2 ? amber : color(0xF0A030, 0.35 + 0.13 * CGFloat(i)))
        c.fillEllipse(in: CGRect(x: dotX - 34, y: dotY - 34, width: 68, height: 68))
    }
    c.restoreGState()
    save(c, "1-strip")
}

// ── 2. Aperture opening into a play triangle ─────────────────────────
func concept2() {
    let c = ctx1024()
    _ = squircleBase(c)
    let center = CGPoint(x: S/2, y: S/2)
    // Six aperture blades.
    let bladeCount = 6
    let outerR: CGFloat = 330
    for i in 0..<bladeCount {
        let a = CGFloat(i) / CGFloat(bladeCount) * 2 * .pi
        c.saveGState()
        c.translateBy(x: center.x, y: center.y)
        c.rotate(by: a)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 150, y: 0))
        p.addLine(to: CGPoint(x: outerR, y: -96))
        p.addLine(to: CGPoint(x: outerR, y: 128))
        p.closeSubpath()
        c.addPath(p)
        c.setFillColor(color(0x35313B))
        c.fillPath()
        c.addPath(p)
        c.setStrokeColor(color(0x4A4552))
        c.setLineWidth(5)
        c.strokePath()
        c.restoreGState()
    }
    // Amber ring.
    c.setStrokeColor(amber)
    c.setLineWidth(18)
    c.strokeEllipse(in: CGRect(x: center.x - 356, y: center.y - 356, width: 712, height: 712))
    // Play at the aperture's mouth.
    c.saveGState()
    c.setShadow(offset: .zero, blur: 60, color: color(0xF0A030, 0.55))
    playTriangle(c, center: CGPoint(x: center.x + 14, y: center.y), r: 120, fill: amber)
    c.restoreGState()
    save(c, "2-aperture")
}

// ── 3. Burst fan: photo cards fanned, top card plays ─────────────────
func concept3() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState()
    clipSquircle(c, box)
    let center = CGPoint(x: S/2, y: S/2 - 30)
    let card = CGRect(x: -240, y: -170, width: 480, height: 340)
    let tilts: [CGFloat] = [-0.30, -0.15, 0, 0.15]
    for (i, tilt) in tilts.enumerated() {
        let isTop = i == tilts.count - 1
        c.saveGState()
        c.translateBy(x: center.x, y: center.y)
        c.rotate(by: tilt)
        c.translateBy(x: 0, y: CGFloat(i) * 10)
        let path = CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(gray: 0, alpha: 0.5))
        c.addPath(path)
        c.setFillColor(isTop ? color(0x2B2731) : color(0x211E27, 0.96))
        c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.addPath(path)
        c.setStrokeColor(isTop ? amber : color(0x39343F))
        c.setLineWidth(isTop ? 10 : 5)
        c.strokePath()
        if isTop {
            c.saveGState()
            c.setShadow(offset: .zero, blur: 44, color: color(0xF0A030, 0.5))
            playTriangle(c, center: CGPoint(x: 10, y: 0), r: 92, fill: amber)
            c.restoreGState()
        }
        c.restoreGState()
    }
    c.restoreGState()
    save(c, "3-fan")
}

// ── 4. Cadence: dots with as-shot spacing orbiting a play ────────────
func concept4() {
    let c = ctx1024()
    _ = squircleBase(c)
    let center = CGPoint(x: S/2, y: S/2)
    // Uneven angular gaps = the signature as-shot cadence.
    let gaps: [CGFloat] = [1, 1, 1, 2.6, 1, 1, 1.4, 1, 1, 2.2, 1, 1.4]
    let totalGap = gaps.reduce(0, +)
    var angle: CGFloat = .pi / 2
    let orbitR: CGFloat = 300
    for (i, gap) in gaps.enumerated() {
        angle -= gap / totalGap * 2 * .pi
        let x = center.x + cos(angle) * orbitR
        let y = center.y + sin(angle) * orbitR
        let r: CGFloat = i == 0 ? 48 : 34
        c.setFillColor(i == 0 ? amber : color(0xF0A030, 0.30 + 0.05 * CGFloat(i)))
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    c.saveGState()
    c.setShadow(offset: .zero, blur: 56, color: color(0xF0A030, 0.45))
    playTriangle(c, center: CGPoint(x: center.x + 16, y: center.y), r: 132, fill: offWhite)
    c.restoreGState()
    save(c, "4-cadence")
}

// ── 5. K monogram built from film strips ─────────────────────────────
func concept5() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState()
    clipSquircle(c, box)

    func strip(_ transform: CGAffineTransform, length: CGFloat, amberStrip: Bool) {
        c.saveGState()
        c.concatenate(transform)
        let w: CGFloat = 150
        let rect = CGRect(x: -w/2, y: -length/2, width: w, height: length)
        c.setFillColor(amberStrip ? amber : color(0x36323D))
        c.fill(rect)
        c.setFillColor(amberStrip ? color(0x18161B, 0.85) : color(0x141216))
        var y = -length/2 + 18
        while y < length/2 - 30 {
            c.fill(CGRect(x: -w/2 + 18, y: y, width: 26, height: 36))
            c.fill(CGRect(x: w/2 - 44, y: y, width: 26, height: 36))
            y += 66
        }
        c.restoreGState()
    }

    // Vertical stem.
    strip(CGAffineTransform(translationX: 372, y: S/2), length: 560, amberStrip: false)
    // Upper diagonal (amber) and lower diagonal.
    strip(CGAffineTransform(translationX: 566, y: 366).rotated(by: .pi / 4.4), length: 430, amberStrip: false)
    strip(CGAffineTransform(translationX: 566, y: 658).rotated(by: -.pi / 4.4), length: 430, amberStrip: true)
    c.restoreGState()
    save(c, "5-monogram")
}

concept1(); concept2(); concept3(); concept4(); concept5()
print("done")
