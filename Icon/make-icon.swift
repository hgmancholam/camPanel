import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Lienzo de diseño 1024x1024, coordenadas con el origen arriba a la izquierda.
let CANVAS: CGFloat = 1024

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

let space = CGColorSpaceCreateDeviceRGB()

func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
}

func render(size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // escala al lienzo de diseño y voltea el eje Y para pensar de arriba hacia abajo
    let k = size / CANVAS
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: 0, y: CANVAS)
    ctx.scaleBy(x: 1, y: -1)

    // --- cuerpo: squircle con la proporción de los iconos de macOS ---
    let inset: CGFloat = 92
    let body = CGRect(x: inset, y: inset - 12, width: CANVAS - inset*2, height: CANVAS - inset*2)
    let radius = body.width * 0.2245
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 46, color: rgb(0, 0, 0, 0.42))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(20, 24, 40))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(64, 78, 138), rgb(38, 45, 84), rgb(19, 22, 39)], [0, 0.52, 1]),
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: [])

    // luz superior, muy suave, para que no se vea plano
    ctx.drawRadialGradient(
        gradient([rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)], [0, 1]),
        startCenter: CGPoint(x: body.midX, y: body.minY + 40), startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.minY + 40), endRadius: body.width * 0.72,
        options: [])
    ctx.restoreGState()

    // borde interior tenue
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.13))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // --- lente ---
    let cx = CANVAS / 2
    let cy: CGFloat = 378
    let rOuter: CGFloat = 196

    // aro exterior
    ctx.setStrokeColor(rgb(236, 240, 252, 0.92))
    ctx.setLineWidth(30)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rOuter, startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.strokePath()

    // cristal
    ctx.saveGState()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rOuter - 22, startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([rgb(46, 60, 112), rgb(14, 18, 34)], [0, 1]),
        startCenter: CGPoint(x: cx - 60, y: cy - 70), startRadius: 10,
        endCenter: CGPoint(x: cx, y: cy), endRadius: rOuter,
        options: [])
    ctx.restoreGState()

    // anillo interior del diafragma
    ctx.setStrokeColor(rgb(255, 255, 255, 0.18))
    ctx.setLineWidth(12)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: 110, startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.strokePath()

    // reflejo del cristal: arco claro arriba a la izquierda
    ctx.setStrokeColor(rgb(255, 255, 255, 0.30))
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rOuter - 74,
               startAngle: .pi * 1.08, endAngle: .pi * 1.52, clockwise: false)
    ctx.strokePath()

    // punto especular
    ctx.setFillColor(rgb(255, 255, 255, 0.85))
    ctx.fillEllipse(in: CGRect(x: cx - 112, y: cy - 120, width: 40, height: 40))

    // --- tres sliders: esto es un panel de ajustes, no un visor ---
    let trackX: CGFloat = 296
    let trackW: CGFloat = 432
    let rows: [(CGFloat, CGFloat)] = [(652, 0.32), (754, 0.68), (856, 0.48)]

    for (y, pos) in rows {
        ctx.setLineCap(.round)
        ctx.setLineWidth(30)
        ctx.setStrokeColor(rgb(255, 255, 255, 0.30))
        ctx.move(to: CGPoint(x: trackX, y: y))
        ctx.addLine(to: CGPoint(x: trackX + trackW, y: y))
        ctx.strokePath()

        // tramo recorrido, en el ámbar de acento
        ctx.setStrokeColor(rgb(255, 178, 44, 0.95))
        ctx.move(to: CGPoint(x: trackX, y: y))
        ctx.addLine(to: CGPoint(x: trackX + trackW * pos, y: y))
        ctx.strokePath()

        // perilla
        let kx = trackX + trackW * pos
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: rgb(0, 0, 0, 0.45))
        ctx.setFillColor(rgb(255, 255, 255))
        ctx.fillEllipse(in: CGRect(x: kx - 34, y: y - 34, width: 68, height: 68))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./CamPanel.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    write(render(size: size), to: outDir + "/" + name)
}
print("iconset generado en \(outDir)")
