import Foundation
import MapKit

enum HistoricalLayerOpacity: String, Codable, CaseIterable, Identifiable {
    case translucent
    case opaque

    var id: String { rawValue }

    var alpha: Double {
        switch self {
        case .translucent: 0.5
        case .opaque: 1.0
        }
    }

    var title: String {
        switch self {
        case .translucent: "Translucent"
        case .opaque: "Opaque"
        }
    }

    func accessibilityIdentifier(for mapID: String) -> String {
        "archive.library.\(mapID).opacity.\(rawValue)"
    }

    var accessibilityHint: String {
        switch self {
        case .translucent:
            "Overlays this historical map at 50% opacity for comparison with the modern basemap"
        case .opaque:
            "Overlays this historical map at full opacity"
        }
    }
}

enum HistoricalLayerDisplayMode: String, CaseIterable, Identifiable {
    case hidden
    case translucent
    case opaque

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: "Hidden"
        case .translucent: "Translucent"
        case .opaque: "Opaque"
        }
    }

    func accessibilityIdentifier(for mapID: String) -> String {
        switch self {
        case .hidden:
            "archive.library.\(mapID).display.hidden"
        case .translucent:
            "archive.library.\(mapID).opacity.translucent"
        case .opaque:
            "archive.library.\(mapID).opacity.opaque"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .hidden:
            "Hides this historical map layer and shows only the modern basemap"
        case .translucent:
            "Enables this historical map at 50% opacity for comparison with the modern basemap"
        case .opaque:
            "Enables this historical map at full opacity"
        }
    }
}

struct HistoricalMapLayerState: Codable, Equatable {
    var isEnabled: Bool
    var opacity: HistoricalLayerOpacity

    var displayMode: HistoricalLayerDisplayMode {
        guard isEnabled else { return .hidden }
        switch opacity {
        case .translucent: return .translucent
        case .opaque: return .opaque
        }
    }
}

struct HistoricalMapLayerConfig: Equatable, Identifiable {
    let id: String
    let archiveURL: URL
    let bounds: MKMapRect
    let opacity: Double

    static func == (lhs: HistoricalMapLayerConfig, rhs: HistoricalMapLayerConfig) -> Bool {
        lhs.id == rhs.id &&
        lhs.archiveURL == rhs.archiveURL &&
        lhs.opacity == rhs.opacity &&
        MKMapRectEqualToRect(lhs.bounds, rhs.bounds)
    }
}

struct HistoricalMapArchive: Identifiable, Hashable {
    let id: String
    let title: String
    let yearLabel: String
    let yearNumber: String
    let displayTitle: String
    let layerTitle: String
    let regionLabel: String
    let sourceShort: String
    let sourceCompact: String
    let sourceAttribution: String
    let resourceName: String
    let resourceExtension: String
    let previewZoom: Int
    let previewDeskewDegrees: Double
    let bounds: MKMapRect
    let sourceURL: URL?
    let defaultState: HistoricalMapLayerState
    var fileURL: URL? = nil
    var previewImageURL: URL? = nil
    var isUserImported: Bool = false
    var controlPointCount: Int = 0

