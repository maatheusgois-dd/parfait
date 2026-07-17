// Generates the Nutola app icon (all AppIcon.iconset sizes + 1024 master) and
// nav-bar template icons from Resources/AppIcon.svg.
// Run: swift scripts/MakeIcon.swift <outdir> [app|menu|all]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let appDesignSize: CGFloat = 321
let appBackgroundTop = srgb(154, 162, 255)    // #9AA2FF
let appBackgroundBottom = srgb(94, 107, 255)  // #5E6BFF at offset 0.674037
let appStripeLeft: CGFloat = 67
let appStripeRight: CGFloat = 253.214

/// Nav-bar glyph uses Resources/NavIcon.svg artboard (44×56), not AppIcon.svg.
let menuDesignW: CGFloat = 44
let menuDesignH: CGFloat = 56
let menuStripeLeft: CGFloat = 4
let menuStripeRight: CGFloat = 40

let stripeColors = [
    srgb(255, 249, 242), // cream
    srgb(242, 169, 59),  // honey
    srgb(224, 57, 107),  // raspberry
    srgb(90, 106, 207),  // blueberry
]

/// Stripe bands from Resources/AppIcon.svg (equal-height layers inside the cup).
let appStripeBands: [(CGFloat, CGFloat)] = [
    (42, 101.25),
    (101.25, 160.5),
    (160.5, 219.75),
    (219.75, 279),
]

/// Stripe bands from Resources/NavIcon.svg.
let menuStripeBands: [(CGFloat, CGFloat)] = [
    (8, 15),
    (18, 25),
    (28, 35),
    (38, 46),
]

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

/// Cup mask from Resources/AppIcon.svg (clips the stripe fills).
func nutolaIconCupPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 100.857, y: 42))
    p.addLine(to: CGPoint(x: 219.357, y: 42))
    p.addCurve(to: CGPoint(x: 243.298, y: 51.9165),
               control1: CGPoint(x: 228.337, y: 42), control2: CGPoint(x: 236.948, y: 45.5671))
    p.addCurve(to: CGPoint(x: 253.214, y: 75.8571),
               control1: CGPoint(x: 249.647, y: 58.266), control2: CGPoint(x: 253.214, y: 66.8777))
    p.addLine(to: CGPoint(x: 253.214, y: 202.821))
    p.addCurve(to: CGPoint(x: 230.902, y: 256.688),
               control1: CGPoint(x: 253.214, y: 223.025), control2: CGPoint(x: 245.188, y: 242.402))
    p.addCurve(to: CGPoint(x: 177.036, y: 279),
               control1: CGPoint(x: 216.616, y: 270.974), control2: CGPoint(x: 197.24, y: 279))
    p.addLine(to: CGPoint(x: 143.179, y: 279))
    p.addCurve(to: CGPoint(x: 89.3122, y: 256.688),
               control1: CGPoint(x: 122.975, y: 279), control2: CGPoint(x: 103.598, y: 270.974))
    p.addCurve(to: CGPoint(x: 67, y: 202.821),
               control1: CGPoint(x: 75.0259, y: 242.402), control2: CGPoint(x: 67, y: 223.025))
    p.addLine(to: CGPoint(x: 67, y: 75.8571))
    p.addCurve(to: CGPoint(x: 76.9165, y: 51.9165),
               control1: CGPoint(x: 67, y: 66.8777), control2: CGPoint(x: 70.5671, y: 58.266))
    p.addCurve(to: CGPoint(x: 100.857, y: 42),
               control1: CGPoint(x: 83.266, y: 45.5671), control2: CGPoint(x: 91.8777, y: 42))
    p.closeSubpath()
    return p
}

/// Stroke outline from Resources/AppIcon.svg (separate path, stroke-width 4).
func nutolaIconStrokePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 219.357, y: 40))
    p.addCurve(to: CGPoint(x: 244.712, y: 50.502),
               control1: CGPoint(x: 228.867, y: 40.0001), control2: CGPoint(x: 237.987, y: 43.7776))
    p.addCurve(to: CGPoint(x: 255.214, y: 75.8574),
               control1: CGPoint(x: 251.436, y: 57.2265), control2: CGPoint(x: 255.214, y: 66.3475))
    p.addLine(to: CGPoint(x: 255.214, y: 202.821))
    p.addCurve(to: CGPoint(x: 232.316, y: 258.102),
               control1: CGPoint(x: 255.214, y: 223.555), control2: CGPoint(x: 246.978, y: 243.44))
    p.addCurve(to: CGPoint(x: 177.036, y: 281),
               control1: CGPoint(x: 217.655, y: 272.763), control2: CGPoint(x: 197.77, y: 281))
    p.addLine(to: CGPoint(x: 143.179, y: 281))
    p.addCurve(to: CGPoint(x: 87.8984, y: 258.102),
               control1: CGPoint(x: 122.444, y: 281), control2: CGPoint(x: 102.56, y: 272.763))
    p.addCurve(to: CGPoint(x: 65, y: 202.821),
               control1: CGPoint(x: 73.2371, y: 243.44), control2: CGPoint(x: 65, y: 223.556))
    p.addLine(to: CGPoint(x: 65, y: 75.8574))
    p.addLine(to: CGPoint(x: 65.0107, y: 74.9668))
    p.addCurve(to: CGPoint(x: 75.502, y: 50.502),
               control1: CGPoint(x: 65.2387, y: 65.7796), control2: CGPoint(x: 68.9876, y: 57.0163))
    p.addCurve(to: CGPoint(x: 100.857, y: 40),
               control1: CGPoint(x: 82.2265, y: 43.7774), control2: CGPoint(x: 91.3475, y: 40))
    p.addLine(to: CGPoint(x: 219.357, y: 40))
    p.closeSubpath()
    return p
}

