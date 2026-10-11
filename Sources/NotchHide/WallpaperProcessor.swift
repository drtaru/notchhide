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
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProcessError.unreadable(source)
        }

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
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ProcessError.writeFailed }
        try png.write(to: outURL, options: .atomic)
        return outURL
    }
}
