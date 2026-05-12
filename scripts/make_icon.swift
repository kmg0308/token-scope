import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "dist/TokenMeter.app/Contents/Resources/TokenMeter.icns"
let outputURL = URL(fileURLWithPath: output)
let fileManager = FileManager.default
let workURL = fileManager.temporaryDirectory
    .appendingPathComponent("TokenMeterIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workURL.appendingPathComponent("TokenMeter.iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

for item in sizes {
    let pixels = Int(item.points * item.scale)
    let image = drawIcon(size: CGFloat(pixels))
    let url = iconsetURL.appendingPathComponent(item.name)
    try writePNG(image, to: url)
}

let process = Process()
try? fileManager.removeItem(at: outputURL)
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "TokenMeterIcon", code: Int(process.terminationStatus))
}

try? fileManager.removeItem(at: workURL)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let tileColor = NSColor.white
    let markColor = NSColor.black
    let tile = NSBezierPath(
        roundedRect: canvas.insetBy(dx: size * 0.01, dy: size * 0.01),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    tileColor.setFill()
    tile.fill()

    let markBounds = canvas.insetBy(dx: size * 0.14, dy: size * 0.14)
    let outer = NSBezierPath(ovalIn: markBounds)
    let inner = NSBezierPath(ovalIn: markBounds.insetBy(dx: size * 0.145, dy: size * 0.145))
    outer.append(inner.reversed)
    markColor.setFill()
    outer.fill()

    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    let cutWidth = size * 0.14
    let verticalCut = NSBezierPath(roundedRect: CGRect(
        x: center.x - cutWidth / 2,
        y: markBounds.minY - size * 0.02,
        width: cutWidth,
        height: markBounds.height + size * 0.04
    ), xRadius: cutWidth / 2, yRadius: cutWidth / 2)
    tileColor.setFill()
    verticalCut.fill()

    let tokenSize = size * 0.12
    let token = NSBezierPath(ovalIn: CGRect(
        x: center.x - tokenSize / 2,
        y: center.y - tokenSize / 2,
        width: tokenSize,
        height: tokenSize
    ))
    markColor.setFill()
    token.fill()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TokenMeterIcon", code: 1)
    }
    try png.write(to: url)
}
