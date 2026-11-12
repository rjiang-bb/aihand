#!/usr/bin/env swift
// Draws the DMG window background: a soft gradient, an install headline, and a curved
// arrow from the app icon slot to the Applications slot.
//
//   swift scripts/make-dmg-background.swift assets/dmg-background.png
//
// Coordinates are window points (560x360, origin top-left). Keep the icon centers in sync
// with `build_dmg` in scripts/lib.sh (app 150,170 / Applications 410,170).
import AppKit

let points = CGSize(width: 560, height: 360)
let scale: CGFloat = 2
let appCenter = CGPoint(x: 150, y: 170)
let dropCenter = CGPoint(x: 410, y: 170)
let iconHalf: CGFloat = 56

let outPath = CommandLine.arguments.dropFirst().first ?? "dmg-background.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(points.width * scale),
    pixelsHigh: Int(points.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("bitmap") }

guard let gfx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("context") }
let cg = gfx.cgContext
cg.translateBy(x: 0, y: points.height * scale)
cg.scaleBy(x: scale, y: -scale)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

// Background gradient (light, so Finder's dark icon labels stay readable).
let top = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1)
let bottom = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.94, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(origin: .zero, size: points), angle: 90)

// Headline.
let para = NSMutableParagraphStyle()
para.alignment = .center
let title = NSAttributedString(string: "Drag AiHand into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.2, alpha: 1),
    .paragraphStyle: para,
])
title.draw(in: NSRect(x: 0, y: 40, width: points.width, height: 24))
let sub = NSAttributedString(string: "to install", attributes: [
    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.4, green: 0.4, blue: 0.46, alpha: 1),
    .paragraphStyle: para,
])
sub.draw(in: NSRect(x: 0, y: 64, width: points.width, height: 18))

// Arrow: a gentle arc from just right of the app icon to just left of the Applications folder.
let accent = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.91, alpha: 1)
let start = CGPoint(x: appCenter.x + iconHalf + 14, y: appCenter.y - 6)
let end = CGPoint(x: dropCenter.x - iconHalf - 16, y: dropCenter.y - 6)
let control = CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 52)

// Shaft stops short of the tip so the head's point stays crisp.
let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
let len = hypot(tangent.x, tangent.y)
let dir = CGPoint(x: tangent.x / len, y: tangent.y / len)
let headLen: CGFloat = 26
let shaftEnd = CGPoint(x: end.x - dir.x * (headLen - 6), y: end.y - dir.y * (headLen - 6))

let shaft = NSBezierPath()
shaft.move(to: start)
shaft.curve(
    to: shaftEnd,
    controlPoint1: CGPoint(x: start.x + (control.x - start.x) * 0.9, y: start.y + (control.y - start.y) * 0.9),
    controlPoint2: CGPoint(x: shaftEnd.x + (control.x - shaftEnd.x) * 0.9, y: shaftEnd.y + (control.y - shaftEnd.y) * 0.9)
)
shaft.lineWidth = 6
shaft.lineCapStyle = .round
accent.setStroke()
shaft.stroke()

// Arrow head (filled triangle with rounded joins).
let normal = CGPoint(x: -dir.y, y: dir.x)
let base = CGPoint(x: end.x - dir.x * headLen, y: end.y - dir.y * headLen)
let head = NSBezierPath()
head.move(to: end)
head.line(to: CGPoint(x: base.x + normal.x * 15, y: base.y + normal.y * 15))
head.line(to: CGPoint(x: base.x - normal.x * 15, y: base.y - normal.y * 15))
head.close()
head.lineJoinStyle = .round
accent.setFill()
head.fill()

NSGraphicsContext.current = nil
// 144 dpi → Finder treats the PNG as a @2x image of the 560x360 window.
// (Set after drawing: assigning `size` first rescales the context.)
rep.size = NSSize(width: points.width, height: points.height)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(rep.pixelsWide)x\(rep.pixelsHigh) px)")
