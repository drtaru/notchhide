import AppKit
import CryptoKit
import ImageIO

enum ProcessError: LocalizedError {
    case noWallpaper
    case unreadable(URL)
    case renderFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noWallpaper: return "No wallpaper URL for this screen."
        case .unreadable(let url): return "Cannot read \(url.lastPathComponent) as a still image (dynamic/aerial wallpapers are unsupported)."
        case .renderFailed: return "Image render failed."
        case .writeFailed: return "Could not write processed image."
        }
    }
}

enum WallpaperProcessor {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchHide", isDirectory: true)
    }()
    static let processedDir = supportDir.appendingPathComponent("processed", isDirectory: true)

    static func isProcessed(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(processedDir.standardizedFileURL.path)
    }

    static let maxProcessedImages = 20

    /// Keeps only the `maxProcessedImages` most recently written/used processed PNGs.
    /// Files in `keeping` (wallpapers currently applied) are never deleted.
    static func prune(keeping: [URL] = []) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: processedDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let protected = Set(keeping.map { $0.standardizedFileURL.path })
        let pngs = files.filter { $0.pathExtension == "png" }
        guard pngs.count > maxProcessedImages else { return }

        func mtime(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let newestFirst = pngs.sorted { mtime($0) > mtime($1) }
        for url in newestFirst.dropFirst(maxProcessedImages) where !protected.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
    }

    /// Height in points of the black bar: the full menu bar strip, so the notch blends in.
    static func barHeight(for screen: NSScreen) -> CGFloat {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(menuBar, screen.safeAreaInsets.top)
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(num.uint32Value)) != 0
    }

    /// Renders `source` fill-cropped to the screen's pixel size with a black bar on top.
    /// Returns the URL of the processed PNG (cached by content key).
    static func process(source: URL, for screen: NSScreen) throws -> URL {
        // Pool drains the transient bitmaps; pressure relief hands freed malloc pages back to the OS
        // so the idle footprint doesn't stay at the rendering peak.
        defer { malloc_zone_pressure_relief(nil, 0) }
        return try autoreleasepool { try render(source: source, for: screen) }
    }

    private static func render(source: URL, for screen: NSScreen) throws -> URL {
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        let barPx = Int((barHeight(for: screen) * scale).rounded(.up))

        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let key = "\(source.path)|\(attrs?[.modificationDate] ?? "")|\(attrs?[.size] ?? "")|\(width)x\(height)|\(barPx)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let outURL = processedDir.appendingPathComponent("\(digest).png")
        if FileManager.default.fileExists(atPath: outURL.path) {
            // Bump mtime so pruning treats reused images as recent.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: outURL.path)
            return outURL
        }

        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let srcW = props[kCGImagePropertyPixelWidth] as? Int,
              let srcH = props[kCGImagePropertyPixelHeight] as? Int,
              srcW > 0, srcH > 0 else {
            throw ProcessError.unreadable(source)
        }

        // Decode straight to the size we need instead of the full-resolution bitmap
        // (a 6K wallpaper is ~100 MB decoded). Never upscale: only use a thumbnail when shrinking.
        let fillScale = max(CGFloat(width) / CGFloat(srcW), CGFloat(height) / CGFloat(srcH))
        let needed = Int((CGFloat(max(srcW, srcH)) * fillScale).rounded(.up))
        let decoded: CGImage?
        if needed < max(srcW, srcH) {
            decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: needed,
            ] as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image = decoded else { throw ProcessError.unreadable(source) }

        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProcessError.renderFailed
        }
        ctx.interpolationQuality = .high

        // Aspect-fill, centered.
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let fill = max(CGFloat(width) / iw, CGFloat(height) / ih)
        let dw = iw * fill, dh = ih * fill
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))

        // CGContext origin is bottom-left, so the top bar sits at y = height - barPx.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - barPx, width: width, height: barPx))

        guard let out = ctx.makeImage() else { throw ProcessError.renderFailed }
        try FileManager.default.createDirectory(at: processedDir, withIntermediateDirectories: true)
        // Encode straight to disk; avoids NSBitmapImageRep's extra bitmap copy and an in-memory PNG Data.
        let tmpURL = outURL.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw ProcessError.writeFailed
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ProcessError.writeFailed
        }
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tmpURL, to: outURL)
        return outURL
    }
}
