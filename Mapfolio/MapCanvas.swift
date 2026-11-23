import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class MapLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    @Published private(set) var recenter = 0
    @Published var showSettings = false

    private let manager = CLLocationManager()
    private var locatingAfterPermission = false

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    var authorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            locatingAfterPermission = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            recenter += 1
        default:
            showSettings = true
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refreshAuthorization() }
    }

    private func refreshAuthorization() {
        status = manager.authorizationStatus
        if locatingAfterPermission && status != .notDetermined {
            locatingAfterPermission = false
            if authorized { recenter += 1 }
        }
    }
}

struct MapFocusRequest: Equatable {
    var nonce: Int = 0
    var bounds: MKMapRect = ShanghaiLayer.bounds

    static func == (lhs: MapFocusRequest, rhs: MapFocusRequest) -> Bool {
        lhs.nonce == rhs.nonce && MKMapRectEqualToRect(lhs.bounds, rhs.bounds)
    }
}

final class HistoryMapView: MKMapView {
    var defaultFocusBounds: MKMapRect = ShanghaiLayer.bounds
    private var hasInitialCamera = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !hasInitialCamera, bounds.width >= 100, bounds.height >= 100 else { return }
        hasInitialCamera = true
        focus(on: defaultFocusBounds, animated: false)
    }

    func focus(on mapRect: MKMapRect, animated: Bool) {
        setUserTrackingMode(.none, animated: false)
        let insets = safeAreaInsets
        let padding = UIEdgeInsets(
            top: max(20, insets.top + 12),
            left: max(20, insets.left + 16),
            bottom: max(24, insets.bottom + 16),
            right: max(20, insets.right + 16)
        )
        setVisibleMapRect(mapRect, edgePadding: padding, animated: animated)
    }
}

final class HistoryMapViewController: UIViewController, UIGestureRecognizerDelegate {
    let mapView = HistoryMapView()
    var onPeekPressChanged: ((Bool) -> Void)?
    var isPeekEnabled = true {
        didSet {
            guard isPeekEnabled != oldValue else { return }
            peekLongPressRecognizer.isEnabled = isPeekEnabled
            if !isPeekEnabled && isHoldingPeek {
                isHoldingPeek = false
                onPeekPressChanged?(false)
            }
        }
    }

    private var desiredSafeAreaInsets: UIEdgeInsets = .zero
    private var isHoldingPeek = false
    private lazy var peekLongPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handlePeekLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.25
        recognizer.allowableMovement = 12
        recognizer.numberOfTouchesRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        peekLongPressRecognizer.isEnabled = isPeekEnabled
        mapView.addGestureRecognizer(peekLongPressRecognizer)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isHoldingPeek {
            isHoldingPeek = false
            onPeekPressChanged?(false)
        }
    }

    @objc private func handlePeekLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isPeekEnabled, !isHoldingPeek else { return }
            isHoldingPeek = true
            onPeekPressChanged?(true)
        case .ended, .cancelled, .failed:
            guard isHoldingPeek else { return }
            isHoldingPeek = false
            onPeekPressChanged?(false)
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === peekLongPressRecognizer else { return true }
        guard isPeekEnabled else { return false }
        var candidate = touch.view
        while let current = candidate {
            if current is UIControl || current is UINavigationBar {
                return false
            }
            if current === mapView {
                break
            }
            candidate = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === peekLongPressRecognizer else { return false }
        if otherGestureRecognizer is UIPanGestureRecognizer
            || otherGestureRecognizer is UIPinchGestureRecognizer
            || otherGestureRecognizer is UITapGestureRecognizer
            || otherGestureRecognizer is UIRotationGestureRecognizer {
            return false
        }
        return true
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        recomputeAdditionalSafeAreaInsets()
    }

    func applyDesiredSafeAreaInsets(_ desired: UIEdgeInsets) {
        desiredSafeAreaInsets = desired
        recomputeAdditionalSafeAreaInsets()
    }

    private func recomputeAdditionalSafeAreaInsets() {
        let current = view.safeAreaInsets
        let existingAdditional = additionalSafeAreaInsets
        let inherited = UIEdgeInsets(
            top: max(0, current.top - existingAdditional.top),
            left: max(0, current.left - existingAdditional.left),
            bottom: max(0, current.bottom - existingAdditional.bottom),
            right: max(0, current.right - existingAdditional.right)
        )
        let needed = UIEdgeInsets(
            top: max(0, desiredSafeAreaInsets.top - inherited.top),
            left: max(0, desiredSafeAreaInsets.left - inherited.left),
            bottom: max(0, desiredSafeAreaInsets.bottom - inherited.bottom),
            right: max(0, desiredSafeAreaInsets.right - inherited.right)
        )
        if abs(needed.top - existingAdditional.top) > 0.5 ||
            abs(needed.left - existingAdditional.left) > 0.5 ||
            abs(needed.bottom - existingAdditional.bottom) > 0.5 ||
            abs(needed.right - existingAdditional.right) > 0.5 {
            additionalSafeAreaInsets = needed
        }
    }
}