    var bundleURL: URL? {
        if let fileURL {
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
        guard !resourceName.isEmpty else { return nil }
        return Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    static func == (lhs: HistoricalMapArchive, rhs: HistoricalMapArchive) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayAttribution: String {
        guard isUserImported else { return sourceAttribution }
        return AppText.userMapAttribution(pinCount: controlPointCount)
    }

    var kickerText: String {
        if isUserImported {
            let tag = yearNumber == "USER" ? AppText.userMapDefaultTag : yearNumber
            return regionLabel.isEmpty ? tag : "\(tag) · \(regionLabel)"
        }
        return "\(yearNumber) · \(regionLabel)"
    }

    var gridYearTag: String {
        if isUserImported && yearNumber == "USER" {
            return AppText.userMapDefaultTag
        }
        return yearNumber
    }

    static let shanghai1946 = HistoricalMapArchive(
        id: "shanghai1946",
        title: "Detailed Street Map of Shanghai",
        yearLabel: "1946",
        yearNumber: "1946",
        displayTitle: "1946 Detailed Street Map of Shanghai",
        layerTitle: "1946 Shanghai Overlay",
        regionLabel: "Shanghai",
        sourceShort: "Virtual Shanghai · Stanford University Libraries",
        sourceCompact: "Virtual Shanghai · Public Domain",
        sourceAttribution: "Virtual Shanghai / Stanford Libraries",
        resourceName: "Shanghai1946",
        resourceExtension: "sqlite",
        previewZoom: 13,
        previewDeskewDegrees: -13.1,
        bounds: ShanghaiLayer.bounds,
        sourceURL: ShanghaiLayer.source,
        defaultState: HistoricalMapLayerState(isEnabled: true, opacity: .translucent)
    )

    static let beijing1930 = HistoricalMapArchive(
        id: "beijing1930",
        title: "Complete Detailed Map of Beiping",
        yearLabel: "1930",
        yearNumber: "1930",
        displayTitle: "1930 Complete Detailed Map of Beiping",
        layerTitle: "1930 Beiping Overlay",
        regionLabel: "Old Beijing",
        sourceShort: "Library of Congress · Wenya Press",
        sourceCompact: "Library of Congress",
        sourceAttribution: "Library of Congress / Allmaps",
        resourceName: "Beijing1930",
        resourceExtension: "sqlite",
        previewZoom: 13,
        previewDeskewDegrees: -1.0,
        bounds: mapRect(
            nw: CLLocationCoordinate2D(latitude: 39.966397, longitude: 116.339060),
            se: CLLocationCoordinate2D(latitude: 39.859636, longitude: 116.441542)
        ),
        sourceURL: URL(string: "https://www.loc.gov/item/2006458554/")!,
        defaultState: HistoricalMapLayerState(isEnabled: false, opacity: .translucent)
    )

    static let paris1811 = HistoricalMapArchive(
        id: "paris1811",
        title: "Plan of Paris & Its Twelve Arrondissements",
        yearLabel: "1811",
        yearNumber: "1811",
        displayTitle: "1811 Plan of Paris & Its Twelve Arrondissements",
        layerTitle: "1811 Paris Overlay",
        regionLabel: "Central Paris",
        sourceShort: "Leventhal Map & Education Center, BPL",
        sourceCompact: "Boston Public Library",
        sourceAttribution: "Boston Public Library / Allmaps",
        resourceName: "Paris1811",
        resourceExtension: "sqlite",
        previewZoom: 13,
        previewDeskewDegrees: 22.7,
        bounds: mapRect(
            nw: CLLocationCoordinate2D(latitude: 48.892621, longitude: 2.278080),
            se: CLLocationCoordinate2D(latitude: 48.819257, longitude: 2.409214)
        ),
        sourceURL: URL(string: "https://collections.leventhalmap.org/search/commonwealth:3f4631174")!,
        defaultState: HistoricalMapLayerState(isEnabled: false, opacity: .translucent)
    )

    static let london1765 = HistoricalMapArchive(
        id: "london1765",
        title: "Plan of the Cities of London & Westminster",
        yearLabel: "c. 1765",
        yearNumber: "1765",
        displayTitle: "1765 Plan of the Cities of London & Westminster",
        layerTitle: "1765 London Overlay",
        regionLabel: "Central London",
        sourceShort: "Leventhal Map & Education Center, BPL",
        sourceCompact: "Boston Public Library",
        sourceAttribution: "Boston Public Library / Allmaps",
        resourceName: "London1765",
        resourceExtension: "sqlite",
        previewZoom: 13,
        previewDeskewDegrees: -1.2,
        bounds: mapRect(
            nw: CLLocationCoordinate2D(latitude: 51.535030, longitude: -0.158607),
            se: CLLocationCoordinate2D(latitude: 51.488766, longitude: -0.026668)
        ),
        sourceURL: URL(string: "https://collections.leventhalmap.org/search/commonwealth:3f462x782")!,
        defaultState: HistoricalMapLayerState(isEnabled: false, opacity: .translucent)
    )

    static let catalog: [HistoricalMapArchive] = [.shanghai1946, .beijing1930, .paris1811, .london1765]

    private static func mapRect(nw: CLLocationCoordinate2D, se: CLLocationCoordinate2D) -> MKMapRect {
        let northwest = MKMapPoint(nw)
        let southeast = MKMapPoint(se)
        return MKMapRect(
            x: northwest.x,
            y: northwest.y,
            width: southeast.x - northwest.x,
            height: southeast.y - northwest.y
        )
    }
}

@MainActor
final class HistoricalMapLibraryStore: ObservableObject {
    static let storageKey = "cc.monism.antiquemaps.libraryStates.v1"
    static let selectedMapStorageKey = "cc.monism.antiquemaps.selectedMapID.v1"
    static let resetLaunchArgument = "-UITestingResetLibrary"
    static let emptyCatalogLaunchArgument = "-UITestingEmptyCatalog"

    @Published private(set) var catalog: [HistoricalMapArchive]
    @Published private(set) var selectedMapID: String?
    @Published private var statesByID: [String: HistoricalMapLayerState]

    private let defaults: UserDefaults
    private let userMapStorage: UserMapStorage

    init(
        catalog: [HistoricalMapArchive] = HistoricalMapArchive.catalog,
        defaults: UserDefaults = .standard,
        userMapStorage: UserMapStorage = .shared,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        self.userMapStorage = userMapStorage

        if arguments.contains(Self.resetLaunchArgument) {
            defaults.removeObject(forKey: Self.storageKey)
            defaults.removeObject(forKey: Self.selectedMapStorageKey)
            userMapStorage.deleteAllUserMaps()
        }

        let userArchives = arguments.contains(Self.emptyCatalogLaunchArgument)
            ? []
            : userMapStorage.loadAllRecords().map { userMapStorage.makeArchive(from: $0) }
        let resolvedCatalog = arguments.contains(Self.emptyCatalogLaunchArgument)
            ? []
            : catalog + userArchives
        self.catalog = resolvedCatalog

        let persisted = Self.loadStates(from: defaults)
        var resolved: [String: HistoricalMapLayerState] = [:]
        for map in resolvedCatalog {
            resolved[map.id] = persisted[map.id] ?? map.defaultState
        }
        self.statesByID = resolved

        let savedSelection = defaults.string(forKey: Self.selectedMapStorageKey)
        if let savedSelection, resolvedCatalog.contains(where: { $0.id == savedSelection }) {
            self.selectedMapID = savedSelection
        } else {
            self.selectedMapID = resolvedCatalog.first?.id
        }
    }

    func upsertUserMap(record: UserMapRecord) -> HistoricalMapArchive {
        let archive = userMapStorage.makeArchive(from: record)
        if let index = catalog.firstIndex(where: { $0.id == archive.id }) {
            MapSheetPreviewLoader.shared.invalidatePreview(for: catalog[index])
            catalog[index] = archive
            if statesByID[archive.id] == nil {
                statesByID[archive.id] = archive.defaultState
            }
        } else {
            catalog.append(archive)
            statesByID[archive.id] = archive.defaultState
        }
        selectedMapID = archive.id
        defaults.set(archive.id, forKey: Self.selectedMapStorageKey)
        persist()
        return archive
    }

    func deleteUserMap(id: String) {
        guard let index = catalog.firstIndex(where: { $0.id == id && $0.isUserImported }) else {
            return
        }
        MapSheetPreviewLoader.shared.invalidatePreview(for: catalog[index])
        userMapStorage.deleteMap(id: id)
        catalog.remove(at: index)
        statesByID.removeValue(forKey: id)
        if selectedMapID == id {
            let fallbackIndex = min(index, max(0, catalog.count - 1))
            selectedMapID = catalog.indices.contains(fallbackIndex) ? catalog[fallbackIndex].id : nil
            if let selectedMapID {
                defaults.set(selectedMapID, forKey: Self.selectedMapStorageKey)
            } else {
                defaults.removeObject(forKey: Self.selectedMapStorageKey)
            }
        }
        persist()
    }

    func loadUserRecord(id: String) -> UserMapRecord? {
        userMapStorage.loadRecord(id: id)
    }

    func loadUserSourceImage(id: String) -> UIImage? {
        userMapStorage.loadSourceImage(id: id)
    }

    func activeLayers(shanghaiProfile: ShanghaiDisplayProfile) -> [HistoricalMapLayerConfig] {
        catalog.compactMap { map in
            guard let state = statesByID[map.id],
                  state.isEnabled,
                  let archiveURL = map.bundleURL else {
                return nil
            }
            return HistoricalMapLayerConfig(
                id: map.id,
                archiveURL: shanghaiProfile.displayURL(for: archiveURL),
                bounds: shanghaiProfile.displayBounds(for: map.bounds, mapID: map.id),
                opacity: state.opacity.alpha
            )
        }
    }

    var defaultFocusBounds: MKMapRect {
        catalog.first?.bounds ?? ShanghaiLayer.bounds
    }

    var enabledCount: Int {
        catalog.reduce(into: 0) { count, map in
            if state(for: map).isEnabled && map.bundleURL != nil {
                count += 1
            }
        }
    }

    var hasEnabledOverlay: Bool {
        enabledCount > 0
    }

    var hasAnyAvailableMap: Bool {
        catalog.contains { $0.bundleURL != nil }
    }

    func state(for map: HistoricalMapArchive) -> HistoricalMapLayerState {
        statesByID[map.id] ?? map.defaultState
    }

    func setEnabled(_ isEnabled: Bool, for mapID: String) {
        guard var current = statesByID[mapID] ?? catalog.first(where: { $0.id == mapID })?.defaultState else {
            return
        }
        guard current.isEnabled != isEnabled else { return }
        current.isEnabled = isEnabled
        statesByID[mapID] = current
        persist()
    }

    func setOpacity(_ opacity: HistoricalLayerOpacity, for mapID: String) {
        guard var current = statesByID[mapID] ?? catalog.first(where: { $0.id == mapID })?.defaultState else {
            return
        }
        guard current.opacity != opacity else { return }
        current.opacity = opacity
        statesByID[mapID] = current
        persist()
    }

    func setDisplayMode(_ mode: HistoricalLayerDisplayMode, for mapID: String) {
        guard var current = statesByID[mapID] ?? catalog.first(where: { $0.id == mapID })?.defaultState else {
            return
        }
        let next: HistoricalMapLayerState
        switch mode {
        case .hidden:
            next = HistoricalMapLayerState(isEnabled: false, opacity: current.opacity)
        case .translucent:
            next = HistoricalMapLayerState(isEnabled: true, opacity: .translucent)
        case .opaque:
            next = HistoricalMapLayerState(isEnabled: true, opacity: .opaque)
        }
        guard current != next else { return }
        current = next
        statesByID[mapID] = current
        persist()
    }

    func enableAllAvailableMaps() {
        var changed = false
        for map in catalog where map.bundleURL != nil {
            var current = statesByID[map.id] ?? map.defaultState
            if !current.isEnabled {
                current.isEnabled = true
                statesByID[map.id] = current
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    func selectMap(_ mapID: String?) {
        guard let mapID,
              catalog.contains(where: { $0.id == mapID }),
              selectedMapID != mapID else {
            return
        }
        selectedMapID = mapID
        defaults.set(mapID, forKey: Self.selectedMapStorageKey)
    }

    func restoreCatalogDefaults() {
        if catalog.isEmpty {
            catalog = HistoricalMapArchive.catalog
        }
        var reset: [String: HistoricalMapLayerState] = [:]
        for map in catalog {
            reset[map.id] = map.defaultState
        }
        statesByID = reset
        if selectedMapID == nil || !catalog.contains(where: { $0.id == selectedMapID }) {
            selectedMapID = catalog.first?.id
            if let selectedMapID {
                defaults.set(selectedMapID, forKey: Self.selectedMapStorageKey)
            }
        }
        persist()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(statesByID) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
    }

    private static func loadStates(from defaults: UserDefaults) -> [String: HistoricalMapLayerState] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: HistoricalMapLayerState].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
