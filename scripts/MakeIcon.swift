// Generates the Parfait app icon (all AppIcon.iconset sizes + 1024 master)
// and menu-bar template icons. Run: swift scripts/MakeIcon.swift <outdir>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let bgTop = srgb(255, 251, 246)
let bgBottom = srgb(252, 238, 220)
let glassTone = srgb(233, 213, 184)
let raspberry = srgb(224, 57, 107)
let honey = srgb(242, 169, 59)
let creamLayer = srgb(255, 253, 248)
let leafGreen = srgb(63, 178, 127)
let shadowTone = srgb(139, 98, 55, 0.28)

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) {
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fputs("cannot create \(url.path)\n", stderr); exit(1) }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fputs("cannot write \(url.path)\n", stderr); exit(1) }
}

/// Tapered cup: flat rim at topY, rounded bottom corners. Works in any coordinate scale.
func cupPath(cx: CGFloat, topY: CGFloat, botY: CGFloat, topHalf: CGFloat, botHalf: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let tl = CGPoint(x: cx - topHalf, y: topY)
    let bl = CGPoint(x: cx - botHalf, y: botY)
    let br = CGPoint(x: cx + botHalf, y: botY)
    let tr = CGPoint(x: cx + topHalf, y: topY)
    p.move(to: tl)
    p.addArc(tangent1End: bl, tangent2End: br, radius: r)
    p.addArc(tangent1End: br, tangent2End: tr, radius: r)
    p.addLine(to: tr)
    p.closeSubpath()
    return p
}

// MARK: - App icon (drawn in 1024-space, vector-scaled to each pixel size)

func drawAppIcon(in ctx: CGContext, px: Int) {
    ctx.saveGState()
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Rounded-rect plate with standard macOS icon margins; everything clips to it.
    let plate = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.addPath(plate)
    ctx.clip()
    let grad = CGGradient(colorsSpace: space, colors: [bgBottom, bgTop] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Soft elliptical shadow under the foot.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 196)
    ctx.scaleBy(x: 1, y: 0.14)
    let sg = CGGradient(colorsSpace: space, colors: [shadowTone, srgb(139, 98, 55, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sg, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 205, options: [])
    ctx.restoreGState()

    // Glass body: cup + stem + foot as one flat sand-toned shape.
    let cup = cupPath(cx: 512, topY: 753, botY: 286, topHalf: 206, botHalf: 132, r: 44)
    let stem = CGPath(rect: CGRect(x: 486, y: 214, width: 52, height: 100), transform: nil)
    let foot = CGPath(
        roundedRect: CGRect(x: 380, y: 190, width: 264, height: 34),
        cornerWidth: 17, cornerHeight: 17, transform: nil)
    ctx.setFillColor(glassTone)
    ctx.addPath(cup)
    ctx.addPath(stem)
    ctx.addPath(foot)
    ctx.fillPath()

    // Interior inset leaves a visible glass wall + rim lip; three flat layers inside.
    let interior = cupPath(cx: 512, topY: 737, botY: 302, topHalf: 188, botHalf: 115, r: 32)
    ctx.saveGState()
    ctx.addPath(interior)
    ctx.clip()
    ctx.setFillColor(raspberry)
    ctx.fill(CGRect(x: 300, y: 302, width: 424, height: 176))
    ctx.setFillColor(honey)
    ctx.fill(CGRect(x: 300, y: 478, width: 424, height: 130))
    ctx.setFillColor(creamLayer)
    ctx.fill(CGRect(x: 300, y: 608, width: 424, height: 129))
    ctx.restoreGState()

    // Berry with a small highlight, plus a pointed leaf angled off its shoulder.
    ctx.setFillColor(raspberry)
    ctx.fillEllipse(in: CGRect(x: 512 - 56, y: 781 - 56, width: 112, height: 112))
    ctx.setFillColor(srgb(255, 255, 255, 0.5))
    ctx.fillEllipse(in: CGRect(x: 481, y: 793, width: 26, height: 26))

    ctx.saveGState()
    ctx.translateBy(x: 584, y: 843)
    ctx.rotate(by: .pi * 32 / 180)
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: -34, y: 0))
    leaf.addQuadCurve(to: CGPoint(x: 34, y: 0), control: CGPoint(x: 0, y: 26))
    leaf.addQuadCurve(to: CGPoint(x: -34, y: 0), control: CGPoint(x: 0, y: -26))
    ctx.setFillColor(leafGreen)
    ctx.addPath(leaf)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Menu bar template glyph (18-space; heavier strokes so 18px stays readable)

func drawMenuGlyph(in ctx: CGContext, px: Int) {
    ctx.saveGState()
    let s = CGFloat(px) / 18
    ctx.scaleBy(x: s, y: s)
    // Stronger taper + berry floating just above the rim so the solid
    // silhouette reads as a dessert glass, not a trophy.
    let p = CGMutablePath()
    p.addPath(cupPath(cx: 9, topY: 12.8, botY: 5.8, topHalf: 5.5, botHalf: 2.9, r: 1.2))
    p.addPath(CGPath(rect: CGRect(x: 8.25, y: 2.4, width: 1.5, height: 3.6), transform: nil))
    p.addPath(CGPath(
        roundedRect: CGRect(x: 5.0, y: 1.2, width: 8.0, height: 1.4),
        cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
    p.addEllipse(in: CGRect(x: 9 - 1.7, y: 15.0 - 1.7, width: 3.4, height: 3.4))
    ctx.setFillColor(srgb(0, 0, 0))
    ctx.addPath(p)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: swift MakeIcon.swift <outdir>\n", stderr)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderAppIcon(_ px: Int, to url: URL) {
    let ctx = makeContext(px)
    drawAppIcon(in: ctx, px: px)
    writePNG(ctx, to: url)
}

func renderMenuGlyph(_ px: Int, to url: URL) {
    let ctx = makeContext(px)
    drawMenuGlyph(in: ctx, px: px)
    writePNG(ctx, to: url)
}

// iconutil requires exactly these names; each rendered from vectors at its own size.
let iconsetEntries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in iconsetEntries {
    renderAppIcon(px, to: iconset.appendingPathComponent(name))
}
renderAppIcon(1024, to: outDir.appendingPathComponent("AppIcon-1024.png"))

renderMenuGlyph(18, to: outDir.appendingPathComponent("MenuBarIcon.png"))
renderMenuGlyph(36, to: outDir.appendingPathComponent("MenuBarIcon@2x.png"))
// Oversized render for design review only; not shipped.
renderMenuGlyph(288, to: outDir.appendingPathComponent("MenuBarIcon-preview.png"))

print("wrote icons to \(outDir.path)")
