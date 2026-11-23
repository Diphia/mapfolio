import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MapKit
import UIKit

struct CalibrationControlPoint: Identifiable, Codable, Equatable {
    let id: UUID
    /// Pixel coordinate in upright image space (origin top-left, x right, y down).
    var imageX: Double
    var imageY: Double
    /// Target coordinate in MKMapPoint space (origin top-left NW, x east, y south).
    var mapX: Double
    var mapY: Double

    init(
        id: UUID = UUID(),
        imageX: Double,
        imageY: Double,
        mapX: Double,
        mapY: Double
    ) {
        self.id = id
        self.imageX = imageX
        self.imageY = imageY
        self.mapX = mapX
        self.mapY = mapY
    }

    var imagePoint: CGPoint {
        CGPoint(x: imageX, y: imageY)
    }

    var mapPoint: MKMapPoint {
        MKMapPoint(x: mapX, y: mapY)
    }

    var coordinate: CLLocationCoordinate2D {
        mapPoint.coordinate
    }
}

struct RoughMapPlacement: Codable, Equatable {
    /// Geographic center of the image in MKMapPoint space.
    var centerX: Double
    var centerY: Double
    /// Scale factor: MKMapPoint units per image pixel (> 0).
    var mapPointsPerPixel: Double
    /// Clockwise rotation in radians (0 = image top points north).
    var rotationRadians: Double

    var centerMapPoint: MKMapPoint {
        get { MKMapPoint(x: centerX, y: centerY) }
        set {
            centerX = newValue.x
            centerY = newValue.y
        }
    }

    static func initial(
        imageSize: CGSize,
        around center: MKMapPoint,
        visibleMapWidth: Double
    ) -> RoughMapPlacement {
        let safeImageWidth = max(1.0, Double(imageSize.width))
        let targetWidth = max(1_000.0, visibleMapWidth * 0.68)
        return RoughMapPlacement(
            centerX: center.x,
            centerY: center.y,
            mapPointsPerPixel: targetWidth / safeImageWidth,
            rotationRadians: 0
        )
    }

    func affineTransform(imageSize: CGSize) -> MapAffineTransform {
        let halfW = Double(imageSize.width) * 0.5
        let halfH = Double(imageSize.height) * 0.5
        let cosR = cos(rotationRadians)
        let sinR = sin(rotationRadians)
        let a = mapPointsPerPixel * cosR
        let b = -mapPointsPerPixel * sinR
        let c = mapPointsPerPixel * sinR
        let d = mapPointsPerPixel * cosR
        let tx = centerX - a * halfW - b * halfH
        let ty = centerY - c * halfW - d * halfH
        return MapAffineTransform(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }
}

/// First-order 2D affine transform mapping upright image pixel `(px, py)` -> `MKMapPoint(mx, my)`:
///   mx = a * px + b * py + tx
///   my = c * px + d * py + ty
struct MapAffineTransform: Codable, Equatable {
    var a: Double
    var b: Double
    var tx: Double
    var c: Double
    var d: Double
    var ty: Double

    var determinant: Double {
        a * d - b * c
    }

    var isValid: Bool {
        determinant.isFinite && abs(determinant) > 1e-12
    }

    func apply(imageX px: Double, imageY py: Double) -> MKMapPoint {
        MKMapPoint(
            x: a * px + b * py + tx,
            y: c * px + d * py + ty
        )
    }

    func apply(_ point: CGPoint) -> MKMapPoint {
        apply(imageX: Double(point.x), imageY: Double(point.y))
    }

    func inverse(_ mapPoint: MKMapPoint) -> CGPoint? {
        let det = determinant
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        let dx = mapPoint.x - tx
        let dy = mapPoint.y - ty
        let px = (d * dx - b * dy) / det
        let py = (-c * dx + a * dy) / det
        guard px.isFinite, py.isFinite else { return nil }
        return CGPoint(x: px, y: py)
    }

    func contains(mapPoint: MKMapPoint, imageSize: CGSize, marginPixels: Double = 0) -> Bool {
        guard let px = inverse(mapPoint) else { return false }
        return Double(px.x) >= -marginPixels
            && Double(px.x) <= Double(imageSize.width) + marginPixels
            && Double(px.y) >= -marginPixels
            && Double(px.y) <= Double(imageSize.height) + marginPixels
    }

