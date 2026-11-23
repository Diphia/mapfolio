import Foundation
import MapKit

/// A display choice for this one historical sheet, not a general coordinate conversion.
enum ShanghaiDisplayProfile: String {
    case source
    case mainland

    // OpenStreetMap WGS-84 checks and measured MapKit results when the underlying
    // map credited Amap. These are fixed public landmarks, never the user's location.
    struct Landmark {
        let query: String
        let source: CLLocationCoordinate2D
        let mainland: CLLocationCoordinate2D
    }

    static let landmarks = [
        Landmark(query: "Waibaidu Bridge",
                 source: .init(latitude: 31.245463, longitude: 121.485806),
                 mainland: .init(latitude: 31.242896, longitude: 121.490060)),
        Landmark(query: "Shanghai Customs House",
                 source: .init(latitude: 31.238618, longitude: 121.485434),
                 mainland: .init(latitude: 31.236591, longitude: 121.489936)),
        Landmark(query: "Shanghai History Museum",
                 source: .init(latitude: 31.232788, longitude: 121.466593),
                 mainland: .init(latitude: 31.230594, longitude: 121.470891))
    ]

    static func classify(_ coordinate: CLLocationCoordinate2D, for landmark: Landmark) -> Self? {
        let point = MKMapPoint(coordinate)
        let sourceDistance = point.distance(to: MKMapPoint(landmark.source))
        let mainlandDistance = point.distance(to: MKMapPoint(landmark.mainland))
        if sourceDistance < 150 && mainlandDistance - sourceDistance > 200 { return .source }
        if mainlandDistance < 150 && sourceDistance - mainlandDistance > 200 { return .mainland }
        return nil
    }

    func displayBounds(for original: MKMapRect, mapID: String, bundle: Bundle = .main) -> MKMapRect {
        guard self == .mainland else { return original }
        // Keep these projected metres synchronized with scripts/build_tiles.py and scripts/allmaps_specs.json.
        let pointsPerProjectedMetre = MKMapRect.world.width / (2 * Double.pi * 6_378_137)
        switch mapID {
        case "shanghai1946":
            guard bundle.url(forResource: "Shanghai1946Mainland", withExtension: "sqlite") != nil else {
                return original
            }
            return original.offsetBy(dx: 485 * pointsPerProjectedMetre,
                                     dy: 300 * pointsPerProjectedMetre)
        case "beijing1930":
            guard bundle.url(forResource: "Beijing1930Mainland", withExtension: "sqlite") != nil else {
                return original
            }
            return original.offsetBy(dx: 695 * pointsPerProjectedMetre,
                                     dy: -204 * pointsPerProjectedMetre)
        default:
            return original
        }
    }

    func displayURL(for sourceURL: URL, bundle: Bundle = .main) -> URL {
        guard self == .mainland else { return sourceURL }
        switch sourceURL.lastPathComponent {
        case "Shanghai1946.sqlite":
            return bundle.url(forResource: "Shanghai1946Mainland", withExtension: "sqlite") ?? sourceURL
        case "Beijing1930.sqlite":
            return bundle.url(forResource: "Beijing1930Mainland", withExtension: "sqlite") ?? sourceURL
        default:
            return sourceURL
        }
    }
}

/// MapKit exposes no basemap-coordinate-system flag. Select a local presentation
/// from a majority of independent MapKit POI results. Keep the last confirmed
/// choice offline; first run without usable results keeps the source coordinates.
@MainActor
final class ShanghaiDisplayAlignment: ObservableObject {
    private static let cacheKey = "historicalMaps.shanghai.displayProfile"
    @Published private(set) var profile: ShanghaiDisplayProfile
    private var didResolve = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = defaults.string(forKey: Self.cacheKey).flatMap(ShanghaiDisplayProfile.init(rawValue:)) ?? .source
    }

    func resolve() async {
        guard !didResolve, !Task.isCancelled else { return }
        didResolve = true
        defer { if Task.isCancelled { didResolve = false } }

        var votes: [ShanghaiDisplayProfile: Int] = [:]
        for landmark in ShanghaiDisplayProfile.landmarks {
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = landmark.query
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: landmark.source, latitudinalMeters: 4_000, longitudinalMeters: 4_000
            )
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled, let first = response.mapItems.first else { continue }
            let coordinate: CLLocationCoordinate2D
            if #available(iOS 26.0, macOS 26.0, *) {
                coordinate = first.location.coordinate
            } else {
                coordinate = first.placemark.coordinate
            }
            guard let vote = ShanghaiDisplayProfile.classify(coordinate, for: landmark) else { continue }
            votes[vote, default: 0] += 1
            if votes[vote] == 2 {
                defaults.set(vote.rawValue, forKey: Self.cacheKey)
                profile = vote
                break
            }
        }
    }
}
