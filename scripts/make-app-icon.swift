import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
}

func drawIcon(_ context: CGContext) {
    let bounds = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: bounds, cornerWidth: 188, cornerHeight: 188, transform: nil)

    context.saveGState()
    context.setFillColor(color(0x11212C))
    context.setShadow(offset: CGSize(width: 0, height: -15), blur: 36, color: color(0x030810, alpha: 0.35))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x163D4C), color(0x102631), color(0x0C1826)]),
        start: CGPoint(x: 215, y: 130),
        end: CGPoint(x: 807, y: 910),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    let glowCenter = CGPoint(x: 375, y: 325)
    context.drawRadialGradient(
        gradient([color(0x58E6CA, alpha: 0.19), color(0x58E6CA, alpha: 0)]),
        startCenter: glowCenter,
        startRadius: 0,
        endCenter: glowCenter,
        endRadius: 475,
        options: []
    )
    context.restoreGState()

    context.setLineWidth(6)
    context.setStrokeColor(color(0xB8EAE8, alpha: 0.24))
    context.addPath(tile)
    context.strokePath()

    let hotspot = CGPoint(x: 380, y: 294)
    context.setStrokeColor(color(0x8DFCE3, alpha: 0.31))
    context.strokeEllipse(in: CGRect(x: hotspot.x - 91, y: hotspot.y - 91, width: 182, height: 182))
    context.setStrokeColor(color(0x8DFCE3, alpha: 0.62))
    context.strokeEllipse(in: CGRect(x: hotspot.x - 57, y: hotspot.y - 57, width: 114, height: 114))

    let pointer = CGMutablePath()
    pointer.move(to: hotspot)
    pointer.addLine(to: CGPoint(x: 713, y: 555))
    pointer.addLine(to: CGPoint(x: 574, y: 573))
    pointer.addLine(to: CGPoint(x: 642, y: 714))
    pointer.addLine(to: CGPoint(x: 564, y: 750))
    pointer.addLine(to: CGPoint(x: 495, y: 607))
    pointer.addLine(to: CGPoint(x: 394, y: 699))
    pointer.closeSubpath()

    context.setLineJoin(.round)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -17), blur: 28, color: color(0x050C15, alpha: 0.64))
    context.setLineWidth(28)
    context.setStrokeColor(color(0x0C1926))
    context.setFillColor(color(0x83F4D2))
    context.addPath(pointer)
    context.drawPath(using: .fillStroke)
    context.restoreGState()

    context.saveGState()
    context.addPath(pointer)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xC8FFEE), color(0x6AF3CB), color(0x39C4A9)]),
        start: hotspot,
        end: CGPoint(x: 626, y: 739),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    context.setLineWidth(7)
    context.setStrokeColor(color(0xCAFFEC, alpha: 0.8))
    context.addPath(pointer)
    context.strokePath()
}

enum IconError: Error {
    case unableToWrite(URL)
}

func iconElement(type: String, payload: Data) -> Data {
    var element = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { element.append(contentsOf: $0) }
    element.append(payload)
    return element
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let representations = [
    (16, "icp4"), (32, "icp5"), (128, "ic07"), (256, "ic08"), (512, "ic09"),
    (32, "ic11"), (64, "ic12"), (256, "ic13"), (512, "ic14"), (1024, "ic10"),
]
var contents = Data()
for (side, type) in representations {
    let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let unit = CGFloat(side) / 1024
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: unit, y: -unit)
    drawIcon(context)

    let png = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.unableToWrite(output) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.unableToWrite(output) }
    contents.append(iconElement(type: type, payload: png as Data))
}
try iconElement(type: "icns", payload: contents).write(to: output, options: .atomic)
