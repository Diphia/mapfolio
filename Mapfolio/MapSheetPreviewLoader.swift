import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UIKit

final class MapSheetPreviewLoader: @unchecked Sendable {
    static let shared = MapSheetPreviewLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "cc.monism.antiquemaps.sheetPreview", qos: .userInitiated)

    private init() {
        cache.countLimit = 24
    }

    func cachedPreview(for map: HistoricalMapArchive) -> UIImage? {
        guard let url = map.bundleURL else { return nil }
        return cache.object(forKey: cacheKey(url: url, zoom: map.previewZoom, deskew: map.previewDeskewDegrees))
    }

    func invalidatePreview(for map: HistoricalMapArchive) {
        guard let url = map.bundleURL else { return }
        cache.removeObject(forKey: cacheKey(url: url, zoom: map.previewZoom, deskew: map.previewDeskewDegrees))
    }

    func loadPreview(for map: HistoricalMapArchive) async -> UIImage? {
        guard let url = map.bundleURL else { return nil }
        let key = cacheKey(url: url, zoom: map.previewZoom, deskew: map.previewDeskewDegrees)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let directPreviewURL = map.previewImageURL
        let preferredZoom = map.previewZoom
        let deskew = map.previewDeskewDegrees

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = self.cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                let rendered: UIImage?
                if let directPreviewURL,
                   let data = try? Data(contentsOf: directPreviewURL),
                   let image = UIImage(data: data) {
                    rendered = image
                } else {
                    rendered = Self.renderSheet(archiveURL: url, preferredZoom: preferredZoom, deskewDegrees: deskew)
                }
                if let rendered {
                    self.cache.setObject(rendered, forKey: key)
                }
                continuation.resume(returning: rendered)
            }
        }
    }

    private func cacheKey(url: URL, zoom: Int, deskew: Double) -> NSString {
        "\(url.path)#z\(zoom)#d\(Int((deskew * 10).rounded()))" as NSString
    }

    private static func renderSheet(archiveURL: URL, preferredZoom: Int, deskewDegrees: Double) -> UIImage? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(archiveURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let zoom = resolveZoomLevel(in: db, preferred: preferredZoom)
        let tiles = loadTiles(in: db, zoom: zoom)
        guard !tiles.isEmpty, let stitched = stitchAndTrim(tiles: tiles) else {
            return nil
        }

        let finalImage: CGImage
        if abs(deskewDegrees) > 0.1, let straightened = deskewAndTrim(image: stitched, degrees: deskewDegrees) {
            finalImage = straightened
        } else {
            finalImage = stitched
        }
        return UIImage(cgImage: finalImage)
    }

    private static func resolveZoomLevel(in db: OpaquePointer, preferred: Int) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT z, COUNT(*) FROM tiles GROUP BY z ORDER BY z ASC", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return preferred
        }
        defer { sqlite3_finalize(stmt) }

        var available: [(z: Int, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            available.append((Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int(stmt, 1))))
        }
        if available.contains(where: { $0.z == preferred && $0.count > 0 }) {
            return preferred
        }
        if let ideal = available.first(where: { $0.count >= 6 && $0.count <= 36 }) {
            return ideal.z
        }
        return available.first?.z ?? preferred
    }

    private static func loadTiles(in db: OpaquePointer, zoom: Int) -> [(x: Int, y: Int, image: CGImage)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT x, y, data FROM tiles WHERE z = ?", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(zoom))
        var results: [(Int, Int, CGImage)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let x = Int(sqlite3_column_int(stmt, 0))
            let y = Int(sqlite3_column_int(stmt, 1))
            guard let bytes = sqlite3_column_blob(stmt, 2) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: bytes, count: count)
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                results.append((x, y, image))
            }
        }
        return results
    }

    private static func stitchAndTrim(tiles: [(x: Int, y: Int, image: CGImage)]) -> CGImage? {
        guard let minX = tiles.map(\.x).min(),
              let maxX = tiles.map(\.x).max(),
              let minY = tiles.map(\.y).min(),
              let maxY = tiles.map(\.y).max() else {
            return nil
        }

        let tileSize = 256
        let width = (maxX - minX + 1) * tileSize
        let height = (maxY - minY + 1) * tileSize
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        for tile in tiles {
            let drawX = (tile.x - minX) * tileSize
            let drawY = height - (tile.y - minY + 1) * tileSize
            context.draw(tile.image, in: CGRect(x: drawX, y: drawY, width: tileSize, height: tileSize))
        }

        guard let rawData = context.data?.assumingMemoryBound(to: UInt8.self),
              let fullImage = context.makeImage() else {
            return nil
        }

        var top = height
        var bottom = 0
        var left = width
        var right = 0

        for row in 0..<height {
            let rowOffset = row * width * 4
            for col in 0..<width {
                if rawData[rowOffset + col * 4 + 3] > 20 {
                    if row < top { top = row }
                    if row > bottom { bottom = row }
                    if col < left { left = col }
                    if col > right { right = col }
                }
            }
        }

        guard right > left, bottom > top else { return fullImage }
        let cropRect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return fullImage.cropping(to: cropRect) ?? fullImage
    }

    private static func deskewAndTrim(image: CGImage, degrees: Double) -> CGImage? {
        let radians = degrees * .pi / 180.0
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let canvasW = Int(ceil(srcW * cosA + srcH * sinA)) + 16
        let canvasH = Int(ceil(srcW * sinA + srcH * cosA)) + 16

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: canvasW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(canvasW) / 2, y: CGFloat(canvasH) / 2)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -srcW / 2, y: -srcH / 2, width: srcW, height: srcH))

        guard let rawData = context.data?.assumingMemoryBound(to: UInt8.self),
              let rotated = context.makeImage() else {
            return nil
        }

        let rowThreshold = max(32, Int(srcW * 0.45))
        let colThreshold = max(32, Int(srcH * 0.45))

        var top = canvasH
        var bottom = 0
        for row in 0..<canvasH {
            let rowOffset = row * canvasW * 4
            var opaqueCount = 0
            for col in 0..<canvasW where rawData[rowOffset + col * 4 + 3] > 200 {
                opaqueCount += 1
            }
            if opaqueCount >= rowThreshold {
                if row < top { top = row }
                if row > bottom { bottom = row }
            }
        }

        var left = canvasW
        var right = 0
        for col in 0..<canvasW {
            var opaqueCount = 0
            for row in 0..<canvasH where rawData[(row * canvasW + col) * 4 + 3] > 200 {
                opaqueCount += 1
            }
            if opaqueCount >= colThreshold {
                if col < left { left = col }
                if col > right { right = col }
            }
        }

        let inset = 4
        let cropX = left + inset
        let cropY = top + inset
        let cropW = (right - left) - inset * 2
        let cropH = (bottom - top) - inset * 2
        guard cropW > 32, cropH > 32 else { return rotated }

        return rotated.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) ?? rotated
    }
}
