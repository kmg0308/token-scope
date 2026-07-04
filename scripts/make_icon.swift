import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "dist/TokenMeter.app/Contents/Resources/TokenMeter.icns"
let outputURL = URL(fileURLWithPath: output)
let fileManager = FileManager.default
let workURL = fileManager.temporaryDirectory
    .appendingPathComponent("TokenMeterIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workURL.appendingPathComponent("TokenMeter.iconset", isDirectory: true)
defer {
    try? fileManager.removeItem(at: workURL)
}

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

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let backgroundTop = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.060, alpha: 1)
    let backgroundBottom = NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 1)
    let barTop = NSColor(calibratedRed: 0.250, green: 0.700, blue: 1.000, alpha: 1)
    let barBottom = NSColor(calibratedRed: 0.000, green: 0.340, blue: 0.880, alpha: 1)
    let barShadow = NSColor(calibratedRed: 0.000, green: 0.180, blue: 0.520, alpha: 0.35)
    let axisColor = NSColor(calibratedRed: 0.150, green: 0.510, blue: 1.000, alpha: 0.34)
    let shineColor = NSColor.white.withAlphaComponent(0.16)
    let tile = NSBezierPath(
        roundedRect: canvas.insetBy(dx: size * 0.01, dy: size * 0.01),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    let backgroundGradient = NSGradient(starting: backgroundTop, ending: backgroundBottom)
    backgroundGradient?.draw(in: tile, angle: -90)

    let innerGlow = NSBezierPath(
        roundedRect: canvas.insetBy(dx: size * 0.045, dy: size * 0.045),
        xRadius: size * 0.18,
        yRadius: size * 0.18
    )
    NSColor(calibratedRed: 0.080, green: 0.240, blue: 0.470, alpha: 0.18).setStroke()
    innerGlow.lineWidth = max(1, size * 0.018)
    innerGlow.stroke()

    let axis = NSBezierPath(roundedRect: CGRect(
        x: size * 0.19,
        y: size * 0.22,
        width: size * 0.62,
        height: size * 0.045
    ), xRadius: size * 0.022, yRadius: size * 0.022)
    axisColor.setFill()
    axis.fill()

    let barWidth = size * 0.115
    let barGap = size * 0.055
    let startX = size * 0.245
    let baseY = size * 0.245
    let heights = [size * 0.225, size * 0.390, size * 0.545, size * 0.680]

    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * (barWidth + barGap)
        let barRect = CGRect(x: x, y: baseY, width: barWidth, height: height)

        let shadow = NSBezierPath(roundedRect: barRect.offsetBy(dx: size * 0.020, dy: -size * 0.018),
                                  xRadius: size * 0.040,
                                  yRadius: size * 0.040)
        barShadow.setFill()
        shadow.fill()

        let bar = NSBezierPath(roundedRect: barRect,
                               xRadius: size * 0.040,
                               yRadius: size * 0.040)
        NSGradient(starting: barTop, ending: barBottom)?.draw(in: bar, angle: -90)

        let highlightRect = CGRect(
            x: barRect.minX + barRect.width * 0.22,
            y: barRect.minY + barRect.height * 0.10,
            width: barRect.width * 0.26,
            height: barRect.height * 0.82
        )
        let highlight = NSBezierPath(roundedRect: highlightRect,
                                     xRadius: size * 0.018,
                                     yRadius: size * 0.018)
        shineColor.setFill()
        highlight.fill()
    }

    NSColor.black.withAlphaComponent(0.22).setStroke()
    tile.lineWidth = max(1, size * 0.018)
    tile.stroke()

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
