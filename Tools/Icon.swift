import AppKit

let output = CommandLine.arguments[1]
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.29, green: 0.30, blue: 0.78, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 220, yRadius: 220).fill()
NSColor.white.setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: 230, y: 725))
head.line(to: NSPoint(x: 362, y: 658))
head.curve(to: NSPoint(x: 662, y: 658), controlPoint1: NSPoint(x: 450, y: 710), controlPoint2: NSPoint(x: 574, y: 710))
head.line(to: NSPoint(x: 794, y: 725))
head.line(to: NSPoint(x: 774, y: 435))
head.curve(to: NSPoint(x: 250, y: 435), controlPoint1: NSPoint(x: 750, y: 160), controlPoint2: NSPoint(x: 274, y: 160))
head.close(); head.fill()
NSColor(calibratedRed: 0.29, green: 0.30, blue: 0.78, alpha: 1).setFill()
for x in [376, 648] {
    NSBezierPath(ovalIn: NSRect(x: x - 56, y: 470, width: 112, height: 135)).fill()
}
NSColor(calibratedRed: 0.98, green: 0.64, blue: 0.27, alpha: 1).setFill()
let beak = NSBezierPath()
beak.move(to: NSPoint(x: 470, y: 432)); beak.line(to: NSPoint(x: 554, y: 432)); beak.line(to: NSPoint(x: 512, y: 372)); beak.close(); beak.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
