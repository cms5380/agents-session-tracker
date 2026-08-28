// renders app-icon candidates (1024px PNG).
// usage: swift tools/gen-appicon.swift <radar|stack|dots> out.png
import AppKit

let style = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "radar"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "appicon.png"

let S: CGFloat = 1024
let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let cg = NSGraphicsContext.current!.cgContext

// squircle canvas
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
cg.addPath(CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil))
cg.clip()
let bg = [NSColor(red: 0.17, green: 0.17, blue: 0.21, alpha: 1).cgColor,
          NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1).cgColor]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: bg as CFArray, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S), end: CGPoint(x: S/2, y: 0), options: [])

let c = CGPoint(x: S/2, y: S/2)

switch style {
case "radar":
    // concentric sweep rings + agent blips
    for (i, r) in [130.0, 230.0, 330.0].enumerated() {
        cg.setStrokeColor(orange.withAlphaComponent(0.25 - CGFloat(i) * 0.05).cgColor)
        cg.setLineWidth(10)
        cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r))
    }
    // sweep wedge
    let wedge = CGMutablePath()
    wedge.move(to: c)
    wedge.addArc(center: c, radius: 335, startAngle: .pi * 0.42, endAngle: .pi * 0.12, clockwise: true)
    wedge.closeSubpath()
    cg.addPath(wedge)
    cg.setFillColor(orange.withAlphaComponent(0.18).cgColor)
    cg.fillPath()
    cg.setStrokeColor(orange.cgColor)
    cg.setLineWidth(14)
    cg.setLineCap(.round)
    cg.beginPath()
    cg.move(to: c)
    cg.addLine(to: CGPoint(x: c.x + cos(.pi * 0.12) * 335, y: c.y + sin(.pi * 0.12) * 335))
    cg.strokePath()
    // center hub
    cg.setFillColor(orange.cgColor)
    cg.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
    // blips: green running, orange waiting, blue reply
    let blips: [(CGFloat, CGFloat, NSColor)] = [
        (-160, 120, .systemGreen), (150, 200, .systemOrange), (110, -170, NSColor.systemTeal)]
    for (dx, dy, col) in blips {
        cg.setFillColor(col.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x + dx - 30, y: c.y + dy - 30, width: 60, height: 60))
    }

case "stack":
    // three stacked session cards, top one with status dots
    func card(_ dx: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) -> CGRect {
        CGRect(x: c.x - 290 + dx, y: c.y - 190 + dy, width: 580, height: 380)
    }
    for (i, off) in [(-70.0), (0.0), (70.0)].enumerated() {
        let r = card(CGFloat(i) * 26 - 26, CGFloat(off), 1)
        let p = CGPath(roundedRect: r, cornerWidth: 56, cornerHeight: 56, transform: nil)
        cg.addPath(p)
        if i == 2 {
            cg.setFillColor(NSColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1).cgColor)
        } else {
            cg.setFillColor(orange.withAlphaComponent(i == 0 ? 0.35 : 0.6).cgColor)
        }
        cg.fillPath()
    }
    // status dots + lines on top card
    let top = card(26, 70, 1)
    let dots: [NSColor] = [.systemGreen, .systemOrange, NSColor.systemTeal]
    for (i, col) in dots.enumerated() {
        cg.setFillColor(col.cgColor)
        cg.fillEllipse(in: CGRect(x: top.minX + 60, y: top.maxY - 110 - CGFloat(i) * 100,
                                  width: 52, height: 52))
        cg.setFillColor(NSColor(white: 0.2, alpha: 0.5).cgColor)
        let lw: CGFloat = [300, 220, 260][i]
        cg.fill(CGRect(x: top.minX + 150, y: top.maxY - 96 - CGFloat(i) * 100,
                       width: lw, height: 26))
    }

case "dots":
    // minimal: three big status dots, diagonal
    let spots: [(CGFloat, CGFloat, NSColor)] = [
        (-190, 180, .systemGreen), (0, 0, orange), (190, -180, NSColor.systemTeal)]
    for (dx, dy, col) in spots {
        cg.setFillColor(col.withAlphaComponent(0.25).cgColor)
        cg.fillEllipse(in: CGRect(x: c.x + dx - 130, y: c.y + dy - 130, width: 260, height: 260))
        cg.setFillColor(col.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x + dx - 82, y: c.y + dy - 82, width: 164, height: 164))
    }

default:
    break
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
