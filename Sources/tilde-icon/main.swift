// Writes Tilde's app icon as an .iconset folder for iconutil; see scripts/build-app.sh.
//   tilde-icon <folder.iconset>

import AppKit
import TildeUI

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: tilde-icon <folder.iconset>")
    exit(2)
}

let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        TildeMark.appIconImage(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
