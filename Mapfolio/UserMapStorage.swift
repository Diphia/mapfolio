import CoreGraphics
import Foundation
import ImageIO
import MapKit
import SQLite3
import UIKit
import UniformTypeIdentifiers

struct SerializedMapRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: MKMapRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var mapRect: MKMapRect {
        MKMapRect(x: x, y: y, width: width, height: height)
    }
}

struct UserMapRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var yearNumber: String
    var regionLabel: String
    var createdAt: Date
    var updatedAt: Date
    var imageWidth: Double
    var imageHeight: Double
    var roughPlacement: RoughMapPlacement
    var controlPoints: [CalibrationControlPoint]
    var transform: MapAffineTransform
    var fitMode: CalibrationFitMode
    var bounds: SerializedMapRect
    var minZoom: Int
    var maxZoom: Int
    var calibrationProfile: String
    /// Incrementing revision forces MapCanvas / preview caches to reload after recalibration.
    var revision: Int

    var previewZoom: Int {
        min(maxZoom, max(minZoom, minZoom + 2))
    }
}

struct BakedTileArchiveResult {
    let minZoom: Int
    let maxZoom: Int
    let tileCount: Int
}

enum UserMapTileBakerError: LocalizedError {
    case invalidImage
    case invalidTransform
    case sqliteFailure(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Unable to decode the selected map image."
        case .invalidTransform:
            return "The map alignment transform is invalid."
        case .sqliteFailure(let message):
            return "Failed to write tile archive: \(message)"
        case .emptyOutput:
            return "No map tiles could be generated for the current alignment."
        }
    }
}

enum UserMapTileBaker {
    private static let tileSize = 256
    private static let maxTilesAtMaxZoom = 220
    private static let maxZoomSpan = 6

    static func computeZoomRange(
        imageSize: CGSize,
        transform: MapAffineTransform,
        bounds: MKMapRect
    ) -> ClosedRange<Int> {
        let worldWidth = MKMapRect.world.width
        let mpp = transform.averageMapPointsPerPixel
        let nativeZoom = log2(worldWidth / (Double(tileSize) * max(1e-6, mpp)))
        var maxZoom = min(19, max(4, Int(ceil(nativeZoom))))

        while maxZoom > 4 {
            let range = tileIndexBounds(for: bounds, zoom: maxZoom)
            let count = (range.x1 - range.x0 + 1) * (range.y1 - range.y0 + 1)
            if count <= maxTilesAtMaxZoom {
                break
            }
            maxZoom -= 1
        }

        let maxSpan = max(1.0, max(bounds.width, bounds.height))
        let fitZoom = Int(floor(log2(worldWidth / maxSpan)))
        let minZoom = max(2, min(maxZoom, max(maxZoom - maxZoomSpan, fitZoom - 1)))
        return minZoom...maxZoom
    }