struct MapCanvas: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let layers: [HistoricalMapLayerConfig]
    var hideOverlays: Bool = false
    var defaultBounds: MKMapRect = ShanghaiLayer.bounds
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var showLocation: Bool
    var recenter: Int
    var focusRequest: MapFocusRequest
    var isPeekEnabled: Bool = true
    var onPeekPressChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(initialFocusNonce: focusRequest.nonce)
    }

    private static let structuralPointOfInterestFilter: MKPointOfInterestFilter = {
        var categories: [MKPointOfInterestCategory] = [
            .publicTransport,
            .airport,
            .park,
            .nationalPark,
            .museum,
            .library,
            .theater,
            .university,
            .school,
            .hospital,
            .stadium,
            .zoo,
            .aquarium,
            .amusementPark
        ]
        if #available(iOS 18.0, *) {
            categories.append(contentsOf: [
                .landmark,
                .nationalMonument,
                .castle,
                .fortress,
                .conventionCenter
            ])
        }
        return MKPointOfInterestFilter(including: categories)
    }()

    func makeUIViewController(context: Context) -> HistoryMapViewController {
        let controller = HistoryMapViewController()
        let map = controller.mapView
        map.delegate = context.coordinator
        map.defaultFocusBounds = defaultBounds
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = Self.structuralPointOfInterestFilter
        map.preferredConfiguration = configuration
        map.pointOfInterestFilter = Self.structuralPointOfInterestFilter
        // Keep the historical and modern maps aligned north-up when comparing streets.
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        controller.isPeekEnabled = isPeekEnabled
        controller.onPeekPressChanged = onPeekPressChanged
        controller.applyDesiredSafeAreaInsets(uiEdgeInsets(from: safeAreaInsets))
        context.coordinator.syncOverlays(on: map, layers: layers, hideOverlays: hideOverlays)
        return controller
    }

    func updateUIViewController(_ controller: HistoryMapViewController, context: Context) {
        let coordinator = context.coordinator
        let map = controller.mapView
        map.defaultFocusBounds = defaultBounds
        controller.isPeekEnabled = isPeekEnabled
        controller.onPeekPressChanged = onPeekPressChanged
        controller.applyDesiredSafeAreaInsets(uiEdgeInsets(from: safeAreaInsets))
        coordinator.syncOverlays(on: map, layers: layers, hideOverlays: hideOverlays)

        if map.showsUserLocation != showLocation {
            map.showsUserLocation = showLocation
        }

        if coordinator.lastFocusNonce != focusRequest.nonce {
            coordinator.lastFocusNonce = focusRequest.nonce
            map.focus(on: focusRequest.bounds, animated: !reduceMotion)
        }

        if coordinator.recenter != recenter {
            coordinator.recenter = recenter
            map.setUserTrackingMode(.follow, animated: !reduceMotion)
        }
    }

    private func uiEdgeInsets(from insets: EdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: insets.top,
            left: insets.leading,
            bottom: insets.bottom,
            right: insets.trailing
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private struct ActiveOverlayEntry {
            let url: URL
            let overlay: ShanghaiTileOverlay
        }

        private var overlaysByID: [String: ActiveOverlayEntry] = [:]
        private var alphaByOverlay: [ObjectIdentifier: CGFloat] = [:]
        var recenter = 0
        var lastFocusNonce: Int

        init(initialFocusNonce: Int) {
            self.lastFocusNonce = initialFocusNonce
        }

        func syncOverlays(on map: MKMapView, layers: [HistoricalMapLayerConfig], hideOverlays: Bool) {
            let desiredByID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })

            for (id, entry) in overlaysByID {
                guard let target = desiredByID[id], target.archiveURL == entry.url else {
                    map.removeOverlay(entry.overlay)
                    alphaByOverlay.removeValue(forKey: ObjectIdentifier(entry.overlay))
                    overlaysByID.removeValue(forKey: id)
                    continue
                }
            }

            let orderedOverlays = layers.map { layer -> ShanghaiTileOverlay in
                let overlay: ShanghaiTileOverlay
                if let existing = overlaysByID[layer.id], existing.url == layer.archiveURL {
                    overlay = existing.overlay
                } else {
                    overlay = ShanghaiTileOverlay(archive: layer.archiveURL, bounds: layer.bounds)
                    overlaysByID[layer.id] = ActiveOverlayEntry(url: layer.archiveURL, overlay: overlay)
                }

                let targetAlpha = hideOverlays ? 0.0 : CGFloat(layer.opacity)
                alphaByOverlay[ObjectIdentifier(overlay)] = targetAlpha
                if let renderer = map.renderer(for: overlay), abs(renderer.alpha - targetAlpha) > 0.001 {
                    renderer.alpha = targetAlpha
                }
                return overlay
            }

            let installed = map.overlays.compactMap { $0 as? ShanghaiTileOverlay }
            if !orderedOverlays.starts(with: installed, by: { $0 === $1 }) {
                map.removeOverlays(installed)
                map.addOverlays(orderedOverlays, level: .aboveLabels)
            } else {
                map.addOverlays(Array(orderedOverlays.dropFirst(installed.count)), level: .aboveLabels)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
            renderer.alpha = alphaByOverlay[ObjectIdentifier(tiles)] ?? 1.0
            return renderer
        }
    }
}