    func corners(imageSize: CGSize) -> [MKMapPoint] {
        let w = Double(imageSize.width)
        let h = Double(imageSize.height)
        return [
            apply(imageX: 0, imageY: 0),
            apply(imageX: w, imageY: 0),
            apply(imageX: w, imageY: h),
            apply(imageX: 0, imageY: h)
        ]
    }

    func boundingMapRect(imageSize: CGSize) -> MKMapRect {
        let pts = corners(imageSize: imageSize)
        let minX = pts.map(\.x).min() ?? 0
        let maxX = pts.map(\.x).max() ?? 0
        let minY = pts.map(\.y).min() ?? 0
        let maxY = pts.map(\.y).max() ?? 0
        let world = MKMapRect.world
        let clampedMinX = max(world.minX, min(world.maxX, minX))
        let clampedMaxX = max(clampedMinX + 1, min(world.maxX, maxX))
        let clampedMinY = max(world.minY, min(world.maxY, minY))
        let clampedMaxY = max(clampedMinY + 1, min(world.maxY, maxY))
        return MKMapRect(
            x: clampedMinX,
            y: clampedMinY,
            width: clampedMaxX - clampedMinX,
            height: clampedMaxY - clampedMinY
        )
    }

    /// Average MKMapPoint units per image pixel (geometric mean of X/Y scales).
    var averageMapPointsPerPixel: Double {
        let sx = hypot(a, c)
        let sy = hypot(b, d)
        return max(1e-9, sqrt(sx * sy))
    }

    /// Approximate clockwise rotation in degrees (for gallery deskew metadata).
    var rotationDegrees: Double {
        atan2(c, a) * 180.0 / .pi
    }

    /// Convert to a CoreGraphics CGAffineTransform mapping image pixel (px, py)
    /// into a top-down destination space shifted by `(originX, originY)` and scaled by `scale`.
    /// That is: destX = (mx - originX) * scale, destY = (my - originY) * scale.
    func cgTransform(originX: Double, originY: Double, scale: Double) -> CGAffineTransform {
        // CGAffineTransform applies:
        //   x' = a_cg * x + c_cg * y + tx_cg
        //   y' = b_cg * x + d_cg * y + ty_cg
        CGAffineTransform(
            a: a * scale,
            b: c * scale,
            c: b * scale,
            d: d * scale,
            tx: (tx - originX) * scale,
            ty: (ty - originY) * scale
        )
    }
}

enum CalibrationFitMode: String, Codable, Equatable {
    case rough
    case translation
    case similarity
    case affine
}

struct CalibrationPinResidual: Equatable {
    let pinID: UUID
    let errorMeters: Double
}

struct CalibrationFitResult: Equatable {
    let transform: MapAffineTransform
    let mode: CalibrationFitMode
    let residuals: [CalibrationPinResidual]
    let meanErrorMeters: Double

    func residualMeters(for pinID: UUID) -> Double? {
        residuals.first(where: { $0.pinID == pinID })?.errorMeters
    }
}

enum MapCalibrationSolver {
    static func solve(
        imageSize: CGSize,
        rough: RoughMapPlacement,
        controlPoints: [CalibrationControlPoint]
    ) -> CalibrationFitResult {
        let base = rough.affineTransform(imageSize: imageSize)

        switch controlPoints.count {
        case 0:
            return CalibrationFitResult(
                transform: base,
                mode: .rough,
                residuals: [],
                meanErrorMeters: 0
            )
        case 1:
            let p = controlPoints[0]
            let predicted = base.apply(imageX: p.imageX, imageY: p.imageY)
            let shifted = MapAffineTransform(
                a: base.a,
                b: base.b,
                tx: base.tx + (p.mapX - predicted.x),
                c: base.c,
                d: base.d,
                ty: base.ty + (p.mapY - predicted.y)
            )
            return evaluate(transform: shifted, mode: .translation, controlPoints: controlPoints)
        case 2:
            if let sim = fitSimilarity(controlPoints: controlPoints) {
                return evaluate(transform: sim, mode: .similarity, controlPoints: controlPoints)
            }
            return solve(imageSize: imageSize, rough: rough, controlPoints: [controlPoints[0]])
        default:
            if let aff = fitAffine(controlPoints: controlPoints) {
                return evaluate(transform: aff, mode: .affine, controlPoints: controlPoints)
            }
            if let sim = fitSimilarity(controlPoints: controlPoints) {
                return evaluate(transform: sim, mode: .similarity, controlPoints: controlPoints)
            }
            return solve(imageSize: imageSize, rough: rough, controlPoints: [controlPoints[0]])
        }
    }

