import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

struct MapLibraryGalleryView: View {
    @ObservedObject var store: HistoricalMapLibraryStore
    let calibrationProfile: ShanghaiDisplayProfile
    let defaultCalibrationCoordinate: CLLocationCoordinate2D
    let reduceMotion: Bool
    let onFocusMap: (HistoricalMapArchive) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isOverviewGridPresented = false
    @State private var hasAlignedInitialScroll = false
    @State private var previewsByID: [String: UIImage] = [:]

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var calibrationDraft: MapCalibrationDraft?
    @State private var showImportFailureAlert = false
    @State private var pendingDeleteMap: HistoricalMapArchive?

    private let useSampleImportForUITests = ProcessInfo.processInfo.arguments.contains("-UITestingEnableSampleImport")

    private var activeMap: HistoricalMapArchive? {
        if let selectedID = store.selectedMapID,
           let matched = store.catalog.first(where: { $0.id == selectedID }) {
            return matched
        }
        return store.catalog.first
    }

    private var selectedMapBinding: Binding<String?> {
        Binding(
            get: { store.selectedMapID ?? store.catalog.first?.id },
            set: { newID in
                guard hasAlignedInitialScroll else { return }
                store.selectMap(newID)
            }
        )
    }

    var body: some View {
        ZStack {
            MonolithPalette.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                if store.catalog.isEmpty {
                    emptyLibraryView
                } else if isOverviewGridPresented {
                    overviewGridView
                        .transition(.opacity)
                } else {
                    showcaseBody
                        .transition(.opacity)
                }
            }
        }
        .fontDesign(.serif)
        .preferredColorScheme(.dark)
        .tint(MonolithPalette.ink)
        .sensoryFeedback(.selection, trigger: store.activeLayers(shanghaiProfile: .source))
        .onAppear {
            if store.selectedMapID == nil {
                store.selectMap(store.catalog.first?.id)
            }
            seedCachedPreviews()
        }
        .onChange(of: store.catalog.map(\.id)) { _, ids in
            if let current = store.selectedMapID, !ids.contains(current) {
                store.selectMap(ids.first)
            } else if store.selectedMapID == nil {
                store.selectMap(ids.first)
            }
            seedCachedPreviews()
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadPickedPhoto(newItem)
            }
        }
        .task(id: store.catalog.map(\.id)) {
            await loadMissingPreviews()
        }
        .fullScreenCover(item: $calibrationDraft) { draft in
            MapCalibrationView(
                draft: draft,
                defaultRegionCoordinate: defaultCalibrationCoordinate,
                calibrationProfile: calibrationProfile,
                reduceMotion: reduceMotion,
                onSaved: { record in
                    let archive = store.upsertUserMap(record: record)
                    previewsByID.removeValue(forKey: archive.id)
                    isOverviewGridPresented = false
                    Task {
                        if let rendered = await MapSheetPreviewLoader.shared.loadPreview(for: archive) {
                            previewsByID[archive.id] = rendered
                        }
                    }
                }
            )
        }
        .alert(AppText.calibrationImportFailedTitle, isPresented: $showImportFailureAlert) {
            Button(AppText.locationAlertOK, role: .cancel) {}
        } message: {
            Text(AppText.calibrationImportFailedMessage)
        }
        .alert(
            AppText.deleteMapAlertTitle,
            isPresented: Binding(
                get: { pendingDeleteMap != nil },
                set: { if !$0 { pendingDeleteMap = nil } }
            ),
            presenting: pendingDeleteMap
        ) { target in
            Button(AppText.deleteMapTitle, role: .destructive) {
                previewsByID.removeValue(forKey: target.id)
                store.deleteUserMap(id: target.id)
                pendingDeleteMap = nil
            }
            Button(AppText.cancelLabel, role: .cancel) {
                pendingDeleteMap = nil
            }
        } message: { target in
            Text(AppText.deleteMapAlertMessage(title: target.title))
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppText.libraryLabel)
                    .font(.footnote.weight(.medium))
                    .tracking(1.4)
                    .foregroundStyle(MonolithPalette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)

                if !store.catalog.isEmpty {
                    Text(String(format: "%02d / %02d", store.enabledCount, store.catalog.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MonolithPalette.inkMuted)
                        .lineLimit(1)
                        .accessibilityLabel(AppText.activeLayersCount(enabled: store.enabledCount, total: store.catalog.count))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                importPhotoButton

                if !store.catalog.isEmpty {
                    Rectangle()
                        .fill(MonolithPalette.hairline)
                        .frame(width: 1, height: 34)

                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            isOverviewGridPresented.toggle()
                        }
                    } label: {
                        Image(systemName: isOverviewGridPresented ? "rectangle.portrait.on.rectangle.portrait" : "square.grid.2x2")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(MonolithPalette.ink.opacity(0.88))
                            .frame(width: 38, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MonolithSegmentCellButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityIdentifier("archive.library.viewToggle")
                    .accessibilityLabel(AppText.viewToggleLabel(isGridPresented: isOverviewGridPresented))
                }

                Rectangle()
                    .fill(MonolithPalette.hairline)
                    .frame(width: 1, height: 34)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MonolithPalette.ink)
                        .frame(width: 38, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MonolithSegmentCellButtonStyle(reduceMotion: reduceMotion))
                .accessibilityIdentifier("archive.library.close")
                .accessibilityLabel(AppText.doneLabel)
            }
            .background(MonolithPalette.canvas)
            .overlay(
                Rectangle()
                    .strokeBorder(MonolithPalette.hairline, lineWidth: 1)
            )
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var importPhotoButton: some View {
        let iconView = Image(systemName: "plus")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(MonolithPalette.ink)
            .frame(width: 38, height: 34)
            .contentShape(Rectangle())

        if useSampleImportForUITests {
            Button {
                calibrationDraft = MapCalibrationDraft(
                    image: ImportedMapImageUtilities.makeSampleTestMapImage(),
                    exifCoordinate: CLLocationCoordinate2D(latitude: 31.236, longitude: 121.482),
                    existingRecord: nil
                )
            } label: {
                iconView
            }
            .buttonStyle(MonolithSegmentCellButtonStyle(reduceMotion: reduceMotion))
            .accessibilityIdentifier("archive.library.import")
            .accessibilityLabel(AppText.importMapLabel)
        } else {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                iconView
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("archive.library.import")
            .accessibilityLabel(AppText.importMapLabel)
        }
    }

    private var showcaseBody: some View {
        GeometryReader { proxy in
            let isShortViewport = proxy.size.height < 520
            let maxEditorialWidth = min(proxy.size.width, 460)
            let stageHeight = isShortViewport
                ? max(146, min(proxy.size.height * 0.42, 184))
                : max(248, min(proxy.size.height * 0.48, 344))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if !store.hasEnabledOverlay {
                        allDisabledNoticeStrip
                            .frame(maxWidth: maxEditorialWidth)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .transition(.opacity)
                    }

                    mapStageCarousel(
                        containerWidth: proxy.size.width,
                        stageHeight: stageHeight
                    )

                    if store.catalog.count > 1 {
                        paginationBars
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                    }

                    if let map = activeMap {
                        EditorialMapPlacard(
                            map: map,
                            state: store.state(for: map),
                            reduceMotion: reduceMotion,
                            onSelectDisplayMode: { mode in
                                store.setDisplayMode(mode, for: map.id)
                            },
                            onFocus: {
                                onFocusMap(map)
                            },
                            onRecalibrate: {
                                startRecalibration(for: map)
                            },
                            onDelete: {
                                pendingDeleteMap = map
                            }
                        )
                        .frame(maxWidth: maxEditorialWidth)
                        .padding(.horizontal, 22)
                        .padding(.top, isShortViewport ? 6 : 10)
                        .padding(.bottom, isShortViewport ? 16 : 26)
                        .id(map.id)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func mapStageCarousel(containerWidth: CGFloat, stageHeight: CGFloat) -> some View {
        let cardWidth = min(containerWidth - 32, 372)
        let horizontalInset = max(16, (containerWidth - cardWidth) / 2)

        if store.catalog.count <= 1, let onlyMap = store.catalog.first {
            PerspectiveMapSheetView(
                map: onlyMap,
                previewImage: previewsByID[onlyMap.id],
                displayMode: store.state(for: onlyMap).displayMode,
                isAvailable: onlyMap.bundleURL != nil,
                reduceMotion: reduceMotion
            )
            .frame(width: cardWidth, height: stageHeight)
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 22) {
                        ForEach(store.catalog) { map in
                            PerspectiveMapSheetView(
                                map: map,
                                previewImage: previewsByID[map.id],
                                displayMode: store.state(for: map).displayMode,
                                isAvailable: map.bundleURL != nil,
                                reduceMotion: reduceMotion
                            )
                            .frame(width: cardWidth, height: stageHeight)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.89)
                                    .opacity(phase.isIdentity ? 1.0 : 0.48)
                            }
                            .id(map.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: selectedMapBinding)
                .frame(height: stageHeight)
                .onAppear {
                    hasAlignedInitialScroll = false
                    if let targetID = activeMap?.id {
                        scrollProxy.scrollTo(targetID, anchor: .center)
                    }
                    DispatchQueue.main.async {
                        hasAlignedInitialScroll = true
                    }
                }
                .onChange(of: store.selectedMapID) { _, newID in
                    guard let newID else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                        scrollProxy.scrollTo(newID, anchor: .center)
                    }
                }
                .onDisappear {
                    hasAlignedInitialScroll = false
                }
            }
        }
    }

    private var paginationBars: some View {
        HStack(spacing: 5) {
            ForEach(store.catalog) { map in
                let isCurrent = map.id == activeMap?.id
                Rectangle()
                    .fill(isCurrent ? MonolithPalette.ink : MonolithPalette.hairline)
                    .frame(width: isCurrent ? 24 : 10, height: 1.5)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: activeMap?.id)
            }
        }
        .accessibilityHidden(true)
    }

    private var allDisabledNoticeStrip: some View {
        HStack(spacing: 10) {
            Text(AppText.modernBasemapOnlyNotice)
                .font(.caption)
                .foregroundStyle(MonolithPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if store.hasAnyAvailableMap {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        store.enableAllAvailableMaps()
                    }
                } label: {
                    Text(AppText.enableAllTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MonolithPalette.ink)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(
                            Rectangle()
                                .fill(MonolithPalette.surfaceElevated)
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("archive.library.enableAll")
                .accessibilityLabel(AppText.enableAllAccessibilityLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(
            Rectangle()
                .fill(MonolithPalette.surface)
                .overlay(
                    Rectangle()
                        .strokeBorder(MonolithPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.library.disabledState")
    }

    private var overviewGridView: some View {
        GeometryReader { proxy in
            let columnCount = proxy.size.width > 560 ? 3 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.catalog) { map in
                        let mapState = store.state(for: map)
                        let isSelected = map.id == activeMap?.id

                        Button {
                            hasAlignedInitialScroll = false
                            store.selectMap(map.id)
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                isOverviewGridPresented = false
                            }
                        } label: {
                            OverviewGridCard(
                                map: map,
                                previewImage: previewsByID[map.id],
                                displayMode: mapState.displayMode,
                                isSelected: isSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("archive.library.grid.\(map.id)")
                        .accessibilityLabel(
                            AppText.gridCardAccessibilityLabel(
                                displayTitle: map.displayTitle,
                                modeTitle: mapState.displayMode.title
                            )
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .accessibilityIdentifier("archive.library.grid")
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            Image(systemName: "map")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(MonolithPalette.inkMuted)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(AppText.emptyLibraryTitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(MonolithPalette.ink)

                Text(AppText.emptyLibraryMessage)
                    .font(.footnote)
                    .foregroundStyle(MonolithPalette.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.restoreCatalogDefaults()
            } label: {
                Text(AppText.restoreBuiltInMapsTitle)
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(MonolithPalette.inkOnInverted)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 46)
            }
            .buttonStyle(MonolithInvertedButtonStyle(reduceMotion: reduceMotion))
            .padding(.top, 4)
            .accessibilityIdentifier("archive.library.restore")

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.library.empty")
    }

    private func seedCachedPreviews() {
        for map in store.catalog {
            if previewsByID[map.id] == nil, let cached = MapSheetPreviewLoader.shared.cachedPreview(for: map) {
                previewsByID[map.id] = cached
            }
        }
    }

    private func loadMissingPreviews() async {
        for map in store.catalog {
            if previewsByID[map.id] != nil { continue }
            if let rendered = await MapSheetPreviewLoader.shared.loadPreview(for: map) {
                previewsByID[map.id] = rendered
            }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ImportedMapImageUtilities.normalizedUprightImage(from: data) else {
            showImportFailureAlert = true
            return
        }
        let exifCoord = ImportedMapImageUtilities.extractGPSCoordinate(from: data)
        calibrationDraft = MapCalibrationDraft(
            image: image,
            exifCoordinate: exifCoord,
            existingRecord: nil
        )
    }

    private func startRecalibration(for map: HistoricalMapArchive) {
        guard map.isUserImported,
              let record = store.loadUserRecord(id: map.id),
              let sourceImage = store.loadUserSourceImage(id: map.id) else {
            return
        }
        calibrationDraft = MapCalibrationDraft(
            image: sourceImage,
            exifCoordinate: nil,
            existingRecord: record
        )
    }
}

// MARK: - 2.5D Perspective Map Sheet (Sharp 0pt Monolith Stage)

private struct PerspectiveMapSheetView: View {
    let map: HistoricalMapArchive
    let previewImage: UIImage?
    let displayMode: HistoricalLayerDisplayMode
    let isAvailable: Bool
    let reduceMotion: Bool

    private var isHidden: Bool {
        displayMode == .hidden || !isAvailable
    }

    private var isTranslucent: Bool {
        displayMode == .translucent && isAvailable
    }

    private var sheetAspectRatio: CGFloat {
        guard let image = previewImage, image.size.height > 0 else {
            return 1.408
        }
        return max(0.68, min(1.85, image.size.width / image.size.height))
    }

    var body: some View {
        GeometryReader { proxy in
            let maxW = max(148, proxy.size.width - 56)
            let maxH = max(116, proxy.size.height - 40)
            let fittedWidth = min(maxW, maxH * sheetAspectRatio)
            let fittedHeight = fittedWidth / sheetAspectRatio

            ZStack {
                ZStack {
                    Rectangle()
                        .fill(isHidden ? MonolithPalette.paperEdgeDim : MonolithPalette.paperEdgeDeep)
                        .frame(width: fittedWidth, height: fittedHeight)
                        .offset(x: -2.5, y: 4.5)

                    Rectangle()
                        .fill(isHidden ? MonolithPalette.paperEdgeDim.opacity(0.85) : MonolithPalette.paperEdgeTop)
                        .frame(width: fittedWidth, height: fittedHeight)
                        .offset(x: -1.2, y: 2.2)

                    ZStack {
                        ModernGridUnderlay()
                            .opacity(isTranslucent ? 1.0 : 0.0)

                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: fittedWidth, height: fittedHeight)
                                .opacity(isTranslucent ? 0.78 : 1.0)
                        } else {
                            placeholderParchment
                        }

                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.10), location: 0.0),
                                .init(color: Color.clear, location: 0.45),
                                .init(color: Color.black.opacity(0.16), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .frame(width: fittedWidth, height: fittedHeight)
                    .background(MonolithPalette.paperBase)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                MonolithPalette.ink.opacity(isHidden ? 0.08 : 0.22),
                                lineWidth: 0.5
                            )
                    )
                }
                .shadow(color: .black.opacity(isHidden ? 0.48 : 0.82), radius: isHidden ? 12 : 24, x: -3, y: isHidden ? 10 : 18)
                .shadow(color: .black.opacity(isHidden ? 0.28 : 0.50), radius: 6, x: 0, y: 5)
                .saturation(isHidden ? 0.42 : 1.02)
                .brightness(isHidden ? -0.22 : 0.0)
                .rotation3DEffect(
                    .degrees(isHidden ? 44 : 36),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.44
                )
                .rotationEffect(.degrees(-5.5))
                .scaleEffect(isHidden ? 0.93 : 1.0)
                .offset(y: isHidden ? 10 : 0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.84),
                    value: displayMode
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppText.previewAccessibilityLabel(
                displayTitle: map.displayTitle,
                modeTitle: displayMode.title
            )
        )
        .accessibilityIdentifier("archive.library.\(map.id).preview")
    }

    private var placeholderParchment: some View {
        ZStack {
            MonolithPalette.paperBase
            Rectangle()
                .strokeBorder(Color(red: 0.35, green: 0.28, blue: 0.18).opacity(0.28), lineWidth: 1)
                .padding(10)
            Text(map.yearNumber)
                .font(.title2.weight(.medium))
                .foregroundStyle(Color(red: 0.30, green: 0.24, blue: 0.15).opacity(0.55))
        }
    }
}

private struct ModernGridUnderlay: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.075, green: 0.078, blue: 0.086)))

            var grid = Path()
            let rows = 5
            let cols = 5
            for idx in 1..<rows {
                let y = size.height * CGFloat(idx) / CGFloat(rows)
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            for idx in 1..<cols {
                let x = size.width * CGFloat(idx) / CGFloat(cols)
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

            var river = Path()
            river.move(to: CGPoint(x: size.width, y: size.height * 0.34))
            river.addCurve(
                to: CGPoint(x: size.width * 0.70, y: size.height),
                control1: CGPoint(x: size.width * 0.76, y: size.height * 0.39),
                control2: CGPoint(x: size.width * 0.64, y: size.height * 0.72)
            )
            context.stroke(
                river,
                with: .color(Color(red: 0.16, green: 0.22, blue: 0.27)),
                style: StrokeStyle(lineWidth: size.width * 0.085, lineCap: .butt)
            )

            var creek = Path()
            creek.move(to: CGPoint(x: 0, y: size.height * 0.50))
            creek.addQuadCurve(
                to: CGPoint(x: size.width * 0.67, y: size.height * 0.50),
                control: CGPoint(x: size.width * 0.38, y: size.height * 0.44)
            )
            context.stroke(
                creek,
                with: .color(Color(red: 0.13, green: 0.18, blue: 0.22)),
                style: StrokeStyle(lineWidth: max(4, size.width * 0.025), lineCap: .butt)
            )
        }
    }
}

// MARK: - Minimal Monochrome Editorial Placard (B3 Full Serif)

private struct EditorialMapPlacard: View {
    let map: HistoricalMapArchive
    let state: HistoricalMapLayerState
    let reduceMotion: Bool
    let onSelectDisplayMode: (HistoricalLayerDisplayMode) -> Void
    let onFocus: () -> Void
    let onRecalibrate: () -> Void
    let onDelete: () -> Void

    @Namespace private var modeHighlightNamespace

    private var isAvailable: Bool { map.bundleURL != nil }
    private var activeMode: HistoricalLayerDisplayMode {
        isAvailable ? state.displayMode : .hidden
    }

    private var inlineYearTag: String? {
        let trimmed = map.yearNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "USER" else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleWithInlineYear
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    trailingMetadataAction
                }

                if !isAvailable {
                    Label(AppText.missingLocalArchiveWarning(yearLabel: map.yearLabel), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(MonolithPalette.inkSecondary)
                }
            }

            triStateControl

            Button(action: onFocus) {
                Text(AppText.viewMapSheetTitle)
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(MonolithPalette.inkOnInverted)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(MonolithInvertedButtonStyle(reduceMotion: reduceMotion))
            .accessibilityIdentifier("archive.library.\(map.id).focus")
            .accessibilityLabel(AppText.viewMapSheetAccessibilityLabel(displayTitle: map.displayTitle))
            .accessibilityHint(AppText.viewMapSheetAccessibilityHint(regionLabel: map.regionLabel))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.library.row.\(map.id)")
    }

    @ViewBuilder
    private var titleWithInlineYear: some View {
        let titleView = Text(map.title)
            .font(.title2.weight(.medium))
            .tracking(0.4)
            .foregroundStyle(MonolithPalette.ink)
            .fixedSize(horizontal: false, vertical: true)

        if let year = inlineYearTag {
            let yearView = Text(year)
                .font(.subheadline.weight(.regular).monospacedDigit())
                .tracking(0.8)
                .foregroundStyle(MonolithPalette.inkMuted)
                .fixedSize(horizontal: true, vertical: false)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleView
                        .fixedSize(horizontal: true, vertical: false)
                    yearView
                }

                VStack(alignment: .leading, spacing: 3) {
                    titleView
                    yearView
                }
            }
        } else {
            titleView
        }
    }

    @ViewBuilder
    private var trailingMetadataAction: some View {
        if map.isUserImported {
            HStack(spacing: 4) {
                Button(action: onRecalibrate) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MonolithPalette.inkSecondary)
                        .frame(minWidth: 38, minHeight: 44, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive.library.\(map.id).recalibrate")
                .accessibilityLabel(AppText.recalibrateTitle)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MonolithPalette.destructive.opacity(0.85))
                        .frame(minWidth: 38, minHeight: 44, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive.library.\(map.id).delete")
                .accessibilityLabel(AppText.deleteMapTitle)
            }
        } else if let sourceURL = map.sourceURL {
            Link(destination: sourceURL) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(MonolithPalette.inkMuted)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("archive.library.\(map.id).source")
            .accessibilityLabel(AppText.archiveSourceAccessibilityLabel(displayTitle: map.displayTitle))
        }
    }

    private var triStateControl: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(MonolithPalette.hairline)
                .frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(HistoricalLayerDisplayMode.allCases) { mode in
                        triStateButton(for: mode)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(HistoricalLayerDisplayMode.allCases) { mode in
                        triStateButton(for: mode)
                    }
                }
            }

            Rectangle()
                .fill(MonolithPalette.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.library.\(map.id).opacityMode")
    }

    private func triStateButton(for mode: HistoricalLayerDisplayMode) -> some View {
        let isSelected = activeMode == mode

        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                onSelectDisplayMode(mode)
            }
        } label: {
            Text(mode.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .tracking(0.5)
                .foregroundStyle(labelColor(isSelected: isSelected))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .background {
                    if isSelected {
                        ZStack(alignment: .bottom) {
                            Rectangle()
                                .fill(MonolithPalette.surfaceElevated)
                            Rectangle()
                                .fill(MonolithPalette.ink)
                                .frame(height: 1.5)
                        }
                        .matchedGeometryEffect(id: "activeModeHighlight", in: modeHighlightNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityIdentifier(mode.accessibilityIdentifier(for: map.id))
        .accessibilityLabel(
            AppText.triStateAccessibilityLabel(
                displayTitle: map.displayTitle,
                modeTitle: mode.title
            )
        )
        .accessibilityHint(mode.accessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func labelColor(isSelected: Bool) -> Color {
        guard isAvailable else { return MonolithPalette.inkFaint }
        return isSelected ? MonolithPalette.ink : MonolithPalette.inkMuted
    }
}

// MARK: - Overview Grid Card (Sharp 0pt Monochrome)

private struct OverviewGridCard: View {
    let map: HistoricalMapArchive
    let previewImage: UIImage?
    let displayMode: HistoricalLayerDisplayMode
    let isSelected: Bool

    private var isHidden: Bool { displayMode == .hidden }

    private var inlineYearTag: String? {
        let trimmed = map.yearNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "USER" else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                MonolithPalette.canvasDeep

                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(MonolithPalette.paperBase)
                            .aspectRatio(1.4, contentMode: .fit)
                    }
                }
                .clipped()
                .overlay(
                    Rectangle()
                        .strokeBorder(MonolithPalette.ink.opacity(isHidden ? 0.08 : 0.18), lineWidth: 0.5)
                )
                .padding(16)
                .shadow(color: .black.opacity(0.68), radius: 10, x: -2, y: 8)
                .saturation(isHidden ? 0.42 : 1.0)
                .brightness(isHidden ? -0.20 : 0.0)
                .rotationEffect(.degrees(-5))
                .rotation3DEffect(.degrees(28), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            }
            .frame(height: 118)
            .clipped()

            Rectangle()
                .fill(MonolithPalette.hairlineSubtle)
                .frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(map.title)
                        .font(.subheadline.weight(isHidden ? .regular : .medium))
                        .foregroundStyle(isHidden ? MonolithPalette.inkSecondary : MonolithPalette.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if let year = inlineYearTag {
                        Text(year)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(MonolithPalette.inkMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(map.title)
                        .font(.caption.weight(isHidden ? .regular : .medium))
                        .foregroundStyle(isHidden ? MonolithPalette.inkSecondary : MonolithPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let year = inlineYearTag {
                        Text(year)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(MonolithPalette.inkMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                if !isHidden {
                    Rectangle()
                        .fill(MonolithPalette.ink.opacity(displayMode == .opaque ? 0.92 : 0.45))
                        .frame(height: 1.5)
                }
            }
        }
        .background(MonolithPalette.surface)
        .overlay(
            Rectangle()
                .strokeBorder(
                    isSelected ? MonolithPalette.ink : MonolithPalette.hairline,
                    lineWidth: 1
                )
        )
    }
}
