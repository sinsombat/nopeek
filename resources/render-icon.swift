import AppKit

// NoPeek icon candidates — 1024pt, macOS squircle style, navy glass + shield/eye identity.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func roundedRectPath(_ rect: NSRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ name: String, _ draw: (CGContext, NSRect) -> Void) {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }
    draw(ctx, NSRect(x: 0, y: 0, width: size, height: size))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    let path = "\(outDir)/\(name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// macOS-style: 824/1024 rounded square, centered, gentle shadow, glass-ish gradient.
func background(_ ctx: CGContext) {
    let canvas: CGFloat = 1024
    let inset: CGFloat = 100
    let shapeRect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius: CGFloat = 185

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(roundedRectPath(shapeRect, radius: radius))
    ctx.setFillColor(NSColor(calibratedRed: 0.043, green: 0.122, blue: 0.228, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRectPath(shapeRect, radius: radius))
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.40, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.20, alpha: 1).cgColor,
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: shapeRect.maxY),
                               end: CGPoint(x: 0, y: shapeRect.minY),
                               options: [])
    }
    // top glass highlight
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    ctx.fill(CGRect(x: shapeRect.minX, y: shapeRect.midY, width: shapeRect.width, height: shapeRect.height / 2))
    ctx.restoreGState()
}

/// Draw an SF symbol tinted with hierarchical palette colors, centered at a target size.
func symbol(_ name: String, pointSize: CGFloat, centerY: CGFloat, palette: [NSColor]) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        fatalError("missing symbol \(name)")
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: palette))
    guard let sym = base.withSymbolConfiguration(config) else { fatalError("config \(name)") }
    let s = sym.size
    let rect = NSRect(x: (1024 - s.width) / 2, y: centerY - s.height / 2, width: s.width, height: s.height)
    sym.draw(in: rect)
}

let navy = NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.50, alpha: 1)

// A — Alert shield (matches the menu-bar shield; red exclamation = org-first severity)
render("candidate-A-alert-shield") { _, _ in
    background(NSGraphicsContext.current!.cgContext)
    symbol("exclamationmark.shield.fill", pointSize: 560, centerY: 512, palette: [.white, .systemRed])
}

// B — Eye with slash (surveillance blocked)
render("candidate-B-eye-slash") { _, _ in
    background(NSGraphicsContext.current!.cgContext)
    symbol("eye.slash.fill", pointSize: 540, centerY: 512, palette: [.white, .systemRed])
}

// C — Shield + watching light
render("candidate-C-watch-light") { _, _ in
    background(NSGraphicsContext.current!.cgContext)
    symbol("shield.fill", pointSize: 560, centerY: 540, palette: [.white])
    // red "recording" dot, lower-right of the shield
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fillEllipse(in: CGRect(x: 640, y: 300, width: 170, height: 170))
    ctx.setStrokeColor(NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.20, alpha: 1).cgColor)
    ctx.setLineWidth(18)
    ctx.strokeEllipse(in: CGRect(x: 640, y: 300, width: 170, height: 170))
}
