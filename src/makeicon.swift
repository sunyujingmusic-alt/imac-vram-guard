import AppKit

// 生成 AppIcon.icns：圆角蓝底 + memorychip 符号（SF Symbols）
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }

    // 圆角背景
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = (s - inset * 2) * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.13, green: 0.42, blue: 0.92, alpha: 1),
                  CGColor(red: 0.10, green: 0.24, blue: 0.72, alpha: 1)]
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }

    // 符号
    if let sym = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.56, weight: .medium)
        let tinted = sym.withSymbolConfiguration(cfg)!
        let draw = tinted
        let dsize = draw.size
        var config = NSImage.SymbolConfiguration(paletteColors: [.white])
        config = config.applying(NSImage.SymbolConfiguration(pointSize: s * 0.56, weight: .medium))
        let final = sym.withSymbolConfiguration(config) ?? tinted
        let fs = final.size
        final.draw(in: CGRect(x: (s - fs.width) / 2, y: (s - fs.height) / 2, width: fs.width, height: fs.height))
        _ = dsize
    }

    img.unlockFocus()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return png
}

for item in sizes {
    if let data = render(size: item.px) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(item.name)
        try? data.write(to: url)
    }
}
print("iconset written to \(outDir)")
