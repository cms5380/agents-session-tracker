// renders the app icon (1024px PNG): dark rounded square + the pixel
// terminal glyph in claude orange.  usage: swift tools/gen-appicon.swift out.png
import AppKit

let appIconMap: [String] = [
    ".oooooooooooooo.",
    "o..............o",
    "o..............o",
    "o..o...........o",
    "o...o..........o",
    "o..o...........o",
    "o......oooo....o",
    "o..............o",
    "o..............o",
    ".oooooooooooooo.",
]

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let cg = NSGraphicsContext.current!.cgContext

// macOS-style rounded square with margin
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.addPath(path)
cg.clip()
let colors = [NSColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1).cgColor,
              NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: colors as CFArray, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: S / 2, y: S), end: CGPoint(x: S / 2, y: 0), options: [])

// pixel terminal glyph, centered
cg.setShouldAntialias(false)
cg.setFillColor(NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor) // claude orange
let px: CGFloat = 42
let gw = px * 16, gh = px * 10
let ox = (S - gw) / 2, oy = (S - gh) / 2
for (y, row) in appIconMap.enumerated() {
    for (x, ch) in row.enumerated() where ch == "o" {
        cg.fill(CGRect(x: ox + CGFloat(x) * px,
                       y: oy + gh - CGFloat(y + 1) * px,
                       width: px, height: px))
    }
}
img.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "appicon.png"
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
