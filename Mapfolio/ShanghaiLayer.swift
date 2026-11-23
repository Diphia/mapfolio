import CoreGraphics
import Foundation
import ImageIO
import MapKit
import SQLite3
import UniformTypeIdentifiers

enum ShanghaiLayer {
    static let source = URL(string: "https://purl.stanford.edu/df634mk1844")!
    static let bounds: MKMapRect = {
        let northwest = MKMapPoint(CLLocationCoordinate2D(latitude: 31.2965, longitude: 121.3882))
        let southeast = MKMapPoint(CLLocationCoordinate2D(latitude: 31.1850, longitude: 121.5514))
        return MKMapRect(x: northwest.x, y: northwest.y,
                         width: southeast.x - northwest.x, height: southeast.y - northwest.y)
    }()
}

// The archive's XYZ grid is pre-rendered. For Shanghai, the mainland
// presentation uses its own display-calibrated tiles; the source is unchanged.
final class ShanghaiTileOverlay: MKTileOverlay {
    private static let defaultMaxStoredZoom = 17
    private static let defaultMinimumZoom = 10
    private let archive: URL
    private let coverage: MKMapRect
    private let minStoredZoom: Int
    private let maxStoredZoom: Int
    private let queue = DispatchQueue(label: "historical-maps.tiles", qos: .userInitiated)
    // SQLite connection and prepared statement are used only on queue.
    private var database: OpaquePointer?
    private var statement: OpaquePointer?

    init(archive: URL, bounds: MKMapRect = ShanghaiLayer.bounds) {
        self.archive = archive
        self.coverage = bounds
        let range = Self.storedZoomRange(in: archive)
        self.minStoredZoom = range.lowerBound
        self.maxStoredZoom = range.upperBound
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = minStoredZoom
        maximumZ = max(21, maxStoredZoom + 4)
        canReplaceMapContent = false
        isGeometryFlipped = false
    }

    override var boundingMapRect: MKMapRect { coverage }
    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, (any Error)?) -> Void) {
        queue.async {
            guard (self.minStoredZoom...self.maximumZ).contains(path.z),
                  path.x >= 0, path.y >= 0 else {
                result(nil, nil)
                return
            }
            let extra = max(0, path.z - self.maxStoredZoom)
            let data = self.tile(z: path.z - extra, x: path.x >> extra, y: path.y >> extra)
            result(extra == 0 ? data : data.flatMap {
                Self.overzoom($0, x: path.x, y: path.y, steps: extra)
            }, nil)
        }
    }

    private static func storedZoomRange(in archive: URL) -> ClosedRange<Int> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(archive.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return defaultMinimumZoom...defaultMaxStoredZoom
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(z), MAX(z) FROM tiles", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return defaultMinimumZoom...defaultMaxStoredZoom
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
            return defaultMinimumZoom...defaultMaxStoredZoom
        }
        let minZ = max(0, Int(sqlite3_column_int(stmt, 0)))
        let maxZ = max(minZ, Int(sqlite3_column_int(stmt, 1)))
        return minZ...maxZ
    }

    deinit {
        // Pending work holds self until its last SQLite operation has completed.
        if let statement { sqlite3_finalize(statement) }
        if let database { sqlite3_close(database) }
    }

    private func tile(z: Int, x: Int, y: Int) -> Data? {
        if statement == nil {
            var db: OpaquePointer?
            guard sqlite3_open_v2(archive.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                return nil
            }
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM tiles WHERE z=? AND x=? AND y=?",
                                     -1, &query, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            database = db
            statement = query
        }
        guard let statement else { return nil }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        sqlite3_bind_int(statement, 1, Int32(z))
        sqlite3_bind_int(statement, 2, Int32(x))
        sqlite3_bind_int(statement, 3, Int32(y))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private static func overzoom(_ data: Data, x: Int, y: Int, steps: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let factor = 1 << steps
        let w = image.width / factor
        let h = image.height / factor
        let rect = CGRect(x: (x % factor) * w, y: (y % factor) * h, width: w, height: h)
        guard let part = image.cropping(to: rect),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        let buffer = NSMutableData()
        guard let output = context.makeImage(),
              let encoder = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(encoder, output, nil)
        return CGImageDestinationFinalize(encoder) ? buffer as Data : nil
    }
}
