// Generates Resources/AppIcon.icns — a Scholar-blue squircle with a white
// graduation cap (gold tassel) and a gold "citations per year" bar-chart badge.
// Run from the package root:
//   swift tools/make_icon.swift                    # writes Resources/AppIcon.icns
//   swift tools/make_icon.swift --preview <dir>    # also writes icon_preview.png,
//                                                  # icon_sizes.png, icon_zoom.png
// Requires only Command Line Tools (AppKit offscreen drawing + iconutil).
import AppKit

// MARK: - Palette

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
}

let bgTop = rgb(0.33, 0.62, 1.00)       // Google-Scholar-ish blue
let bgBottom = rgb(0.10, 0.36, 0.86)
let capTop = rgb(1, 1, 1)
let capEdge = rgb(0.70, 0.80, 0.97)     // board thickness
let bodyTop = rgb(0.78, 0.86, 0.99)     // skull cap, shaded under the board
let bodyBottom = rgb(0.94, 0.97, 1.00)
let gold = rgb(1.00, 0.76, 0.20)
let goldTop = rgb(1.00, 0.80, 0.27)
let goldBottom = rgb(0.98, 0.60, 0.06)

// MARK: - Shapes

/// macOS-style continuous-corner rounded rect ("squircle").
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k = radius
    let (minX, minY, maxX, maxY) = (r.minX, r.minY, r.maxX, r.maxY)
    // y-up coordinates; walk counter-clockwise starting at bottom edge.
    p.move(to: CGPoint(x: minX + 1.52866483 * k, y: minY))
    // bottom-right
    p.addLine(to: CGPoint(x: maxX - 1.52866483 * k, y: minY))
    p.addCurve(to: CGPoint(x: maxX - 0.63149399 * k, y: minY + 0.07491100 * k),
               control1: CGPoint(x: maxX - 1.08849299 * k, y: minY),
               control2: CGPoint(x: maxX - 0.86840701 * k, y: minY))
    p.addCurve(to: CGPoint(x: maxX - 0.07491100 * k, y: minY + 0.63149399 * k),
               control1: CGPoint(x: maxX - 0.37282401 * k, y: minY + 0.16905500 * k),
               control2: CGPoint(x: maxX - 0.16905500 * k, y: minY + 0.37282401 * k))
    p.addCurve(to: CGPoint(x: maxX, y: minY + 1.52866483 * k),
               control1: CGPoint(x: maxX, y: minY + 0.86840701 * k),
               control2: CGPoint(x: maxX, y: minY + 1.08849299 * k))
    // top-right
    p.addLine(to: CGPoint(x: maxX, y: maxY - 1.52866483 * k))
    p.addCurve(to: CGPoint(x: maxX - 0.07491100 * k, y: maxY - 0.63149399 * k),
               control1: CGPoint(x: maxX, y: maxY - 1.08849299 * k),
               control2: CGPoint(x: maxX, y: maxY - 0.86840701 * k))
    p.addCurve(to: CGPoint(x: maxX - 0.63149399 * k, y: maxY - 0.07491100 * k),
               control1: CGPoint(x: maxX - 0.16905500 * k, y: maxY - 0.37282401 * k),
               control2: CGPoint(x: maxX - 0.37282401 * k, y: maxY - 0.16905500 * k))
    p.addCurve(to: CGPoint(x: maxX - 1.52866483 * k, y: maxY),
               control1: CGPoint(x: maxX - 0.86840701 * k, y: maxY),
               control2: CGPoint(x: maxX - 1.08849299 * k, y: maxY))
    // top-left
    p.addLine(to: CGPoint(x: minX + 1.52866483 * k, y: maxY))
    p.addCurve(to: CGPoint(x: minX + 0.63149399 * k, y: maxY - 0.07491100 * k),
               control1: CGPoint(x: minX + 1.08849299 * k, y: maxY),
               control2: CGPoint(x: minX + 0.86840701 * k, y: maxY))
    p.addCurve(to: CGPoint(x: minX + 0.07491100 * k, y: maxY - 0.63149399 * k),
               control1: CGPoint(x: minX + 0.37282401 * k, y: maxY - 0.16905500 * k),
               control2: CGPoint(x: minX + 0.16905500 * k, y: maxY - 0.37282401 * k))
    p.addCurve(to: CGPoint(x: minX, y: maxY - 1.52866483 * k),
               control1: CGPoint(x: minX, y: maxY - 0.86840701 * k),
               control2: CGPoint(x: minX, y: maxY - 1.08849299 * k))
    // bottom-left
    p.addLine(to: CGPoint(x: minX, y: minY + 1.52866483 * k))
    p.addCurve(to: CGPoint(x: minX + 0.07491100 * k, y: minY + 0.63149399 * k),
               control1: CGPoint(x: minX, y: minY + 1.08849299 * k),
               control2: CGPoint(x: minX, y: minY + 0.86840701 * k))
    p.addCurve(to: CGPoint(x: minX + 0.63149399 * k, y: minY + 0.07491100 * k),
               control1: CGPoint(x: minX + 0.16905500 * k, y: minY + 0.37282401 * k),
               control2: CGPoint(x: minX + 0.37282401 * k, y: minY + 0.16905500 * k))
    p.addCurve(to: CGPoint(x: minX + 1.52866483 * k, y: minY),
               control1: CGPoint(x: minX + 0.86840701 * k, y: minY),
               control2: CGPoint(x: minX + 1.08849299 * k, y: minY))
    p.closeSubpath()
    return p
}

