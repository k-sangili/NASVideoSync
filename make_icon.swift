import AppKit

// Renders the NAS Sync app icon: a video (play badge) dropping into a NAS box,
// on an indigo→teal gradient. Full-bleed and opaque; iOS applies the corner mask.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func shadow(_ on: Bool) {
    if on {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
    } else {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

// Background
NSGradient(colors: [NSColor(srgbRed: 0.22, green: 0.24, blue: 0.66, alpha: 1),
                    NSColor(srgbRed: 0.04, green: 0.63, blue: 0.70, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)

// NAS enclosure (lower half)
let box = NSRect(x: 212, y: 150, width: 600, height: 400)
shadow(true)
NSColor.white.setFill()
NSBezierPath(roundedRect: box, xRadius: 72, yRadius: 72).fill()
shadow(false)

// Drive bays + activity LEDs
for i in 0..<3 {
    let y = box.minY + 62 + CGFloat(i) * 102
    NSColor(srgbRed: 0.84, green: 0.88, blue: 0.94, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: box.minX + 66, y: y, width: box.width - 210, height: 64),
                 xRadius: 32, yRadius: 32).fill()
    NSColor(srgbRed: 0.10, green: 0.78, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: box.maxX - 108, y: y + 12, width: 40, height: 40)).fill()
}

// Down arrow from the video into the NAS
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 512 - 30, y: 600, width: 60, height: 90), xRadius: 18, yRadius: 18).fill()
let head = NSBezierPath()
head.move(to: NSPoint(x: 512 - 92, y: 622))
head.line(to: NSPoint(x: 512 + 92, y: 622))
head.line(to: NSPoint(x: 512, y: 560))
head.close()
head.fill()

// Video "play" badge (top)
let badge = NSRect(x: 512 - 130, y: 690, width: 260, height: 260)
shadow(true)
NSColor(srgbRed: 1.0, green: 0.55, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: badge).fill()
shadow(false)
NSColor.white.setFill()
let play = NSBezierPath()
play.move(to: NSPoint(x: badge.midX - 38, y: badge.midY + 62))
play.line(to: NSPoint(x: badge.midX - 38, y: badge.midY - 62))
play.line(to: NSPoint(x: badge.midX + 66, y: badge.midY))
play.close()
play.fill()

// Flatten onto opaque RGB (App Store icons must not have alpha)
let cg = rep.cgImage!
let opaque = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
opaque.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
let png = NSBitmapImageRep(cgImage: opaque.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
