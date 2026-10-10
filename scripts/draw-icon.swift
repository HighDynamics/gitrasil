import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The Gitrasil icon recreated from a 50×54 px screenshot: a lobed crown with a few small
// holes, a straight trunk, and a ground line that runs out both ways and curls up at the right.
// Coordinates are the screenshot's pixels (y down); `draw` maps them onto any box.
//
// Usage: swiftc -O scripts/draw-icon.swift -o /tmp/draw-icon
//        /tmp/draw-icon Sources/GitrasilWallpaper/Resources/MenuBarIcon.pdf docs/yggdrasil \
//            [--iconset /tmp/AppIcon.iconset] [screenshot.png]
//   writes the 18×18 pt template PDF, and in the docs folder icon-template.png and icon-colour.png;
//   given the screenshot, also icon-compare.png (the screenshot, the glyph traced over it, the
//   colour glyph at the same scale, and the template, side by side). With --iconset, also the app
//   icon at every size; `iconutil -c icns /tmp/AppIcon.iconset -o packaging/AppIcon.icns` makes the
//   .icns scripts/build-app.sh puts in Gitrasil.app.

let copper = CGColor(srgbRed: 187 / 255, green: 117 / 255, blue: 69 / 255, alpha: 1)
let paper = CGColor(srgbRed: 248 / 255, green: 244 / 255, blue: 238 / 255, alpha: 1)

/// The glyph in screenshot pixels: the area it spans, and its outline as one filled path.
let span = CGRect(x: 13, y: 8.6, width: 25.4, height: 32)

func glyph(holes: CGFloat) -> CGPath {
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }
    // The crown: four lobes round a filled middle, necking down into the trunk.
    var crown: CGPath = circle(24.9, 12.9, 4.4)
    for lobe in [circle(32.4, 15.9, 4.4), circle(17.6, 17.8, 4.5), circle(23.4, 19.4, 4.3), circle(27.5, 17.2, 4.0)] {
        crown = crown.union(lobe, using: .winding)
    }
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 16.5, y: 21.5))
    neck.addQuadCurve(to: CGPoint(x: 23.2, y: 26.5), control: CGPoint(x: 21.2, y: 23.2))
    neck.addLine(to: CGPoint(x: 26.7, y: 26.5))
    neck.addQuadCurve(to: CGPoint(x: 29.5, y: 20.5), control: CGPoint(x: 26.9, y: 22.8))
    neck.closeSubpath()
    crown = crown.union(neck, using: .winding)

    let trunk = CGPath(rect: CGRect(x: 23.2, y: 24, width: 3.5, height: 15), transform: nil)
    let ground = CGMutablePath()
    ground.move(to: CGPoint(x: 16.6, y: 39))
    ground.addLine(to: CGPoint(x: 34.4, y: 39))
    ground.addQuadCurve(to: CGPoint(x: 36.6, y: 35.6), control: CGPoint(x: 36.7, y: 39))
    let groundStroke = ground.copy(strokingWithWidth: 3.3, lineCap: .round, lineJoin: .round, miterLimit: 10)

    var shape = crown.union(trunk, using: .winding).union(groundStroke, using: .winding)
    // The small holes in the crown: one per lobe, and a slightly larger one in the middle.
    for (x, y, r) in [(24.8, 13.4, 0.85), (32.7, 15.7, 0.8), (17.6, 17.6, 0.85), (23.6, 19.0, 1.0)] as [(CGFloat, CGFloat, CGFloat)] {
        shape = shape.subtracting(circle(x, y, r * holes), using: .winding)
    }
    return shape
}

/// Draws the glyph so its span is `height` tall, centred on `centre`, in a y-up context.
func draw(_ path: CGPath, in ctx: CGContext, centre: CGPoint, height: CGFloat, colour: CGColor) {
    let scale = height / span.height
    var t = CGAffineTransform(translationX: centre.x, y: centre.y)
        .scaledBy(x: scale, y: -scale)
        .translatedBy(x: -span.midX, y: -span.midY)
    guard let placed = path.copy(using: &t) else { return }
    ctx.addPath(placed)
    ctx.setFillColor(colour)
    ctx.fillPath()
}

func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

var args = CommandLine.arguments
var iconset: String?
if let flag = args.firstIndex(of: "--iconset"), flag + 1 < args.count {
    iconset = args[flag + 1]
    args.removeSubrange(flag...(flag + 1))
}