    /// Closed-form least-squares 4-DOF similarity transform (no reflection).
    static func fitSimilarity(controlPoints: [CalibrationControlPoint]) -> MapAffineTransform? {
        let n = Double(controlPoints.count)
        guard controlPoints.count >= 2 else { return nil }

        let pxMean = controlPoints.reduce(0.0) { $0 + $1.imageX } / n
        let pyMean = controlPoints.reduce(0.0) { $0 + $1.imageY } / n
        let mxMean = controlPoints.reduce(0.0) { $0 + $1.mapX } / n
        let myMean = controlPoints.reduce(0.0) { $0 + $1.mapY } / n

        var denom = 0.0
        var numA = 0.0
        var numC = 0.0

        for p in controlPoints {
            let u = p.imageX - pxMean
            let v = p.imageY - pyMean
            let x = p.mapX - mxMean
            let y = p.mapY - myMean
            denom += u * u + v * v
            numA += x * u + y * v
            numC += y * u - x * v
        }

        guard denom > 1e-6 else { return nil }
        let a = numA / denom
        let c = numC / denom
        let scaleSq = a * a + c * c
        guard scaleSq.isFinite, scaleSq > 1e-12 else { return nil }

        let b = -c
        let d = a
        let tx = mxMean - a * pxMean - b * pyMean
        let ty = myMean - c * pxMean - d * pyMean
        let candidate = MapAffineTransform(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
        return candidate.isValid ? candidate : nil
    }

    /// Closed-form centered least-squares 6-DOF affine transform.
    /// Rejects collinear or mirror-flipped configurations.
    static func fitAffine(controlPoints: [CalibrationControlPoint]) -> MapAffineTransform? {
        let n = Double(controlPoints.count)
        guard controlPoints.count >= 3 else { return nil }

        let pxMean = controlPoints.reduce(0.0) { $0 + $1.imageX } / n
        let pyMean = controlPoints.reduce(0.0) { $0 + $1.imageY } / n
        let mxMean = controlPoints.reduce(0.0) { $0 + $1.mapX } / n
        let myMean = controlPoints.reduce(0.0) { $0 + $1.mapY } / n

        var suu = 0.0
        var suv = 0.0
        var svv = 0.0
        var sux = 0.0
        var svx = 0.0
        var suy = 0.0
        var svy = 0.0

        for p in controlPoints {
            let u = p.imageX - pxMean
            let v = p.imageY - pyMean
            let x = p.mapX - mxMean
            let y = p.mapY - myMean
            suu += u * u
            suv += u * v
            svv += v * v
            sux += u * x
            svx += v * x
            suy += u * y
            svy += v * y
        }

        let det = suu * svv - suv * suv
        let trace = suu + svv
        guard trace > 1e-6, det > 1e-5 * trace * trace else {
            return nil
        }

        let a = (svv * sux - suv * svx) / det
        let b = (-suv * sux + suu * svx) / det
        let c = (svv * suy - suv * svy) / det
        let d = (-suv * suy + suu * svy) / det

        // Guard against mirror-flipped or wildly sheared fits.
        let affineDet = a * d - b * c
        let scaleX = hypot(a, c)
        let scaleY = hypot(b, d)
        guard affineDet.isFinite, affineDet > 0, scaleX > 1e-6, scaleY > 1e-6 else {
            return nil
        }
        let anisotropy = max(scaleX / scaleY, scaleY / scaleX)
        let orthogonality = affineDet / (scaleX * scaleY)
        guard anisotropy < 4.0, orthogonality > 0.35 else {
            return nil
        }

        let tx = mxMean - a * pxMean - b * pyMean
        let ty = myMean - c * pxMean - d * pyMean
        let candidate = MapAffineTransform(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
        return candidate.isValid ? candidate : nil
    }

    private static func evaluate(
        transform: MapAffineTransform,
        mode: CalibrationFitMode,
        controlPoints: [CalibrationControlPoint]
    ) -> CalibrationFitResult {
        let residuals = controlPoints.map { point -> CalibrationPinResidual in
            let predicted = transform.apply(imageX: point.imageX, imageY: point.imageY)
            let meters = predicted.distance(to: point.mapPoint)
            return CalibrationPinResidual(pinID: point.id, errorMeters: meters)
        }
        let mean = residuals.isEmpty
            ? 0
            : residuals.reduce(0.0) { $0 + $1.errorMeters } / Double(residuals.count)
        return CalibrationFitResult(
            transform: transform,
            mode: mode,
            residuals: residuals,
            meanErrorMeters: mean
        )
    }
}

enum ImportedMapImageUtilities {
    /// Maximum working/stored long-edge dimension in pixels so memory and tile baking remain snappy.
    static let maxStoredDimension: CGFloat = 4096

    /// Extract optional EXIF GPS coordinates from raw image bytes.
    static func extractGPSCoordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"
        let signedLat = latRef == "S" ? -abs(lat) : abs(lat)
        let signedLon = lonRef == "W" ? -abs(lon) : abs(lon)
        let coord = CLLocationCoordinate2D(latitude: signedLat, longitude: signedLon)
        return CLLocationCoordinate2DIsValid(coord) ? coord : nil
    }

    /// Decode raw image bytes into a normalized upright `.up` UIImage, capped to `maxDimension`.
    static func normalizedUprightImage(from data: Data, maxDimension: CGFloat = maxStoredDimension) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }
        guard let fallback = UIImage(data: data) else { return nil }
        return redrawUpright(fallback, maxDimension: maxDimension)
    }

