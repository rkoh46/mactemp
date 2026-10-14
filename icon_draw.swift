// Draws the MacTemp app icon at 1024x1024 → icon_base.png
import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Background rounded tile, dark gradient
let bg = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.16, alpha: 1),
])!
grad.draw(in: bg, angle: -90)

// Thermometer (outline)
let cx = 400.0
let stemW = 176.0
let stemBottom = 420.0, stemTop = 860.0
let bulbC = NSPoint(x: cx, y: 330), bulbR = 176.0
let stem = NSBezierPath(roundedRect: NSRect(x: cx - stemW/2, y: stemBottom, width: stemW, height: stemTop - stemBottom),
                        xRadius: stemW/2, yRadius: stemW/2)
let bulb = NSBezierPath(ovalIn: NSRect(x: bulbC.x - bulbR, y: bulbC.y - bulbR, width: bulbR*2, height: bulbR*2))
let outline = NSBezierPath()
outline.append(stem)
outline.append(bulb)
NSColor.white.withAlphaComponent(0.94).setFill()
outline.fill()

// Mercury (red)
NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.25, alpha: 1).setFill()
let mercBulb = NSBezierPath(ovalIn: NSRect(x: bulbC.x - bulbR + 40, y: bulbC.y - bulbR + 40,
                                           width: (bulbR - 40) * 2, height: (bulbR - 40) * 2))
mercBulb.fill()
let mercStem = NSBezierPath(roundedRect: NSRect(x: cx - stemW/2 + 40, y: bulbC.y,
                                                width: stemW - 80, height: 470),
                            xRadius: (stemW - 80) / 2, yRadius: (stemW - 80) / 2)
mercStem.fill()

// "°C" label
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 250, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
]
("°C" as NSString).draw(at: NSPoint(x: 640, y: 210), withAttributes: attrs)

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_base.png"))
print("wrote icon_base.png \(png.count) bytes")