let outDir = args[2]

// The template: 18×18 pt, glyph 16 pt tall, black on transparent. Holes a touch larger so they
// survive at menu-bar size.
let template = glyph(holes: 1.25)
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
let pdf = CGContext(URL(fileURLWithPath: args[1]) as CFURL, mediaBox: &box,
                    [kCGPDFContextTitle: "Gitrasil menu-bar icon"] as CFDictionary)!
pdf.beginPDFPage(nil)
draw(template, in: pdf, centre: CGPoint(x: 9, y: 9), height: 16, colour: CGColor(gray: 0, alpha: 1))
pdf.endPDFPage()
pdf.closePDF()

// Large renders.
func templateImage(_ side: Int) -> CGImage {
    let ctx = bitmap(side, side)
    draw(template, in: ctx, centre: CGPoint(x: side / 2, y: side / 2), height: CGFloat(side) * 16 / 18,
         colour: CGColor(gray: 0, alpha: 1))
    return ctx.makeImage()!
}

/// The full-colour icon: copper on a paper tile with rounded corners, the glyph in the proportion
/// it has in the screenshot.
func colourImage(_ side: Int) -> CGImage {
    let ctx = bitmap(side, side)
    let s = CGFloat(side)
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
    ctx.setFillColor(paper)
    ctx.fillPath()
    draw(glyph(holes: 1), in: ctx, centre: CGPoint(x: s / 2, y: s / 2), height: tile.height * 0.6, colour: copper)
    return ctx.makeImage()!
}

save(templateImage(512), "\(outDir)/icon-template.png")
save(colourImage(1024), "\(outDir)/icon-colour.png")

/// The app icon: the colour icon, its tile on Apple's grid (824 of 1024, so macOS 26 shows it as
/// drawn rather than inside a grey tile), with a soft shadow beneath so the pale tile holds its edge
/// on a white Finder window.
func appIconImage(_ side: Int) -> CGImage {
    let ctx = bitmap(side, side)
    let s = CGFloat(side)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02,
                  color: CGColor(gray: 0, alpha: 0.3))
    ctx.draw(colourImage(side), in: CGRect(x: 0, y: 0, width: s, height: s))
    return ctx.makeImage()!
}

if let iconset {
    try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        save(appIconImage(points), "\(iconset)/icon_\(points)x\(points).png")
        save(appIconImage(points * 2), "\(iconset)/icon_\(points)x\(points)@2x.png")
    }
}

guard args.count > 3 else { exit(0) }

// Side by side, each 432 px tall: the screenshot (scaled up 8× without smoothing), the same glyph
// over it in outline, the colour glyph at the same scale, and the template.
let ref = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, nil)!, 0, nil)!
let cell = 432, gap = 24
let compare = bitmap(cell * 4 + gap * 5, cell + gap * 2)
compare.setFillColor(CGColor(gray: 1, alpha: 1))
compare.fill(CGRect(x: 0, y: 0, width: compare.width, height: compare.height))
compare.interpolationQuality = .none
let refRect = CGRect(x: gap, y: gap, width: 400, height: 432)
compare.draw(ref, in: refRect)
// Overlay: the recreated outline on the screenshot, in the screenshot's own pixel grid.
compare.saveGState()
compare.translateBy(x: CGFloat(gap * 2 + cell), y: CGFloat(gap))
compare.draw(ref, in: CGRect(x: 0, y: 0, width: 400, height: 432))
var toRef = CGAffineTransform(translationX: 0, y: 432).scaledBy(x: 8, y: -8)
compare.addPath(glyph(holes: 1).copy(using: &toRef)!)
compare.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
compare.setLineWidth(2)
compare.strokePath()
compare.restoreGState()
compare.saveGState()
compare.translateBy(x: CGFloat(gap * 3 + cell * 2), y: CGFloat(gap))
compare.setFillColor(paper)
compare.fill(CGRect(x: 0, y: 0, width: 400, height: 432))
var same = CGAffineTransform(translationX: 0, y: 432).scaledBy(x: 8, y: -8)
compare.addPath(glyph(holes: 1).copy(using: &same)!)
compare.setFillColor(copper)
compare.fillPath()
compare.restoreGState()
compare.draw(templateImage(cell), in: CGRect(x: gap * 4 + cell * 3, y: gap, width: cell, height: cell))
save(compare.makeImage()!, "\(outDir)/icon-compare.png")