    static func redrawUpright(_ image: UIImage, maxDimension: CGFloat = maxStoredDimension) -> UIImage {
        let origSize = image.size
        guard origSize.width > 0, origSize.height > 0 else { return image }
        let longEdge = max(origSize.width, origSize.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1.0
        let targetSize = CGSize(
            width: max(1, (origSize.width * scale).rounded()),
            height: max(1, (origSize.height * scale).rounded())
        )
        if image.imageOrientation == .up, scale == 1.0, let cg = image.cgImage, image.scale == 1.0 {
            return UIImage(cgImage: cg, scale: 1.0, orientation: .up)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Rotate an upright UIImage by 90 degrees clockwise.
    static func rotatedClockwise90(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.height
        let height = cgImage.width
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        // In CGContext (bottom-up), a 90° clockwise visual rotation is -pi/2 around origin shifted to (0, height).
        context.translateBy(x: 0, y: CGFloat(height))
        context.rotate(by: -.pi / 2)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let rotated = context.makeImage() else { return image }
        return UIImage(cgImage: rotated, scale: 1.0, orientation: .up)
    }

    /// Generate a crisp synthetic vintage-style map image for UI testing without relying on system photo library.
    static func makeSampleTestMapImage() -> UIImage {
        let size = CGSize(width: 960, height: 720)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Warm parchment paper tone
            UIColor(red: 0.91, green: 0.85, blue: 0.72, alpha: 1.0).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Outer cartographic double frame
            UIColor(red: 0.30, green: 0.24, blue: 0.16, alpha: 0.85).setStroke()
            cg.setLineWidth(6)
            cg.stroke(CGRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48))
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: 34, y: 34, width: size.width - 68, height: size.height - 68))

            // Stylized river
            UIColor(red: 0.56, green: 0.70, blue: 0.76, alpha: 0.85).setStroke()
            cg.setLineWidth(38)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 70, y: 470))
            cg.addCurve(
                to: CGPoint(x: 890, y: 260),
                control1: CGPoint(x: 320, y: 440),
                control2: CGPoint(x: 560, y: 200)
            )
            cg.strokePath()

            // Street grid
            UIColor(red: 0.38, green: 0.31, blue: 0.22, alpha: 0.65).setStroke()
            cg.setLineWidth(3)
            for x in stride(from: 120, through: 840, by: 90) {
                cg.move(to: CGPoint(x: CGFloat(x), y: 70))
                cg.addLine(to: CGPoint(x: CGFloat(x), y: 650))
            }
            for y in stride(from: 120, through: 600, by: 80) {
                cg.move(to: CGPoint(x: 70, y: CGFloat(y)))
                cg.addLine(to: CGPoint(x: 890, y: CGFloat(y)))
            }
            cg.strokePath()

            // Three clear landmark rings
            let landmarks = [
                CGPoint(x: 300, y: 280),
                CGPoint(x: 660, y: 280),
                CGPoint(x: 480, y: 520)
            ]
            UIColor(red: 0.68, green: 0.24, blue: 0.18, alpha: 0.9).setStroke()
            cg.setLineWidth(4)
            for pt in landmarks {
                cg.strokeEllipse(in: CGRect(x: pt.x - 16, y: pt.y - 16, width: 32, height: 32))
            }
        }
    }
}
