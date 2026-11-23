import MapKit
import QuartzCore
import UIKit

/// GPU-composited live preview layer that keeps an affine-georeferenced image
/// pixel-locked to a flat, north-up MKMapView at 60/120fps without CATiledLayer flicker.
final class CalibrationOverlayLayerView: UIView {
    private let imageLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let guideLineLayer = CAShapeLayer()
    private let lockedMarkerLayer = CAShapeLayer()

    private var imageSize: CGSize = .zero
    private var lastCGImage: CGImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = MonolithPalette.uiInk.withAlphaComponent(0.82).cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        layer.addSublayer(borderLayer)

        guideLineLayer.fillColor = UIColor.clear.cgColor
        guideLineLayer.strokeColor = MonolithPalette.uiInk.withAlphaComponent(0.92).cgColor
        guideLineLayer.lineWidth = 1.8
        guideLineLayer.lineDashPattern = [5, 5]
        guideLineLayer.shadowColor = UIColor.black.cgColor
        guideLineLayer.shadowOpacity = 0.75
        guideLineLayer.shadowRadius = 3
        guideLineLayer.shadowOffset = .zero
        layer.addSublayer(guideLineLayer)

        lockedMarkerLayer.fillColor = MonolithPalette.uiInk.cgColor
        lockedMarkerLayer.strokeColor = MonolithPalette.uiCanvas.withAlphaComponent(0.95).cgColor
        lockedMarkerLayer.lineWidth = 1.8
        lockedMarkerLayer.shadowColor = UIColor.black.cgColor
        lockedMarkerLayer.shadowOpacity = 0.65
        lockedMarkerLayer.shadowRadius = 4
        lockedMarkerLayer.shadowOffset = .zero
        layer.addSublayer(lockedMarkerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        if lastCGImage === cg { return }
        lastCGImage = cg
        imageSize = CGSize(width: cg.width, height: cg.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cg
        imageLayer.bounds = CGRect(origin: .zero, size: imageSize)
        CATransaction.commit()
    }

    func update(
        on mapView: MKMapView,
        transform: MapAffineTransform,
        opacity: Float,
        showBorder: Bool,
        isInteracting: Bool = false,
        pendingSourceMapPoint: MKMapPoint?,
        animated: Bool
    ) {
        guard bounds.width > 1, bounds.height > 1,
              imageSize.width > 0, imageSize.height > 0,
              let projection = Self.screenProjection(for: mapView) else {
            return
        }

        let screenTransform = CGAffineTransform(
            a: transform.a * projection.scaleX,
            b: transform.c * projection.scaleY,
            c: transform.b * projection.scaleX,
            d: transform.d * projection.scaleY,
            tx: (transform.tx - projection.originX) * projection.scaleX,
            ty: (transform.ty - projection.originY) * projection.scaleY
        )

        let corners = transform.corners(imageSize: imageSize).map { projection.screenPoint(for: $0) }
        let borderPath = UIBezierPath()
        if let first = corners.first {
            borderPath.move(to: first)
            for pt in corners.dropFirst() {
                borderPath.addLine(to: pt)
            }
            borderPath.close()
        }

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        imageLayer.setAffineTransform(screenTransform)
        imageLayer.opacity = opacity

        borderLayer.path = borderPath.cgPath
        borderLayer.lineWidth = isInteracting ? 2.0 : 1.4
        borderLayer.lineDashPattern = isInteracting ? nil : [6, 4]
        borderLayer.strokeColor = isInteracting
            ? MonolithPalette.uiInk.cgColor
            : MonolithPalette.uiInk.withAlphaComponent(0.75).cgColor
        borderLayer.isHidden = !showBorder || opacity < 0.01

        if let pending = pendingSourceMapPoint {
            let startPt = projection.screenPoint(for: pending)
            let centerPt = CGPoint(x: bounds.midX, y: bounds.midY)
            let line = UIBezierPath()
            line.move(to: startPt)
            line.addLine(to: centerPt)
            guideLineLayer.path = line.cgPath
            guideLineLayer.isHidden = false

            let dotRect = CGRect(x: startPt.x - 5.5, y: startPt.y - 5.5, width: 11, height: 11)
            lockedMarkerLayer.path = UIBezierPath(rect: dotRect).cgPath
            lockedMarkerLayer.isHidden = false
        } else {
            guideLineLayer.isHidden = true
            lockedMarkerLayer.isHidden = true
        }

        CATransaction.commit()
    }

    struct ScreenProjection {
        let originX: Double
        let originY: Double
        let scaleX: Double
        let scaleY: Double

        func screenPoint(for mapPoint: MKMapPoint) -> CGPoint {
            CGPoint(
                x: (mapPoint.x - originX) * scaleX,
                y: (mapPoint.y - originY) * scaleY
            )
        }

        func mapPoint(for screenPoint: CGPoint) -> MKMapPoint {
            MKMapPoint(
                x: originX + Double(screenPoint.x) / scaleX,
                y: originY + Double(screenPoint.y) / scaleY
            )
        }

        var mapPointsPerScreenPoint: Double {
            1.0 / max(1e-9, scaleX)
        }
    }

    static func screenProjection(for mapView: MKMapView) -> ScreenProjection? {
        let width = Double(mapView.bounds.width)
        let height = Double(mapView.bounds.height)
        guard width > 1, height > 1 else { return nil }

        let topLeftCoord = mapView.convert(CGPoint(x: 0, y: 0), toCoordinateFrom: mapView)
        let bottomRightCoord = mapView.convert(CGPoint(x: width, y: height), toCoordinateFrom: mapView)
        let m0 = MKMapPoint(topLeftCoord)
        let m1 = MKMapPoint(bottomRightCoord)

        var spanX = m1.x - m0.x
        if spanX <= 0 {
            spanX += MKMapRect.world.width
        }
        let spanY = m1.y - m0.y
        guard spanX > 1e-3, spanY > 1e-3 else { return nil }

        return ScreenProjection(
            originX: m0.x,
            originY: m0.y,
            scaleX: width / spanX,
            scaleY: height / spanY
        )
    }
}