/// Cup silhouette from Resources/NavIcon.svg (44×56).
func nutolaMenuCupPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 10.5455, y: 8))
    p.addLine(to: CGPoint(x: 33.4545, y: 8))
    p.addCurve(to: CGPoint(x: 38.0829, y: 9.58999),
               control1: CGPoint(x: 35.1905, y: 8), control2: CGPoint(x: 36.8554, y: 8.57194))
    p.addCurve(to: CGPoint(x: 40, y: 13.4286),
               control1: CGPoint(x: 39.3104, y: 10.608), control2: CGPoint(x: 40, y: 11.9888))
    p.addLine(to: CGPoint(x: 40, y: 33.7857))
    p.addCurve(to: CGPoint(x: 35.6865, y: 42.4225),
               control1: CGPoint(x: 40, y: 37.0251), control2: CGPoint(x: 38.4484, y: 40.1319))
    p.addCurve(to: CGPoint(x: 25.2727, y: 46),
               control1: CGPoint(x: 32.9246, y: 44.7131), control2: CGPoint(x: 29.1786, y: 46))
    p.addLine(to: CGPoint(x: 18.7273, y: 46))
    p.addCurve(to: CGPoint(x: 8.31352, y: 42.4225),
               control1: CGPoint(x: 14.8214, y: 46), control2: CGPoint(x: 11.0754, y: 44.7131))
    p.addCurve(to: CGPoint(x: 4, y: 33.7857),
               control1: CGPoint(x: 5.55162, y: 40.1319), control2: CGPoint(x: 4, y: 37.0251))
    p.addLine(to: CGPoint(x: 4, y: 13.4286))
    p.addCurve(to: CGPoint(x: 5.91712, y: 9.58999),
               control1: CGPoint(x: 4, y: 11.9888), control2: CGPoint(x: 4.68961, y: 10.608))
    p.addCurve(to: CGPoint(x: 10.5455, y: 8),
               control1: CGPoint(x: 7.14463, y: 8.57194), control2: CGPoint(x: 8.80949, y: 8))
    p.closeSubpath()
    return p
}

func drawAppIcon(in ctx: CGContext, px: Int) {
    let scale = CGFloat(px) / appDesignSize

    // Background gradient from AppIcon.svg paint0_linear_6_14.
    let grad = CGGradient(
        colorsSpace: space,
        colors: [appBackgroundTop, appBackgroundBottom] as CFArray,
        locations: [0, 0.674037])!
    let bgX = 160 * scale
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: bgX, y: CGFloat(px)),
        end: CGPoint(x: bgX, y: CGFloat(px) * (1 - 328.5 / appDesignSize)),
        options: [])

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)

    let cup = nutolaIconCupPath()
    ctx.addPath(cup)
    ctx.clip()

    for (i, band) in appStripeBands.enumerated() {
        ctx.setFillColor(stripeColors[i])
        ctx.fill(CGRect(x: appStripeLeft, y: band.0, width: appStripeRight - appStripeLeft, height: band.1 - band.0))
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setStrokeColor(srgb(67, 50, 43, 0.12))
    ctx.setLineWidth(4)
    ctx.addPath(nutolaIconStrokePath())
    ctx.strokePath()
    ctx.restoreGState()
}

func drawMenuGlyph(in ctx: CGContext, px: Int) {
    let scale = CGFloat(px) / menuDesignH
    let renderW = menuDesignW * scale
    let offsetX = (CGFloat(px) - renderW) / 2

    ctx.saveGState()
    ctx.translateBy(x: offsetX, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)

    let cup = nutolaMenuCupPath()
    ctx.addPath(cup)
    ctx.clip()

    ctx.setFillColor(srgb(0, 0, 0))
    for band in menuStripeBands {
        ctx.fill(CGRect(x: menuStripeLeft, y: band.0, width: menuStripeRight - menuStripeLeft, height: band.1 - band.0))
    }
    ctx.restoreGState()
}

// MARK: - Driver

enum IconMode: String {
    case all, app, menu
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift MakeIcon.swift <outdir> [app|menu|all]\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
var mode: IconMode = .all

for arg in args.dropFirst(2) {
    if let parsed = IconMode(rawValue: arg) {
        mode = parsed
    } else {
        fputs("usage: swift MakeIcon.swift <outdir> [app|menu|all]\n", stderr)
        exit(1)
    }
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

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

if mode == .all || mode == .app {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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

}

if mode == .all || mode == .menu {
    renderMenuGlyph(18, to: outDir.appendingPathComponent("NavIcon.png"))
    renderMenuGlyph(36, to: outDir.appendingPathComponent("NavIcon@2x.png"))
    renderMenuGlyph(288, to: outDir.appendingPathComponent("NavIcon-preview.png"))
}

print("wrote \(mode.rawValue) icons to \(outDir.path)")
