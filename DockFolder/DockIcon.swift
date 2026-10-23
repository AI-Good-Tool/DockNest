import AppKit

@MainActor
enum DockIcon {
    static func render(icons: [NSImage] = []) -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        let body = NSBezierPath(roundedRect: NSRect(x: 38, y: 52, width: 436, height: 374), xRadius: 88, yRadius: 88)
        let tab = NSBezierPath(roundedRect: NSRect(x: 56, y: 336, width: 196, height: 120), xRadius: 34, yRadius: 34)
        NSColor(calibratedRed: 0.26, green: 0.60, blue: 0.96, alpha: 1).setFill()
        tab.fill()
        NSGradient(starting: NSColor(calibratedRed: 0.46, green: 0.80, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.92, alpha: 1))!.draw(in: body, angle: -90)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        body.lineWidth = 3
        body.stroke()
        for index in 0..<4 {
            let rect = NSRect(x: 102 + (index % 2) * 164, y: 242 - (index / 2) * 154, width: 144, height: 144)
            if index < icons.count {
                icons[index].draw(in: rect)
            } else {
                NSColor.white.withAlphaComponent(0.24).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: 27, yRadius: 27).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    /// Standard PNG-backed ICNS chunks; macOS can read these without launching the app.
    static func icnsData(for image: NSImage) throws -> Data {
        func integer(_ value: Int) -> Data {
            var big = UInt32(value).bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        var chunks = Data()
        for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw FolderInstance.failure("无法创建静态图标。")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FolderInstance.failure("无法编码静态图标。")
            }
            chunks.append(Data(type.utf8))
            chunks.append(integer(png.count + 8))
            chunks.append(png)
        }
        var data = Data("icns".utf8)
        data.append(integer(chunks.count + 8))
        data.append(chunks)
        return data
    }

}
