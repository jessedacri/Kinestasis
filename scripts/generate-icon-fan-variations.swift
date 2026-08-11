#!/usr/bin/env swift
// Variations on icon concept 3 (fanned burst of photo cards).
// Renders 3a..3e at 1024 px into build/icon-concepts/.

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
let amber = color(0xF0A030)

func ctx1024() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func squircleBase(_ c: CGContext) -> CGRect {
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: box, cornerWidth: 184, cornerHeight: 184, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.45))
    c.addPath(path); c.setFillColor(ink); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [inkTop, ink] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: S/2, y: box.maxY), end: CGPoint(x: S/2, y: box.minY), options: [])
    c.restoreGState()
    return box
}

func clip(_ c: CGContext, _ box: CGRect) {
    c.addPath(CGPath(roundedRect: box, cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.clip()
}

func play(_ c: CGContext, at center: CGPoint, r: CGFloat, fill: CGColor, glow: CGColor? = nil) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x + r, y: center.y))
    p.addLine(to: CGPoint(x: center.x - r * 0.5, y: center.y + r * 0.866))
    p.addLine(to: CGPoint(x: center.x - r * 0.5, y: center.y - r * 0.866))
    p.closeSubpath()
    c.saveGState()
    if let glow { c.setShadow(offset: .zero, blur: 48, color: glow) }
    c.addPath(p); c.setFillColor(fill); c.fillPath()
    c.restoreGState()
}

func save(_ c: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

let card = CGRect(x: -240, y: -170, width: 480, height: 340)

func drawCard(_ c: CGContext, tilt: CGFloat, offset: CGPoint = .zero,
              fill: CGColor, stroke: CGColor?, strokeW: CGFloat = 5,
              shadow: Bool = true, rect: CGRect = card) {
    c.saveGState()
    c.rotate(by: tilt)
    c.translateBy(x: offset.x, y: offset.y)
    let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
    if shadow { c.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(gray: 0, alpha: 0.5)) }
    c.addPath(path); c.setFillColor(fill); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    if let stroke {
        c.addPath(path); c.setStrokeColor(stroke); c.setLineWidth(strokeW); c.strokePath()
    }
    c.restoreGState()
}

// ── 3a. Solid amber top card, dark play punched out ──────────────────
func v3a() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState(); clip(c, box)
    c.translateBy(x: S/2, y: S/2 - 30)
    for (i, tilt) in [CGFloat(-0.30), -0.15, 0].enumerated() {
        drawCard(c, tilt: tilt, offset: CGPoint(x: 0, y: CGFloat(i) * 8),
                 fill: color(0x211E27, 0.96), stroke: color(0x39343F))
    }
    c.saveGState()
    c.rotate(by: 0.15)
    c.translateBy(x: 0, y: 24)
    let path = CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0xF0A030, 0.35))
    c.addPath(path); c.setFillColor(amber); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    play(c, at: CGPoint(x: 10, y: 0), r: 92, fill: ink)
    c.restoreGState()
    c.restoreGState()
    save(c, "3a-amber-card")
}

// ── 3b. Wide fan from a low pivot, five cards ────────────────────────
func v3b() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState(); clip(c, box)
    c.translateBy(x: S/2, y: S/2 - 190)   // pivot low: cards fan upward
    let pivotRect = CGRect(x: -215, y: 40, width: 430, height: 300)
    // Outer cards first, the straight top card last so it stays on top.
    let tilts: [CGFloat] = [-0.52, 0.52, -0.26, 0.26, 0]
    for (i, tilt) in tilts.enumerated() {
        let isTop = i == tilts.count - 1
        c.saveGState()
        c.rotate(by: tilt)
        let path = CGPath(roundedRect: pivotRect, cornerWidth: 30, cornerHeight: 30, transform: nil)
        c.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: CGColor(gray: 0, alpha: 0.5))
        c.addPath(path)
        c.setFillColor(isTop ? color(0x2B2731) : color(0x201D25, 0.97))
        c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.addPath(path)
        c.setStrokeColor(isTop ? amber : color(0x39343F))
        c.setLineWidth(isTop ? 10 : 5)
        c.strokePath()
        if isTop {
            play(c, at: CGPoint(x: 8, y: 190), r: 84, fill: amber, glow: color(0xF0A030, 0.5))
        }
        c.restoreGState()
    }
    c.restoreGState()
    save(c, "3b-wide-fan")
}

