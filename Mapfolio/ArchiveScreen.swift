import MapKit
import SwiftUI
import UIKit

private enum ArchiveTheme {
    static let primaryInk = dynamicColor(
        light: UIColor(white: 0.0, alpha: 0.92),
        dark: UIColor(white: 1.0, alpha: 0.94)
    )

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

private struct SafeAreaInsetsKey: PreferenceKey {
    static let defaultValue = EdgeInsets()

    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) {
        value = nextValue()
    }
}

private extension View {
    @ViewBuilder
    func hiddenMapNavigationBarBackground() -> some View {
        if #available(iOS 18.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        } else {
            toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private extension ToolbarContent {
    @MainActor
    @ToolbarContentBuilder
    func duoHighPriority() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            visibilityPriority(.high)
                .axisBehavior(.verticalPreferred)
        } else if #available(iOS 27.0, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

struct ArchiveScreen: View {
    @StateObject private var location = MapLocation()
    @StateObject private var libraryStore = HistoricalMapLibraryStore()
    @StateObject private var shanghaiAlignment = ShanghaiDisplayAlignment()
    @State private var focusRequest = MapFocusRequest()
    @State private var safeAreaInsets = EdgeInsets()
    @State private var isLibraryPresented = false
    @State private var isPeekingModernMap = false
    @State private var uiTestPeekTriggerCount = 0

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let observePeekForUITests = ProcessInfo.processInfo.arguments.contains("-UITestingObservePeek")

    var body: some View {
        NavigationStack {
            ZStack {
                MapCanvas(
                    layers: libraryStore.activeLayers(shanghaiProfile: shanghaiAlignment.profile),
                    hideOverlays: isPeekingModernMap,
                    defaultBounds: libraryStore.defaultFocusBounds,
                    safeAreaInsets: safeAreaInsets,
                    showLocation: location.authorized,
                    recenter: location.recenter,
                    focusRequest: focusRequest,
                    isPeekEnabled: libraryStore.hasEnabledOverlay,
                    onPeekPressChanged: { pressing in
                        let nextPeeking = pressing && libraryStore.hasEnabledOverlay
                        if nextPeeking && !isPeekingModernMap {
                            uiTestPeekTriggerCount += 1
                        }
                        isPeekingModernMap = nextPeeking
                    }
                )
                .ignoresSafeArea()

                if observePeekForUITests {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("archive.peek.state")
                        .accessibilityValue("count:\(uiTestPeekTriggerCount),peeking:\(isPeekingModernMap)")
                }

                GeometryReader { proxy in
                    Color.clear
                        .allowsHitTesting(false)
                        .preference(key: SafeAreaInsetsKey.self, value: proxy.safeAreaInsets)
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(SafeAreaInsetsKey.self) { safeAreaInsets = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .hiddenMapNavigationBarBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isLibraryPresented = true
                    } label: {
                        Label(AppText.libraryLabel, systemImage: "square.3.layers.3d")
                    }
                    .accessibilityIdentifier("archive.library")
                    .accessibilityLabel(AppText.libraryLabel)
                    .accessibilityHint(AppText.libraryHint)
                }
                .duoHighPriority()

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        location.locate()
                    } label: {
                        Label(AppText.locateLabel, systemImage: location.authorized ? "location.fill" : "location")
                    }
                    .accessibilityIdentifier("archive.locate")
                    .accessibilityLabel(AppText.locateLabel)
                    .accessibilityHint(AppText.locateHint)
                }
                .duoHighPriority()
            }
        }
        .tint(ArchiveTheme.primaryInk)
        .onChange(of: isLibraryPresented) { _, presented in
            if presented { isPeekingModernMap = false }
        }
        .onChange(of: libraryStore.hasEnabledOverlay) { _, enabled in
            if !enabled { isPeekingModernMap = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isPeekingModernMap = false }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isPeekingModernMap)
        .task {
            await shanghaiAlignment.resolve()
        }
        .task(id: libraryStore.catalog.map(\.id)) {
            for map in libraryStore.catalog {
                _ = await MapSheetPreviewLoader.shared.loadPreview(for: map)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: focusRequest.nonce)
        .sheet(isPresented: $isLibraryPresented) {
            MapLibraryGalleryView(
                store: libraryStore,
                calibrationProfile: shanghaiAlignment.profile,
                defaultCalibrationCoordinate: MKMapPoint(
                    x: focusRequest.bounds.midX,
                    y: focusRequest.bounds.midY
                ).coordinate,
                reduceMotion: reduceMotion,
                onFocusMap: { map in
                    focusRequest = MapFocusRequest(
                        nonce: focusRequest.nonce + 1,
                        bounds: shanghaiAlignment.profile.displayBounds(for: map.bounds, mapID: map.id)
                    )
                    isLibraryPresented = false
                }
            )
            .presentationDragIndicator(.visible)
        }
        .alert(AppText.locationAlertTitle, isPresented: $location.showSettings) {
            if location.status == .denied {
                Button(AppText.locationAlertOpenSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Button(AppText.locationAlertOK, role: .cancel) {}
        } message: {
            Text(AppText.locationAlertMessage)
        }
    }
}
