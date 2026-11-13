import AppKit
import ImageIO

// Resize the supplied artwork without changing its layout or background.
// Usage: swift govi/draw_icon.swift <output-directory>
let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("app-icon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fatalError("Unable to load \(sourceURL.path)")
}
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(size).png"))
}