    static func tileIndexBounds(for bounds: MKMapRect, zoom: Int) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        let count = 1 << zoom
        let span = MKMapRect.world.width / Double(count)
        let x0 = max(0, min(count - 1, Int(floor(bounds.minX / span))))
        let x1 = max(x0, min(count - 1, Int(floor((bounds.maxX - 1e-6) / span))))
        let y0 = max(0, min(count - 1, Int(floor(bounds.minY / span))))
        let y1 = max(y0, min(count - 1, Int(floor((bounds.maxY - 1e-6) / span))))
        return (x0, x1, y0, y1)
    }

    static func bake(
        image: UIImage,
        transform: MapAffineTransform,
        to outputURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> BakedTileArchiveResult {
        guard let cgImage = image.cgImage else {
            throw UserMapTileBakerError.invalidImage
        }
        guard transform.isValid else {
            throw UserMapTileBakerError.invalidTransform
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let bounds = transform.boundingMapRect(imageSize: imageSize)
        let zoomRange = computeZoomRange(imageSize: imageSize, transform: transform, bounds: bounds)

        var totalCandidates = 0
        for zoom in zoomRange {
            let r = tileIndexBounds(for: bounds, zoom: zoom)
            totalCandidates += (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1)
        }
        totalCandidates = max(1, totalCandidates)

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            tempURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw UserMapTileBakerError.sqliteFailure("Could not create temporary SQLite file.")
        }

        var closed = false
        defer {
            if !closed { sqlite3_close(db) }
        }

        try execSQL(db, """
            CREATE TABLE tiles (
                z INTEGER NOT NULL,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (z, x, y)
            ) WITHOUT ROWID;
            PRAGMA user_version = 1;
            PRAGMA synchronous = OFF;
            PRAGMA journal_mode = MEMORY;
            BEGIN TRANSACTION;
            """)

        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO tiles (z, x, y, data) VALUES (?, ?, ?, ?)",
            -1,
            &insertStmt,
            nil
        ) == SQLITE_OK, let insertStmt else {
            throw UserMapTileBakerError.sqliteFailure("Could not prepare INSERT statement.")
        }
        defer { sqlite3_finalize(insertStmt) }

        let bytesPerRow = tileSize * 4
        var buffer = [UInt8](repeating: 0, count: tileSize * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let worldWidth = MKMapRect.world.width
        var processed = 0
        var writtenCount = 0

        for zoom in zoomRange {
            let tileSpan = worldWidth / Double(1 << zoom)
            let scale = Double(tileSize) / tileSpan
            let range = tileIndexBounds(for: bounds, zoom: zoom)

            for y in range.y0...range.y1 {
                let tileOriginY = Double(y) * tileSpan
                for x in range.x0...range.x1 {
                    let tileOriginX = Double(x) * tileSpan
                    processed += 1

                    let encodedData: Data? = autoreleasepool {
                        buffer.withUnsafeMutableBytes { rawBuffer in
                            guard let baseAddress = rawBuffer.baseAddress else { return nil }
                            memset(baseAddress, 0, rawBuffer.count)
                            guard let context = CGContext(
                                data: baseAddress,
                                width: tileSize,
                                height: tileSize,
                                bitsPerComponent: 8,
                                bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: bitmapInfo
                            ) else {
                                return nil
                            }

                            context.interpolationQuality = .high
                            // Flip raw bottom-up bitmap context into top-down XYZ tile coordinates.
                            context.translateBy(x: 0, y: CGFloat(tileSize))
                            context.scaleBy(x: 1, y: -1)

                            let tileTransform = transform.cgTransform(
                                originX: tileOriginX,
                                originY: tileOriginY,
                                scale: scale
                            )
                            context.concatenate(tileTransform)

                            // Counter-flip CGImage drawing inside image space.
                            context.translateBy(x: 0, y: imageSize.height)
                            context.scaleBy(x: 1, y: -1)
                            context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))

                            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
                            var anyNonZeroAlpha = false
                            var allOpaqueAlpha = true
                            let pixelCount = tileSize * tileSize
                            for idx in 0..<pixelCount {
                                let alpha = ptr[idx * 4 + 3]
                                if alpha != 0 { anyNonZeroAlpha = true }
                                if alpha != 255 { allOpaqueAlpha = false }
                                if anyNonZeroAlpha && !allOpaqueAlpha { break }
                            }

                            guard anyNonZeroAlpha, let tileCGImage = context.makeImage() else {
                                return nil
                            }

                            return encodeTile(tileCGImage, opaque: allOpaqueAlpha)
                        }
                    }

                    if let data = encodedData {
                        sqlite3_reset(insertStmt)
                        sqlite3_clear_bindings(insertStmt)
                        sqlite3_bind_int(insertStmt, 1, Int32(zoom))
                        sqlite3_bind_int(insertStmt, 2, Int32(x))
                        sqlite3_bind_int(insertStmt, 3, Int32(y))
                        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                        _ = data.withUnsafeBytes { bytes in
                            sqlite3_bind_blob(insertStmt, 4, bytes.baseAddress, Int32(data.count), transient)
                        }
                        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                            throw UserMapTileBakerError.sqliteFailure("Failed inserting tile (\(zoom),\(x),\(y)).")
                        }
                        writtenCount += 1
                    }

                    if processed % 8 == 0 || processed == totalCandidates {
                        onProgress?(Double(processed) / Double(totalCandidates))
                    }
                }
            }
        }

        try execSQL(db, "COMMIT;")
        guard writtenCount > 0 else {
            throw UserMapTileBakerError.emptyOutput
        }

        sqlite3_close(db)
        closed = true

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }

        return BakedTileArchiveResult(
            minZoom: zoomRange.lowerBound,
            maxZoom: zoomRange.upperBound,
            tileCount: writtenCount
        )
    }

    private static func execSQL(_ db: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw UserMapTileBakerError.sqliteFailure(message)
        }
    }

    private static func encodeTile(_ image: CGImage, opaque: Bool) -> Data? {
        let output = NSMutableData()
        let typeIdentifier = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier, 1, nil) else {
            return nil
        }
        if opaque {
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.85
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

final class UserMapStorage {
    static let shared = UserMapStorage()

    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = base
                .appendingPathComponent("cc.monism.antiquemaps", isDirectory: true)
                .appendingPathComponent("UserMaps", isDirectory: true)
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func mapDirectory(for id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func metadataURL(for id: String) -> URL {
        mapDirectory(for: id).appendingPathComponent("metadata.json")
    }

    func sourceImageURL(for id: String) -> URL {
        mapDirectory(for: id).appendingPathComponent("source.jpg")
    }

    func previewImageURL(for id: String) -> URL {
        mapDirectory(for: id).appendingPathComponent("preview.jpg")
    }

    func tilesURL(for id: String, revision: Int) -> URL {
        mapDirectory(for: id).appendingPathComponent("tiles-r\(revision).sqlite")
    }

    func loadAllRecords() -> [UserMapRecord] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: rootDirectory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var records: [UserMapRecord] = []
        for entry in entries {
            let metaURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let record = try? decoder.decode(UserMapRecord.self, from: data) else {
                continue
            }
            let tiles = tilesURL(for: record.id, revision: record.revision)
            guard FileManager.default.fileExists(atPath: tiles.path) else { continue }
            records.append(record)
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func loadRecord(id: String) -> UserMapRecord? {
        let metaURL = metadataURL(for: id)
        guard let data = try? Data(contentsOf: metaURL),
              let record = try? decoder.decode(UserMapRecord.self, from: data) else {
            return nil
        }
        return record
    }

    func loadSourceImage(id: String) -> UIImage? {
        let url = sourceImageURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImportedMapImageUtilities.normalizedUprightImage(from: data)
    }

    func makeArchive(from record: UserMapRecord) -> HistoricalMapArchive {
        let tiles = tilesURL(for: record.id, revision: record.revision)
        let preview = previewImageURL(for: record.id)
        let trimmedYear = record.yearNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearNumber = trimmedYear.isEmpty ? "USER" : trimmedYear
        let region = record.regionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return HistoricalMapArchive(
            id: record.id,
            title: record.title,
            yearLabel: yearNumber,
            yearNumber: yearNumber,
            displayTitle: trimmedYear.isEmpty ? record.title : "\(yearNumber) \(record.title)",
            layerTitle: record.title,
            regionLabel: region,
            sourceShort: "Imported from Photos",
            sourceCompact: "Imported from Photos",
            sourceAttribution: "Photos Library",
            resourceName: "",
            resourceExtension: "sqlite",
            previewZoom: record.previewZoom,
            previewDeskewDegrees: 0,
            bounds: record.bounds.mapRect,
            sourceURL: nil,
            defaultState: HistoricalMapLayerState(isEnabled: true, opacity: .translucent),
            fileURL: tiles,
            previewImageURL: FileManager.default.fileExists(atPath: preview.path) ? preview : nil,
            isUserImported: true,
            controlPointCount: record.controlPoints.count
        )
    }

    func saveMap(
        existingRecord: UserMapRecord?,
        image: UIImage,
        title: String,
        yearNumber: String,
        regionLabel: String,
        roughPlacement: RoughMapPlacement,
        controlPoints: [CalibrationControlPoint],
        fitResult: CalibrationFitResult,
        calibrationProfile: ShanghaiDisplayProfile,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> UserMapRecord {
        let upright = ImportedMapImageUtilities.redrawUpright(image)
        let id = existingRecord?.id ?? "user-\(UUID().uuidString.lowercased())"
        let revision = (existingRecord?.revision ?? 0) + 1
        let now = Date()

        let dir = mapDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Persist normalized source image for future recalibration.
        let srcURL = sourceImageURL(for: id)
        if let jpegData = upright.jpegData(compressionQuality: 0.90) {
            try jpegData.write(to: srcURL, options: .atomic)
        }

        // Persist crisp upright preview for 2.5D gallery stage.
        let previewImage = ImportedMapImageUtilities.redrawUpright(upright, maxDimension: 1200)
        let prevURL = previewImageURL(for: id)
        if let prevData = previewImage.jpegData(compressionQuality: 0.85) {
            try prevData.write(to: prevURL, options: .atomic)
        }

        let targetTilesURL = tilesURL(for: id, revision: revision)
        let bakeResult = try UserMapTileBaker.bake(
            image: upright,
            transform: fitResult.transform,
            to: targetTilesURL,
            onProgress: onProgress
        )

        let bounds = fitResult.transform.boundingMapRect(imageSize: upright.size)
        let record = UserMapRecord(
            id: id,
            title: title,
            yearNumber: yearNumber,
            regionLabel: regionLabel,
            createdAt: existingRecord?.createdAt ?? now,
            updatedAt: now,
            imageWidth: Double(upright.size.width),
            imageHeight: Double(upright.size.height),
            roughPlacement: roughPlacement,
            controlPoints: controlPoints,
            transform: fitResult.transform,
            fitMode: fitResult.mode,
            bounds: SerializedMapRect(bounds),
            minZoom: bakeResult.minZoom,
            maxZoom: bakeResult.maxZoom,
            calibrationProfile: calibrationProfile.rawValue,
            revision: revision
        )

        let encoded = try encoder.encode(record)
        try encoded.write(to: metadataURL(for: id), options: .atomic)

        // Clean up previous revision SQLite file after new metadata is committed.
        if let prevRev = existingRecord?.revision, prevRev != revision {
            let oldTiles = tilesURL(for: id, revision: prevRev)
            try? FileManager.default.removeItem(at: oldTiles)
        }

        return record
    }

    func deleteMap(id: String) {
        let dir = mapDirectory(for: id)
        try? FileManager.default.removeItem(at: dir)
    }

    func deleteAllUserMaps() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
