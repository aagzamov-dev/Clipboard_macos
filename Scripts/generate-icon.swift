import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("ClipboardApp/Resources")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 282, y: 224, width: 460, height: 554), xRadius: 65, yRadius: 65).fill()
    NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 372, y: 697, width: 280, height: 139), xRadius: 44, yRadius: 44).fill()
    NSColor(calibratedRed: 0.61, green: 0.86, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 404, y: 729, width: 216, height: 75), xRadius: 25, yRadius: 25).fill()
    NSColor(calibratedRed: 0.47, green: 0.54, blue: 0.54, alpha: 1).setFill()
    for (width, y) in [(264.0, 544.0), (264.0, 440.0), (164.0, 336.0)] {
        NSBezierPath(roundedRect: NSRect(x: 380, y: y, width: width, height: 30), xRadius: 15, yRadius: 15).fill()
    }
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
precondition(task.terminationStatus == 0)