// ── 3c. Echo trails: one solid card, amber outline echoes behind ─────
func v3c() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState(); clip(c, box)
    c.translateBy(x: S/2, y: S/2 - 20)
    for (i, tilt) in [CGFloat(-0.34), -0.22, -0.11].enumerated() {
        drawCard(c, tilt: tilt, fill: color(0x000000, 0),
                 stroke: color(0xF0A030, 0.16 + 0.14 * CGFloat(i)), strokeW: 9, shadow: false)
    }
    drawCard(c, tilt: 0.06, fill: color(0x2B2731), stroke: amber, strokeW: 11)
    c.saveGState()
    c.rotate(by: 0.06)
    play(c, at: CGPoint(x: 10, y: 0), r: 92, fill: amber, glow: color(0xF0A030, 0.5))
    c.restoreGState()
    c.restoreGState()
    save(c, "3c-echoes")
}

// ── 3d. Cadence fan: uneven tilt gaps, amber ramps to the top ────────
func v3d() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState(); clip(c, box)
    c.translateBy(x: S/2, y: S/2 - 30)
    // Gaps tighten then jump: the as-shot signature in card form.
    let tilts: [CGFloat] = [-0.46, -0.40, -0.34, -0.14, 0.08]
    for (i, tilt) in tilts.enumerated() {
        let isTop = i == tilts.count - 1
        let t = CGFloat(i) / CGFloat(tilts.count - 1)
        drawCard(c, tilt: tilt, offset: CGPoint(x: 0, y: t * 16),
                 fill: isTop ? color(0x2B2731) : color(0x201D25, 0.97),
                 stroke: isTop ? amber : color(0xF0A030, 0.10 + 0.18 * t),
                 strokeW: isTop ? 10 : 6)
        if isTop {
            c.saveGState()
            c.rotate(by: tilt)
            c.translateBy(x: 0, y: t * 16)
            play(c, at: CGPoint(x: 10, y: 0), r: 92, fill: amber, glow: color(0xF0A030, 0.5))
            c.restoreGState()
        }
    }
    c.restoreGState()
    save(c, "3d-cadence-fan")
}

// ── 3e. Reductive: one big card, three slivers peeking, huge play ────
func v3e() {
    let c = ctx1024()
    let box = squircleBase(c)
    c.saveGState(); clip(c, box)
    c.translateBy(x: S/2, y: S/2)
    let big = CGRect(x: -280, y: -200, width: 560, height: 400)
    // Slivers peeking from behind, right edge.
    for i in 0..<3 {
        let inset = CGFloat(i + 1) * 26
        let sliver = big.offsetBy(dx: inset, dy: -inset * 0.4)
        let path = CGPath(roundedRect: sliver, cornerWidth: 38, cornerHeight: 38, transform: nil)
        c.addPath(path)
        c.setFillColor(color(0x201D25, 1 - 0.18 * CGFloat(i)))
        c.fillPath()
        c.addPath(path)
        c.setStrokeColor(color(0x39343F, 0.9 - 0.2 * CGFloat(i)))
        c.setLineWidth(4)
        c.strokePath()
    }
    let path = CGPath(roundedRect: big, cornerWidth: 38, cornerHeight: 38, transform: nil)
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.55))
    c.addPath(path); c.setFillColor(color(0x2B2731)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(path); c.setStrokeColor(amber); c.setLineWidth(12); c.strokePath()
    play(c, at: CGPoint(x: 14, y: 0), r: 118, fill: amber, glow: color(0xF0A030, 0.55))
    c.restoreGState()
    save(c, "3e-reductive")
}

v3a(); v3b(); v3c(); v3d(); v3e()
print("done")
