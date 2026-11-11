// Generates Prisme's icon (bar chart through a prism): swift Resources/make-icon.swift Resources
import AppKit

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let inset: CGFloat = 100, body: CGFloat = 824
let rect = CGRect(x: inset, y: inset, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x10203F, 0.30))
ctx.addPath(path)
ctx.setFillColor(color(0x1E2A44))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [color(0x23345A), color(0x141C30)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: inset), end: CGPoint(x: 0, y: inset + body), options: [])
ctx.restoreGState()

// Bars
let bars: [(CGFloat, UInt32)] = [(0.38, 0x2E6FD8), (0.58, 0x2BA37A), (0.46, 0xF28C28), (0.78, 0xE0B400)]
let baseY: CGFloat = 790, barW: CGFloat = 112, gap: CGFloat = 40
var x: CGFloat = 512 - (barW * 4 + gap * 3) / 2
for (h, c) in bars {
    let bh = h * 520
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: baseY - bh, width: barW, height: bh),
                       cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(c))
    ctx.fillPath()
    x += barW + gap
}
// Baseline
ctx.setFillColor(color(0xFFFFFF, 0.85))
ctx.fill(CGRect(x: 230, y: baseY + 18, width: 564, height: 14))

let image = ctx.makeImage()!
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("AppIcon-1024.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("PrismeIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: size, height: size))
            .draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✅ AppIcon.icns created" : "❌ iconutil failed")
