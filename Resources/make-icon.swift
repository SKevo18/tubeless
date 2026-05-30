import AppKit

// renders the Tubeless app icon (pink squircle + white waveform bars) into an
// .iconset directory. run: swift make-icon.swift <output.iconset>
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func makePNG(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let margin = s * 0.08
    let rect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // pink gradient fill clipped to the squircle
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let colors = [CGColor(red: 1.00, green: 0.45, blue: 0.54, alpha: 1),
                  CGColor(red: 1.00, green: 0.18, blue: 0.33, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // white waveform bars
    let heights: [CGFloat] = [0.42, 0.72, 1.0, 0.58, 0.86]
    let n = heights.count
    let area = rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24)
    let gap = area.width * 0.07
    let barW = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    for i in 0..<n {
        let h = area.height * heights[i]
        let x = area.minX + CGFloat(i) * (barW + gap)
        let y = area.midY - h / 2
        let bar = CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: h),
                         cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.addPath(bar); ctx.fillPath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in sizes {
    try! makePNG(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(out)")