// MARK: - Drawing

func draw(_ ctx: CGContext, _ s: CGFloat) {
    let small = s <= 32   // simplified art for 16/32 px so it stays crisp
    let tiny = s <= 16
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

    // Background squircle (Apple icon grid: ~80% canvas, ~22.5% corner radius)
    // Snap to whole pixels at 16/32 px so the edge stays crisp.
    let inset = tiny ? 1 : (small ? (s * 0.098).rounded() : s * 0.098)
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = squircle(rect, radius: rect.width * 0.225)

    if !small {   // soft drop shadow like Apple's template
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.022,
                      color: rgb(0, 0, 0, 0.28))
        ctx.addPath(bg); ctx.setFillColor(bgBottom); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    ctx.drawLinearGradient(gradient([bgTop, bgBottom]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // faint top sheen
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
    ctx.restoreGState()

    // ---- Glyph geometry (unit coordinates) ----
    let g: CGFloat = tiny ? 1.16 : (small ? 1.05 : 1.0)   // enlarge slightly when tiny
    let cx: CGFloat = 0.5
    let cy: CGFloat = tiny ? 0.60 : 0.655                   // board centre
    let W: CGFloat = 0.31 * g                               // board half-width
    let H: CGFloat = tiny ? 0.15 : 0.125 * g                // board half-height
    let drop: CGFloat = tiny ? 1.22 : 1.0                   // deeper bowl when tiny
    let thick: CGFloat = tiny ? 1.1 / s : 0.028 * g         // board edge thickness
    // At 16 px the board edge becomes a dark separating line so cap and bowl don't merge.
    let edgeColor = tiny ? rgb(0.06, 0.25, 0.68) : capEdge
    let showBadge = !tiny
    let badgeC = CGPoint(x: 0.715, y: 0.33)
    let badgeR: CGFloat = small ? 0.15 : 0.125
    let badgeGap: CGFloat = small ? 0.035 : 0.026

    func rhombus(dy: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: P(cx - W, cy + dy)); p.addLine(to: P(cx, cy + H + dy))
        p.addLine(to: P(cx + W, cy + dy)); p.addLine(to: P(cx, cy - H + dy))
        p.closeSubpath()
        return p
    }
    let round = tiny ? 0.5 : s * 0.022   // corner softening via round-joined stroke
    // Board seen with thickness: hull of the top face and the face shifted down.
    func slab() -> CGPath {
        let p = CGMutablePath()
        p.move(to: P(cx, cy + H)); p.addLine(to: P(cx + W, cy))
        p.addLine(to: P(cx + W, cy - thick)); p.addLine(to: P(cx, cy - H - thick))
        p.addLine(to: P(cx - W, cy - thick)); p.addLine(to: P(cx - W, cy))
        p.closeSubpath()
        return p
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.028,
                  color: rgb(0.02, 0.10, 0.35, tiny ? 0 : 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Skull cap (under the board)
    let bw: CGFloat = 0.19 * g
    let body = CGMutablePath()
    body.move(to: P(cx - bw, cy - 0.03))
    body.addLine(to: P(cx + bw, cy - 0.03))
    body.addLine(to: P(cx + bw, cy - 0.185 * g * drop))
    body.addCurve(to: P(cx - bw, cy - 0.185 * g * drop),
                  control1: P(cx + bw * 0.55, cy - 0.27 * g * drop), control2: P(cx - bw * 0.55, cy - 0.27 * g * drop))
    body.closeSubpath()
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(gradient(tiny ? [capTop, capTop] : small ? [capEdge, capEdge] : [bodyTop, bodyBottom]),
                           start: P(0, cy - 0.06), end: P(0, cy - 0.26 * g), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Board: thickness, then top face
    ctx.setLineJoin(.round)
    ctx.setLineWidth(round)
    ctx.addPath(slab()); ctx.setFillColor(edgeColor); ctx.setStrokeColor(edgeColor)
    ctx.drawPath(using: .fillStroke)
    ctx.addPath(rhombus(dy: 0)); ctx.setFillColor(capTop); ctx.setStrokeColor(capTop)
    ctx.drawPath(using: .fillStroke)

    // Tassel: at 16 px just a pixel-aligned gold strand hanging off the left edge
    if tiny {
        let x = ((cx - W * 0.80) * s).rounded(.down) + 0.5
        ctx.setStrokeColor(gold); ctx.setLineWidth(1.25); ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: x, y: cy * s - 0.5)); ctx.addLine(to: CGPoint(x: x, y: cy * s - 4.5))
        ctx.strokePath()
    }
    // Tassel: button, cord over the front-left edge, tuft
    if !small {
        let attach = CGPoint(x: cx - W * 0.84, y: cy - H * 0.16)
        let cord = CGMutablePath()
        cord.move(to: P(cx, cy))
        cord.addLine(to: P(attach.x, attach.y))
        cord.addLine(to: P(attach.x, cy - 0.20))
        ctx.setStrokeColor(gold); ctx.setLineWidth(s * 0.020)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(cord); ctx.strokePath()
        let br = 0.026
        ctx.setFillColor(gold)
        ctx.fillEllipse(in: CGRect(x: (cx - br) * s, y: (cy - br) * s, width: 2 * br * s, height: 2 * br * s))
        // tuft: tapered rounded shape
        let tuft = CGMutablePath()
        let tx = attach.x, tTop = cy - 0.19, tBot = cy - 0.305
        tuft.move(to: P(tx - 0.016, tTop))
        tuft.addLine(to: P(tx + 0.016, tTop))
        tuft.addLine(to: P(tx + 0.030, tBot + 0.012))
        tuft.addQuadCurve(to: P(tx - 0.030, tBot + 0.012), control: P(tx, tBot - 0.012))
        tuft.closeSubpath()
        ctx.addPath(tuft); ctx.setFillColor(gold); ctx.fillPath()
    }

    if showBadge {
        // Cut a gap around the badge so it reads as a separate token
        ctx.setBlendMode(.clear)
        let cr = (badgeR + badgeGap) * s
        ctx.fillEllipse(in: CGRect(x: badgeC.x * s - cr, y: badgeC.y * s - cr, width: 2 * cr, height: 2 * cr))
        ctx.setBlendMode(.normal)

        // Gold disc
        let r = badgeR * s
        let disc = CGPath(ellipseIn: CGRect(x: badgeC.x * s - r, y: badgeC.y * s - r, width: 2 * r, height: 2 * r),
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(disc); ctx.clip()
        ctx.drawLinearGradient(gradient([goldTop, goldBottom]),
                               start: CGPoint(x: 0, y: badgeC.y * s + r), end: CGPoint(x: 0, y: badgeC.y * s - r),
                               options: [])
        ctx.restoreGState()

        // Rising "citations per year" bars
        let heights: [CGFloat] = small ? [0.42, 0.80] : [0.38, 0.62, 0.92]
        let n = CGFloat(heights.count)
        let barW = badgeR * (small ? 0.40 : 0.30)
        let gap = badgeR * (small ? 0.22 : 0.17)
        let total = n * barW + (n - 1) * gap
        let base = badgeC.y - badgeR * 0.50
        let maxH = badgeR * 1.05
        ctx.setFillColor(rgb(1, 1, 1))
        for (i, h) in heights.enumerated() {
            let x = badgeC.x - total / 2 + CGFloat(i) * (barW + gap)
            let bar = CGRect(x: x * s, y: base * s, width: barW * s, height: h * maxH * s)
            let rr = min(barW * s * 0.28, bar.height / 2)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: rr, cornerHeight: rr, transform: nil))
            ctx.fillPath()
        }
    }

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func renderRep(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsctx
    nsctx.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    draw(nsctx.cgContext, CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

// MARK: - Output

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = fm.temporaryDirectory.appendingPathComponent("ScholarBar-AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
var cache: [Int: NSBitmapImageRep] = [:]
func rep(_ px: Int) -> NSBitmapImageRep {
    if let r = cache[px] { return r }
    let r = renderRep(px); cache[px] = r; return r
}
for (px, name) in variants {
    try! png(rep(px)).write(to: iconset.appendingPathComponent(name))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "✅ \(out.path) generated" : "❌ iconutil failed")

// Optional previews: --preview <dir>
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! png(rep(1024)).write(to: dir.appendingPathComponent("icon_preview.png"))

    func canvas(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> Data {
        let c = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let n = NSGraphicsContext(bitmapImageRep: c)!
        NSGraphicsContext.current = n
        body(n.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return png(c)
    }
    func label(_ text: String, at pt: CGPoint, dark: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.35, alpha: 1),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(at: NSPoint(x: pt.x - str.size().width / 2, y: pt.y))
    }

    // Strip at true pixel sizes, on light and dark backgrounds (Dock/Finder check)
    let sizes = [16, 32, 64, 128, 512]
    let pad = 28, rowH = 512 + 2 * pad + 20
    let stripW = sizes.reduce(0, +) + pad * (sizes.count + 1)
    let strip = canvas(stripW, rowH * 2) { c in
        for (row, dark) in [(1, false), (0, true)] {
            c.setFillColor(dark ? rgb(0.13, 0.13, 0.15) : rgb(0.93, 0.93, 0.94))
            c.fill(CGRect(x: 0, y: row * rowH, width: stripW, height: rowH))
            var x = pad
            for px in sizes {
                let y = row * rowH + pad + 20 + (512 - px) / 2
                c.interpolationQuality = .none
                c.draw(rep(px).cgImage!, in: CGRect(x: x, y: y, width: px, height: px))
                label("\(px)", at: CGPoint(x: x + px / 2, y: row * rowH + 10), dark: dark)
                x += px + pad
            }
        }
    }
    try! strip.write(to: dir.appendingPathComponent("icon_sizes.png"))

    // Nearest-neighbour magnification of the small sizes (16→×16, 32→×8, 64→×4)
    let zoom = canvas(256 * 3 + 40 * 4, 256 + 80) { c in
        c.setFillColor(rgb(0.93, 0.93, 0.94)); c.fill(CGRect(x: 0, y: 0, width: 256 * 3 + 160, height: 336))
        c.interpolationQuality = .none
        for (i, px) in [16, 32, 64].enumerated() {
            let x = 40 + i * (256 + 40)
            c.draw(rep(px).cgImage!, in: CGRect(x: x, y: 50, width: 256, height: 256))
            label("\(px) px", at: CGPoint(x: x + 128, y: 18), dark: false)
        }
    }
    try! zoom.write(to: dir.appendingPathComponent("icon_zoom.png"))
    print("🖼  previews written to \(dir.path)")
}
