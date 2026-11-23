import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapCalibrationDraft: Identifiable {
    let id = UUID()
    let image: UIImage
    let exifCoordinate: CLLocationCoordinate2D?
    let existingRecord: UserMapRecord?
}

private enum CalibrationStage: String, CaseIterable {
    case place
    case pins
}

private enum PinPlacementStep: Equatable {
    case browsing
    case pickingSource
    case pickingTarget(imagePoint: CGPoint)
}

private struct CalibrationCameraRequest: Equatable {
    var nonce: Int = 0
    var mapRect: MKMapRect?
    var centerCoordinate: CLLocationCoordinate2D?
    var spanMeters: CLLocationDistance = 4_000
    var animated: Bool = true

    static func == (lhs: CalibrationCameraRequest, rhs: CalibrationCameraRequest) -> Bool {
        lhs.nonce == rhs.nonce
    }
}

private struct CalibrationPinDisplayItem: Equatable {
    let id: UUID
    let index: Int
    let coordinate: CLLocationCoordinate2D
    let residualMeters: Double?
    let hasResiduals: Bool

    static func == (lhs: CalibrationPinDisplayItem, rhs: CalibrationPinDisplayItem) -> Bool {
        lhs.id == rhs.id
            && lhs.index == rhs.index
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.residualMeters == rhs.residualMeters
            && lhs.hasResiduals == rhs.hasResiduals
    }

    var badgeColor: UIColor {
        guard hasResiduals, let meters = residualMeters else {
            return MonolithPalette.uiInk
        }
        if meters < 40 {
            return MonolithPalette.uiAccuracyGood
        } else if meters < 150 {
            return MonolithPalette.uiAccuracyFair
        } else {
            return MonolithPalette.uiAccuracyHigh
        }
    }

    var swiftUIColor: Color {
        Color(uiColor: badgeColor)
    }
}

private struct SearchPlaceResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let locality: String?
}

// MARK: - Main Calibration Studio View

struct MapCalibrationView: View {
    let draft: MapCalibrationDraft
    let defaultRegionCoordinate: CLLocationCoordinate2D
    let calibrationProfile: ShanghaiDisplayProfile
    let reduceMotion: Bool
    let onSaved: (UserMapRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var workingImage: UIImage
    @State private var roughPlacement: RoughMapPlacement
    @State private var controlPoints: [CalibrationControlPoint]
    @State private var stage: CalibrationStage = .place
    @State private var pinStep: PinPlacementStep = .browsing

    @State private var overlayOpacity: Double = 0.58
    @State private var targetGhostOpacity: Double = 0.16
    @State private var isPeekingBasemap = false

    @State private var currentCenterMapPoint: MKMapPoint
    @State private var currentVisibleMapWidth: Double
    @State private var cameraRequest: CalibrationCameraRequest
    @State private var animateNextOverlayUpdate = false

    // Place search state
    @State private var isSearchExpanded = false
    @State private var searchQuery = ""
    @State private var searchResults: [SearchPlaceResult] = []
    @State private var isSearching = false
    @State private var suggestedRegionLabel: String

    // Save sheet state
    private static let minimumRecommendedPins = 3
    @State private var isFewPinsAlertPresented = false
    @State private var isSaveSheetPresented = false
    @State private var mapTitle: String
    @State private var mapYear: String
    @State private var mapRegion: String
    @State private var isSaving = false
    @State private var saveProgress: Double = 0
    @State private var saveErrorMessage: String?

    init(
        draft: MapCalibrationDraft,
        defaultRegionCoordinate: CLLocationCoordinate2D,
        calibrationProfile: ShanghaiDisplayProfile,
        reduceMotion: Bool,
        onSaved: @escaping (UserMapRecord) -> Void
    ) {
        self.draft = draft
        self.defaultRegionCoordinate = defaultRegionCoordinate
        self.calibrationProfile = calibrationProfile
        self.reduceMotion = reduceMotion
        self.onSaved = onSaved

        let normalized = ImportedMapImageUtilities.redrawUpright(draft.image)
        _workingImage = State(initialValue: normalized)

        if let record = draft.existingRecord {
            _roughPlacement = State(initialValue: record.roughPlacement)
            _controlPoints = State(initialValue: record.controlPoints)
            let rect = record.bounds.mapRect
            _currentCenterMapPoint = State(initialValue: MKMapPoint(x: rect.midX, y: rect.midY))
            _currentVisibleMapWidth = State(initialValue: max(4_000, rect.width * 1.45))
            _cameraRequest = State(initialValue: CalibrationCameraRequest(
                nonce: 1,
                mapRect: rect,
                centerCoordinate: nil,
                animated: false
            ))
            _stage = State(initialValue: record.controlPoints.isEmpty ? .place : .pins)
            _mapTitle = State(initialValue: record.title)
            _mapYear = State(initialValue: record.yearNumber == "USER" ? "" : record.yearNumber)
            _mapRegion = State(initialValue: record.regionLabel)
            _suggestedRegionLabel = State(initialValue: record.regionLabel)
        } else {
            let startCoord = draft.exifCoordinate ?? defaultRegionCoordinate
            let startPoint = MKMapPoint(startCoord)
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(startCoord.latitude)
            let initialVisibleWidth = max(2_000, 4_000 * pointsPerMeter)
            let initialRough = RoughMapPlacement.initial(
                imageSize: normalized.size,
                around: startPoint,
                visibleMapWidth: initialVisibleWidth
            )
            _roughPlacement = State(initialValue: initialRough)
            _controlPoints = State(initialValue: [])
            _currentCenterMapPoint = State(initialValue: startPoint)
            _currentVisibleMapWidth = State(initialValue: initialVisibleWidth)
            _cameraRequest = State(initialValue: CalibrationCameraRequest(
                nonce: 1,
                mapRect: nil,
                centerCoordinate: startCoord,
                spanMeters: 4_000,
                animated: false
            ))
            _mapTitle = State(initialValue: "")
            _mapYear = State(initialValue: "")
            _mapRegion = State(initialValue: "")
            _suggestedRegionLabel = State(initialValue: "")
        }
    }

    private var fitResult: CalibrationFitResult {
        MapCalibrationSolver.solve(
            imageSize: workingImage.size,
            rough: roughPlacement,
            controlPoints: controlPoints
        )
    }

    private var effectiveOverlayOpacity: Float {
        if isPeekingBasemap { return 0.0 }
        switch stage {
        case .place:
            return Float(overlayOpacity)
        case .pins:
            switch pinStep {
            case .browsing:
                return Float(overlayOpacity)
            case .pickingSource:
                return 0.88
            case .pickingTarget:
                return Float(targetGhostOpacity)
            }
        }
    }

    private var isCrosshairInsideImage: Bool {
        fitResult.transform.contains(
            mapPoint: currentCenterMapPoint,
            imageSize: workingImage.size,
            marginPixels: 6
        )
    }

    private var pendingSourceMapPoint: MKMapPoint? {
        if case .pickingTarget(let imagePoint) = pinStep {
            return fitResult.transform.apply(imagePoint)
        }
        return nil
    }

    private var pinDisplayItems: [CalibrationPinDisplayItem] {
        let fit = fitResult
        let showResiduals = controlPoints.count >= 4
        return controlPoints.enumerated().map { idx, pt in
            CalibrationPinDisplayItem(
                id: pt.id,
                index: idx + 1,
                coordinate: pt.coordinate,
                residualMeters: fit.residualMeters(for: pt.id),
                hasResiduals: showResiduals
            )
        }
    }

    private var hasRecommendedPins: Bool {
        controlPoints.count >= Self.minimumRecommendedPins
    }

    private var canDragRoughSheet: Bool {
        stage == .place && controlPoints.isEmpty
    }

    private var showCrosshair: Bool {
        stage == .pins && pinStep != .browsing
    }

    private var crosshairColor: UIColor {
        switch pinStep {
        case .pickingTarget:
            return UIColor.white
        default:
            return MonolithPalette.uiInk
        }
    }

    var body: some View {
        ZStack {
            CalibrationMapCanvas(
                image: workingImage,
                transform: fitResult.transform,
                opacity: effectiveOverlayOpacity,
                showBorder: stage == .place || pinStep == .pickingSource,
                isSheetGestureEnabled: canDragRoughSheet,
                showCrosshair: showCrosshair,
                crosshairColor: crosshairColor,
                pendingSourceMapPoint: pendingSourceMapPoint,
                pins: stage == .pins ? pinDisplayItems : [],
                cameraRequest: cameraRequest,
                animateOverlay: animateNextOverlayUpdate && !reduceMotion,
                onVisibleRegionChanged: { centerPoint, visibleWidth in
                    currentCenterMapPoint = centerPoint
                    currentVisibleMapWidth = visibleWidth
                },
                onRoughGesture: { deltaMapX, deltaMapY, scaleFactor, rotationDelta, focalMapPoint in
                    applyRoughGesture(
                        deltaMapX: deltaMapX,
                        deltaMapY: deltaMapY,
                        scaleFactor: scaleFactor,
                        rotationDelta: rotationDelta,
                        focalMapPoint: focalMapPoint
                    )
                },
                onConsumedOverlayAnimation: {
                    animateNextOverlayUpdate = false
                }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome
                if isSearchExpanded {
                    searchPanel
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    statusBar
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                Spacer(minLength: 16)

                bottomDock
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if isSaveSheetPresented {
                SaveCalibratedMapOverlay(
                    title: $mapTitle,
                    year: $mapYear,
                    region: $mapRegion,
                    fitResult: fitResult,
                    pinCount: controlPoints.count,
                    isSaving: isSaving,
                    progress: saveProgress,
                    errorMessage: saveErrorMessage,
                    onCancel: {
                        guard !isSaving else { return }
                        saveErrorMessage = nil
                        isSaveSheetPresented = false
                    },
                    onSave: {
                        performSave()
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .fontDesign(.serif)
        .preferredColorScheme(.dark)
        .tint(MonolithPalette.ink)
        .task {
            if suggestedRegionLabel.isEmpty {
                await reverseGeocodeCurrentCenter()
            }
        }
        .alert(AppText.calibrationFewPinsAlertTitle, isPresented: $isFewPinsAlertPresented) {
            Button(AppText.calibrationFewPinsContinueTitle(pinCount: controlPoints.count), role: .cancel) {
                isSearchExpanded = false
                pinStep = .browsing
                stage = .pins
            }
            Button(AppText.calibrationFewPinsSaveAnywayTitle) {
                prepareAndPresentSaveSheet()
            }
        } message: {
            Text(AppText.calibrationFewPinsAlertMessage(
                pinCount: controlPoints.count,
                minimumRecommended: Self.minimumRecommendedPins
            ))
        }
    }

    // MARK: - Top Bar & Search

    private var topChrome: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text(AppText.cancelLabel)
                    .font(.subheadline.weight(.regular))
                    .foregroundStyle(MonolithPalette.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    .background(
                        Rectangle()
                            .fill(MonolithPalette.surfaceDock)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("calibration.cancel")

            Spacer(minLength: 8)

            // 2-stage switcher
            HStack(spacing: 0) {
                stageTabButton(
                    title: AppText.calibrationStagePlaceTitle,
                    isSelected: stage == .place,
                    identifier: "calibration.stage.place"
                ) {
                    pinStep = .browsing
                    stage = .place
                }

                Rectangle()
                    .fill(MonolithPalette.hairline)
                    .frame(width: 1, height: 36)

                stageTabButton(
                    title: AppText.calibrationStagePinsTitle(count: controlPoints.count),
                    isSelected: stage == .pins,
                    identifier: "calibration.stage.pins"
                ) {
                    isSearchExpanded = false
                    stage = .pins
                }
            }
            .background(
                Rectangle()
                    .fill(MonolithPalette.surfaceDock)
                    .overlay(
                        Rectangle()
                            .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func stageTabButton(
        title: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? MonolithPalette.ink : MonolithPalette.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(isSelected ? MonolithPalette.surfaceElevated : Color.clear)
                        if isSelected {
                            Rectangle()
                                .fill(MonolithPalette.ink)
                                .frame(height: 1.5)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isSearchExpanded = true
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.regular))
                        .foregroundStyle(MonolithPalette.inkSecondary)

                    Text(statusPillText)
                        .font(.caption.weight(.regular).monospacedDigit())
                        .foregroundStyle(MonolithPalette.ink.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(
                    Rectangle()
                        .fill(MonolithPalette.surfaceDock)
                        .overlay(
                            Rectangle()
                                .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("calibration.searchToggle")

            Spacer(minLength: 0)
        }
    }

    private var statusPillText: String {
        if stage == .place {
            return suggestedRegionLabel.isEmpty
                ? AppText.calibrationSearchPlaceholder
                : suggestedRegionLabel
        }
        let fit = fitResult
        return AppText.calibrationFitSummary(
            mode: fit.mode,
            pinCount: controlPoints.count,
            meanErrorMeters: fit.meanErrorMeters
        )
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(MonolithPalette.inkSecondary)

                TextField(AppText.calibrationSearchPlaceholder, text: $searchQuery)
                    .font(.subheadline)
                    .foregroundStyle(MonolithPalette.ink)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await runPlaceSearch() }
                    }
                    .accessibilityIdentifier("calibration.searchField")

                if isSearching {
                    ProgressView()
                        .scaleEffect(0.75)
                }

                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        isSearchExpanded = false
                        searchResults = []
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MonolithPalette.inkMuted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !searchResults.isEmpty {
                Rectangle()
                    .fill(MonolithPalette.hairline)
                    .frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, item in
                        Button {
                            selectSearchResult(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin")
                                    .font(.caption)
                                    .foregroundStyle(MonolithPalette.inkSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(MonolithPalette.ink)
                                        .lineLimit(1)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(MonolithPalette.inkMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < searchResults.count - 1 {
                            Rectangle()
                                .fill(MonolithPalette.hairlineSubtle)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(
            Rectangle()
                .fill(MonolithPalette.surfaceOverlay)
                .overlay(
                    Rectangle()
                        .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                )
        )
    }

    // MARK: - Bottom Dock

    @ViewBuilder
    private var bottomDock: some View {
        switch stage {
        case .place:
            stage1BottomDock
        case .pins:
            stage2BottomDock
        }
    }

    private var stage1BottomDock: some View {
        VStack(spacing: 10) {
            if !controlPoints.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "pin")
                        .font(.caption)
                        .foregroundStyle(MonolithPalette.inkSecondary)
                    Text(AppText.calibrationPinsLockNotice)
                        .font(.caption)
                        .foregroundStyle(MonolithPalette.ink.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        clearAllPins()
                    } label: {
                        Text(AppText.calibrationResetPinsTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MonolithPalette.destructive)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.destructive.opacity(0.10))
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(MonolithPalette.destructive.opacity(0.45), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            } else {
                Text(AppText.calibrationStage1Hint)
                    .font(.caption)
                    .foregroundStyle(MonolithPalette.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if controlPoints.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        bringSheetToCurrentCenter()
                    } label: {
                        Label(AppText.calibrationCenterSheetHere, systemImage: "scope")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MonolithPalette.ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
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
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.centerHere")

                    Button {
                        rotateImage90Clockwise()
                    } label: {
                        Label(AppText.calibrationRotate90Label, systemImage: "rotate.right")
                            .font(.caption.weight(.regular))
                            .foregroundStyle(MonolithPalette.ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.surface)
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.rotate90")

                    Spacer(minLength: 0)
                }
            }

            // Opacity + Hold-to-Peek row
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(MonolithPalette.inkMuted)

                Slider(value: $overlayOpacity, in: 0.15...1.0)
                    .tint(MonolithPalette.ink)

                PeekHoldIconButton(
                    isPeeking: isPeekingBasemap,
                    accessibilityLabel: AppText.calibrationPeekHoldLabel
                ) { pressing in
                    isPeekingBasemap = pressing
                }
                .frame(width: 40, height: 40)
            }

            // Primary progression + secondary early save row
            HStack(spacing: 8) {
                Button {
                    requestSave()
                } label: {
                    Text(AppText.saveLabel)
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(MonolithPalette.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
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
                .contentShape(Rectangle())
                .accessibilityIdentifier("calibration.earlySave")

                Button {
                    isSearchExpanded = false
                    pinStep = .browsing
                    stage = .pins
                } label: {
                    HStack(spacing: 6) {
                        Text(
                            controlPoints.isEmpty
                                ? AppText.calibrationNextPinsTitle
                                : AppText.calibrationContinueToPinsTitle(count: controlPoints.count)
                        )
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(MonolithPalette.inkOnInverted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        Rectangle()
                            .fill(MonolithPalette.ink)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("calibration.nextPins")
            }
        }
        .padding(14)
        .background(dockBackground)
    }

    @ViewBuilder
    private var stage2BottomDock: some View {
        switch pinStep {
        case .browsing:
            stage2BrowsingDock
        case .pickingSource:
            stage2PickingSourceDock
        case .pickingTarget:
            stage2PickingTargetDock
        }
    }

    private var stage2BrowsingDock: some View {
        VStack(spacing: 10) {
            if !pinDisplayItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pinDisplayItems, id: \.id) { item in
                            HStack(spacing: 6) {
                                Button {
                                    focusOnCoordinate(item.coordinate)
                                } label: {
                                    HStack(spacing: 6) {
                                        Rectangle()
                                            .fill(item.swiftUIColor)
                                            .frame(width: 6, height: 6)
                                        Text("#\(item.index)")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .fontDesign(.default)
                                            .foregroundStyle(MonolithPalette.ink)
                                        if item.hasResiduals, let err = item.residualMeters {
                                            Text("±\(Int(err.rounded()))m")
                                                .font(.caption2.monospacedDigit())
                                                .fontDesign(.default)
                                                .foregroundStyle(MonolithPalette.inkSecondary)
                                        }
                                    }
                                    .padding(.leading, 9)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    deletePin(id: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(MonolithPalette.inkMuted)
                                        .frame(width: 26, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("calibration.pin.\(item.index).delete")
                            }
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.surfaceElevated)
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }

            if !hasRecommendedPins {
                Text(AppText.calibrationRecommendedPinsHint(
                    currentCount: controlPoints.count,
                    minimumRecommended: Self.minimumRecommendedPins
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(MonolithPalette.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("calibration.pinsRecommendationHint")
            }

            HStack(spacing: 8) {
                if !hasRecommendedPins {
                    Button {
                        requestSave()
                    } label: {
                        Text(AppText.saveLabel)
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(MonolithPalette.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 46)
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
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.earlySave")

                    Button {
                        isSearchExpanded = false
                        pinStep = .pickingSource
                    } label: {
                        Label(AppText.calibrationAddAnotherPinTitle, systemImage: "plus.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(MonolithPalette.inkOnInverted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.ink)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.addPin")
                } else {
                    Button {
                        isSearchExpanded = false
                        pinStep = .pickingSource
                    } label: {
                        Label(AppText.calibrationAddAnotherPinTitle, systemImage: "plus.viewfinder")
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(MonolithPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 46)
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
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.addPin")

                    Button {
                        requestSave()
                    } label: {
                        Text(AppText.calibrationFinishAndSaveTitle)
                            .font(.subheadline.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(MonolithPalette.inkOnInverted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.ink)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("calibration.finishSave")
                }

                PeekHoldIconButton(
                    isPeeking: isPeekingBasemap,
                    accessibilityLabel: AppText.calibrationPeekHoldLabel
                ) { pressing in
                    isPeekingBasemap = pressing
                }
                .frame(width: 46, height: 46)
            }
        }
        .padding(14)
        .background(dockBackground)
    }

    private var stage2PickingSourceDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isCrosshairInsideImage ? "scope" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.regular))
                    .foregroundStyle(isCrosshairInsideImage ? MonolithPalette.ink : MonolithPalette.accuracyFair)

                Text(isCrosshairInsideImage ? AppText.calibrationPickSourceBanner : AppText.calibrationPickSourceOutsideHint)
                    .font(.caption.weight(.regular))
                    .foregroundStyle(MonolithPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    pinStep = .browsing
                } label: {
                    Text(AppText.cancelLabel)
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(MonolithPalette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
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
                .contentShape(Rectangle())

                Button {
                    lockSourcePointAtCrosshair()
                } label: {
                    Label(AppText.calibrationLockMapPointTitle, systemImage: "pin")
                        .font(.subheadline.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(
                            isCrosshairInsideImage
                                ? MonolithPalette.inkOnInverted
                                : MonolithPalette.inkMuted
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            Rectangle()
                                .fill(
                                    isCrosshairInsideImage
                                        ? MonolithPalette.ink
                                        : MonolithPalette.surfaceElevated
                                )
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(
                                            isCrosshairInsideImage ? Color.clear : MonolithPalette.hairline,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!isCrosshairInsideImage)
                .accessibilityIdentifier("calibration.lockSource")
            }
        }
        .padding(14)
        .background(dockBackground)
    }

    private var stage2PickingTargetDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline.weight(.regular))
                    .foregroundStyle(MonolithPalette.ink)

                Text(AppText.calibrationPickTargetBanner)
                    .font(.caption.weight(.regular))
                    .foregroundStyle(MonolithPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    // Cycle ghost visibility: 16% -> 0% -> 42%
                    if targetGhostOpacity > 0.3 {
                        targetGhostOpacity = 0.0
                    } else if targetGhostOpacity < 0.05 {
                        targetGhostOpacity = 0.16
                    } else {
                        targetGhostOpacity = 0.42
                    }
                } label: {
                    Image(systemName: targetGhostOpacity < 0.05 ? "eye.slash" : "eye")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MonolithPalette.ink)
                        .frame(width: 36, height: 36)
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
                .contentShape(Rectangle())
                .accessibilityLabel(AppText.calibrationGhostToggleLabel)
            }

            HStack(spacing: 8) {
                Button {
                    pinStep = .pickingSource
                } label: {
                    Text(AppText.backLabel)
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(MonolithPalette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
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
                .contentShape(Rectangle())
                .accessibilityIdentifier("calibration.backStep")

                Button {
                    commitTargetPointAtCrosshair()
                } label: {
                    Text(AppText.calibrationMatchHereTitle)
                        .font(.subheadline.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(MonolithPalette.inkOnInverted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            Rectangle()
                                .fill(MonolithPalette.ink)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("calibration.matchTarget")
            }
        }
        .padding(14)
        .background(dockBackground)
    }

    private var dockBackground: some View {
        Rectangle()
            .fill(MonolithPalette.surfaceDock)
            .overlay(
                Rectangle()
                    .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    // MARK: - Actions & Math Updates

    private func applyRoughGesture(
        deltaMapX: Double,
        deltaMapY: Double,
        scaleFactor: Double,
        rotationDelta: Double,
        focalMapPoint: MKMapPoint
    ) {
        guard controlPoints.isEmpty else { return }

        var next = roughPlacement
        // Translate first
        next.centerX += deltaMapX
        next.centerY += deltaMapY

        // Apply scale & rotation around the focal point so the map feels anchored under the user's fingers
        if abs(scaleFactor - 1.0) > 1e-5 || abs(rotationDelta) > 1e-5 {
            let clampedScale = max(0.02, min(50.0, scaleFactor))
            let newMpp = max(0.05, min(500_000.0, next.mapPointsPerPixel * clampedScale))
            let effectiveScale = newMpp / max(1e-9, next.mapPointsPerPixel)

            let vx = next.centerX - focalMapPoint.x
            let vy = next.centerY - focalMapPoint.y
            let cosR = cos(rotationDelta)
            let sinR = sin(rotationDelta)
            let rvx = (vx * cosR - vy * sinR) * effectiveScale
            let rvy = (vx * sinR + vy * cosR) * effectiveScale

            next.centerX = focalMapPoint.x + rvx
            next.centerY = focalMapPoint.y + rvy
            next.mapPointsPerPixel = newMpp
            next.rotationRadians += rotationDelta
        }

        roughPlacement = next
    }

    private func bringSheetToCurrentCenter() {
        guard controlPoints.isEmpty else { return }
        animateNextOverlayUpdate = true
        roughPlacement = RoughMapPlacement.initial(
            imageSize: workingImage.size,
            around: currentCenterMapPoint,
            visibleMapWidth: currentVisibleMapWidth
        )
    }

    private func rotateImage90Clockwise() {
        guard controlPoints.isEmpty else { return }
        workingImage = ImportedMapImageUtilities.rotatedClockwise90(workingImage)
    }

    private func lockSourcePointAtCrosshair() {
        guard let imagePoint = fitResult.transform.inverse(currentCenterMapPoint) else { return }
        let clampedX = max(0, min(Double(workingImage.size.width), Double(imagePoint.x)))
        let clampedY = max(0, min(Double(workingImage.size.height), Double(imagePoint.y)))
        pinStep = .pickingTarget(imagePoint: CGPoint(x: clampedX, y: clampedY))
    }

    private func commitTargetPointAtCrosshair() {
        guard case .pickingTarget(let imagePoint) = pinStep else { return }
        let newPin = CalibrationControlPoint(
            imageX: Double(imagePoint.x),
            imageY: Double(imagePoint.y),
            mapX: currentCenterMapPoint.x,
            mapY: currentCenterMapPoint.y
        )
        animateNextOverlayUpdate = true
        controlPoints.append(newPin)
        pinStep = .browsing
    }

    private func deletePin(id: UUID) {
        animateNextOverlayUpdate = true
        controlPoints.removeAll { $0.id == id }
    }

    private func clearAllPins() {
        // Capture current fitted center/scale/rotation back into roughPlacement so clearing pins doesn't jump wildly.
        let currentTransform = fitResult.transform
        let centerPx = CGPoint(x: workingImage.size.width * 0.5, y: workingImage.size.height * 0.5)
        let centerMp = currentTransform.apply(centerPx)
        roughPlacement = RoughMapPlacement(
            centerX: centerMp.x,
            centerY: centerMp.y,
            mapPointsPerPixel: currentTransform.averageMapPointsPerPixel,
            rotationRadians: atan2(currentTransform.c, currentTransform.a)
        )
        animateNextOverlayUpdate = true
        controlPoints.removeAll()
        pinStep = .browsing
    }

    private func focusOnCoordinate(_ coordinate: CLLocationCoordinate2D) {
        cameraRequest = CalibrationCameraRequest(
            nonce: cameraRequest.nonce + 1,
            mapRect: nil,
            centerCoordinate: coordinate,
            spanMeters: 1_200,
            animated: !reduceMotion
        )
    }

    private func runPlaceSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let response = try? await MKLocalSearch(request: request).start() {
            searchResults = response.mapItems.prefix(5).map { item in
                let coord: CLLocationCoordinate2D
                if #available(iOS 26.0, *) {
                    coord = item.location.coordinate
                } else {
                    coord = item.placemark.coordinate
                }
                let subtitle = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                return SearchPlaceResult(
                    title: item.name ?? query,
                    subtitle: subtitle,
                    coordinate: coord,
                    locality: item.placemark.locality ?? item.name
                )
            }
        }
    }

    private func selectSearchResult(_ item: SearchPlaceResult) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isSearchExpanded = false
            searchResults = []
        }
        suggestedRegionLabel = item.locality ?? item.title

        let targetPoint = MKMapPoint(item.coordinate)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(item.coordinate.latitude)
        let spanMeters: CLLocationDistance = 4_000
        let targetVisibleWidth = max(2_000, spanMeters * pointsPerMeter)

        if controlPoints.isEmpty {
            animateNextOverlayUpdate = true
            roughPlacement = RoughMapPlacement.initial(
                imageSize: workingImage.size,
                around: targetPoint,
                visibleMapWidth: targetVisibleWidth
            )
        }

        cameraRequest = CalibrationCameraRequest(
            nonce: cameraRequest.nonce + 1,
            mapRect: nil,
            centerCoordinate: item.coordinate,
            spanMeters: spanMeters,
            animated: !reduceMotion
        )
    }

    private func reverseGeocodeCurrentCenter() async {
        let coord = currentCenterMapPoint.coordinate
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        ), let first = placemarks.first {
            let label = first.locality ?? first.subAdministrativeArea ?? first.administrativeArea
            if let label, !label.isEmpty, suggestedRegionLabel.isEmpty {
                suggestedRegionLabel = label
            }
        }
    }

    private func requestSave() {
        isSearchExpanded = false
        pinStep = .browsing
        if hasRecommendedPins {
            prepareAndPresentSaveSheet()
        } else {
            isFewPinsAlertPresented = true
        }
    }

    private func prepareAndPresentSaveSheet() {
        isSearchExpanded = false
        pinStep = .browsing
        saveErrorMessage = nil
        if mapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !suggestedRegionLabel.isEmpty {
                mapTitle = suggestedRegionLabel
            } else {
                mapTitle = AppText.userMapDefaultTitle
            }
        }
        if mapRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mapRegion = suggestedRegionLabel.isEmpty ? AppText.userMapDefaultRegion : suggestedRegionLabel
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            isSaveSheetPresented = true
        }
    }

    private func performSave() {
        guard !isSaving else { return }
        saveErrorMessage = nil
        let finalTitle = mapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppText.userMapDefaultTitle
            : mapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalYear = mapYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalRegion = mapRegion.trimmingCharacters(in: .whitespacesAndNewlines)

        let imageSnapshot = workingImage
        let roughSnapshot = roughPlacement
        let pinsSnapshot = controlPoints
        let fitSnapshot = fitResult
        let existingSnapshot = draft.existingRecord
        let profileSnapshot = calibrationProfile

        isSaving = true
        saveProgress = 0.05

        Task.detached(priority: .userInitiated) {
            do {
                let record = try UserMapStorage.shared.saveMap(
                    existingRecord: existingSnapshot,
                    image: imageSnapshot,
                    title: finalTitle,
                    yearNumber: finalYear,
                    regionLabel: finalRegion,
                    roughPlacement: roughSnapshot,
                    controlPoints: pinsSnapshot,
                    fitResult: fitSnapshot,
                    calibrationProfile: profileSnapshot,
                    onProgress: { progress in
                        Task { @MainActor in
                            saveProgress = progress
                        }
                    }
                )
                await MainActor.run {
                    isSaving = false
                    isSaveSheetPresented = false
                    onSaved(record)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Hold-to-Peek Eye Button

private struct PeekHoldIconButton: UIViewRepresentable {
    let isPeeking: Bool
    let accessibilityLabel: String
    let onPressChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPressChanged: onPressChanged)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "calibration.peek"
        button.accessibilityLabel = accessibilityLabel
        button.layer.cornerRadius = 0
        button.layer.borderWidth = 1
        button.layer.borderColor = MonolithPalette.uiHairline.cgColor
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        applyState(to: button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onPressChanged = onPressChanged
        button.accessibilityLabel = accessibilityLabel
        applyState(to: button)
    }

    private func applyState(to button: UIButton) {
        let symbol = isPeeking ? "eye.slash.fill" : "eye"
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.backgroundColor = isPeeking ? MonolithPalette.uiInk : MonolithPalette.uiSurface
        button.tintColor = isPeeking ? MonolithPalette.uiCanvas : MonolithPalette.uiInk
        button.layer.borderColor = isPeeking ? MonolithPalette.uiInk.cgColor : MonolithPalette.uiHairline.cgColor
    }

    final class Coordinator: NSObject {
        var onPressChanged: (Bool) -> Void
        init(onPressChanged: @escaping (Bool) -> Void) {
            self.onPressChanged = onPressChanged
        }
        @objc func down() { onPressChanged(true) }
        @objc func up() { onPressChanged(false) }
    }
}

// MARK: - Inline Save Modal Overlay (Keyboard-Safe & No Nested Sheet Presentation)

private struct SaveCalibratedMapOverlay: View {
    @Binding var title: String
    @Binding var year: String
    @Binding var region: String
    let fitResult: CalibrationFitResult
    let pinCount: Int
    let isSaving: Bool
    let progress: Double
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case year
        case region
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture {
                    if focusedField != nil {
                        focusedField = nil
                    } else if !isSaving {
                        onCancel()
                    }
                }

            GeometryReader { proxy in
                let maxFieldsHeight = min(260, max(110, proxy.size.height - 180))

                VStack {
                    Spacer(minLength: 8)

                    VStack(spacing: 0) {
                        // Header
                        HStack(spacing: 12) {
                            Text(AppText.calibrationSaveSheetTitle)
                                .font(.headline.weight(.medium))
                                .foregroundStyle(MonolithPalette.ink)
                            Spacer()
                            if !isSaving {
                                Button {
                                    focusedField = nil
                                    onCancel()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(MonolithPalette.ink)
                                        .frame(width: 34, height: 34)
                                        .background(
                                            Rectangle()
                                                .fill(MonolithPalette.surface)
                                                .overlay(
                                                    Rectangle()
                                                        .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                        Rectangle()
                            .fill(MonolithPalette.hairline)
                            .frame(height: 1)

                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(AppText.calibrationFitSummary(
                                    mode: fitResult.mode,
                                    pinCount: pinCount,
                                    meanErrorMeters: fitResult.meanErrorMeters
                                ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(MonolithPalette.inkSecondary)

                                VStack(spacing: 12) {
                                    labeledField(
                                        label: AppText.calibrationTitleFieldLabel,
                                        text: $title,
                                        field: .title,
                                        identifier: "calibration.saveSheet.titleField"
                                    )
                                    HStack(spacing: 12) {
                                        labeledField(
                                            label: AppText.calibrationYearFieldLabel,
                                            text: $year,
                                            field: .year,
                                            identifier: "calibration.saveSheet.yearField"
                                        )
                                        .frame(maxWidth: 130)

                                        labeledField(
                                            label: AppText.calibrationRegionFieldLabel,
                                            text: $region,
                                            field: .region,
                                            identifier: "calibration.saveSheet.regionField"
                                        )
                                    }
                                }
                                .disabled(isSaving)

                                if let errorMessage, !errorMessage.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(MonolithPalette.destructive)
                                        Text(errorMessage)
                                            .font(.caption)
                                            .foregroundStyle(MonolithPalette.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        Rectangle()
                                            .fill(MonolithPalette.destructive.opacity(0.12))
                                            .overlay(
                                                Rectangle()
                                                    .strokeBorder(MonolithPalette.destructive.opacity(0.45), lineWidth: 1)
                                            )
                                    )
                                }

                                if isSaving {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ProgressView(value: progress, total: 1.0)
                                            .tint(MonolithPalette.ink)
                                        Text(AppText.calibrationBakingProgressLabel)
                                            .font(.caption)
                                            .foregroundStyle(MonolithPalette.inkMuted)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                        }
                        .frame(maxHeight: maxFieldsHeight)
                        .scrollDismissesKeyboard(.interactively)
                        .scrollBounceBehavior(.basedOnSize)

                        // Always-visible pinned Save button
                        Button {
                            focusedField = nil
                            onSave()
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(MonolithPalette.inkOnInverted)
                                }
                                Text(AppText.calibrationSaveSheetTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .tracking(0.8)
                            }
                            .foregroundStyle(MonolithPalette.inkOnInverted)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                Rectangle()
                                    .fill(MonolithPalette.ink)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .disabled(isSaving)
                        .accessibilityIdentifier("calibration.saveSheet.confirm")
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                    }
                    .frame(maxWidth: 440)
                    .background(
                        Rectangle()
                            .fill(MonolithPalette.canvas)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(MonolithPalette.hairlineStrong, lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.72), radius: 24, y: 10)
                    )
                    .padding(.horizontal, 18)

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fontDesign(.serif)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AppText.doneLabel) {
                    focusedField = nil
                }
                .foregroundStyle(MonolithPalette.ink)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func labeledField(
        label: String,
        text: Binding<String>,
        field: Field,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MonolithPalette.inkMuted)
            TextField("", text: text)
                .font(.subheadline)
                .foregroundStyle(MonolithPalette.ink)
                .submitLabel(.done)
                .focused($focusedField, equals: field)
                .onSubmit {
                    focusedField = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Rectangle()
                        .fill(MonolithPalette.surface)
                        .overlay(
                            Rectangle()
                                .strokeBorder(
                                    focusedField == field ? MonolithPalette.ink : MonolithPalette.hairlineStrong,
                                    lineWidth: 1
                                )
                        )
                )
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Map Canvas + Live Overlay + Crosshair + Direct Sheet Gestures

private final class CalibrationPinAnnotation: NSObject, MKAnnotation {
    let pinID: UUID
    let index: Int
    let badgeColor: UIColor
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(item: CalibrationPinDisplayItem) {
        self.pinID = item.id
        self.index = item.index
        self.badgeColor = item.badgeColor
        self.coordinate = item.coordinate
        super.init()
    }
}

private final class CalibrationCrosshairView: UIView {
    var reticleColor: UIColor = MonolithPalette.uiInk {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let cx = rect.midX
        let cy = rect.midY
        let boxHalf: CGFloat = 15
        let innerGap: CGFloat = 5
        let armLength: CGFloat = 26

        func drawReticle(strokeColor: UIColor, width: CGFloat) {
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)

            ctx.stroke(CGRect(
                x: cx - boxHalf,
                y: cy - boxHalf,
                width: boxHalf * 2,
                height: boxHalf * 2
            ))

            // 4 sharp arms with clean center gap
            ctx.move(to: CGPoint(x: cx - armLength, y: cy))
            ctx.addLine(to: CGPoint(x: cx - innerGap, y: cy))
            ctx.move(to: CGPoint(x: cx + innerGap, y: cy))
            ctx.addLine(to: CGPoint(x: cx + armLength, y: cy))
            ctx.move(to: CGPoint(x: cx, y: cy - armLength))
            ctx.addLine(to: CGPoint(x: cx, y: cy - innerGap))
            ctx.move(to: CGPoint(x: cx, y: cy + innerGap))
            ctx.addLine(to: CGPoint(x: cx, y: cy + armLength))
            ctx.strokePath()
        }

        // High-contrast dark halo + sharp inner reticle
        drawReticle(strokeColor: UIColor.black.withAlphaComponent(0.78), width: 3.6)
        drawReticle(strokeColor: reticleColor, width: 1.5)

        // Tiny sharp square center pip
        ctx.setFillColor(reticleColor.cgColor)
        ctx.fill(CGRect(x: cx - 1.5, y: cy - 1.5, width: 3, height: 3))
    }
}

private final class SheetHitTestGestureView: UIView {
    var shouldClaimPoint: ((CGPoint, UIEvent?) -> Bool)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return shouldClaimPoint?(point, event) ?? false
    }
}

private final class CalibrationMapViewController: UIViewController, MKMapViewDelegate, UIGestureRecognizerDelegate {
    let mapView = MKMapView()
    let overlayView = CalibrationOverlayLayerView()
    let gestureView = SheetHitTestGestureView()
    let crosshairView = CalibrationCrosshairView()

    var currentImageSize: CGSize = .zero
    var currentTransform = MapAffineTransform(a: 1, b: 0, tx: 0, c: 0, d: 1, ty: 0)
    var currentOpacity: Float = 0.58
    var showBorder = true
    var pendingSourceMapPoint: MKMapPoint?

    var onVisibleRegionChanged: ((MKMapPoint, Double) -> Void)?
    var onRoughGesture: ((Double, Double, Double, Double, MKMapPoint) -> Void)?

    private var lastCameraNonce = 0
    private var lastPinItems: [CalibrationPinDisplayItem] = []

    private var isSheetInteracting: Bool {
        let activeStates: [UIGestureRecognizer.State] = [.began, .changed]
        return activeStates.contains(panRecognizer.state)
            || activeStates.contains(pinchRecognizer.state)
            || activeStates.contains(rotationRecognizer.state)
    }

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let r = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        r.maximumNumberOfTouches = 2
        r.delegate = self
        return r
    }()

    private lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let r = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        r.delegate = self
        return r
    }()

    private lazy var rotationRecognizer: UIRotationGestureRecognizer = {
        let r = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        r.delegate = self
        return r
    }()

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        mapView.preferredConfiguration = config
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false

        overlayView.translatesAutoresizingMaskIntoConstraints = false

        gestureView.translatesAutoresizingMaskIntoConstraints = false
        gestureView.backgroundColor = .clear
        gestureView.shouldClaimPoint = { [weak self] point, event in
            self?.shouldClaimSheetTouch(at: point, event: event) ?? false
        }
        gestureView.addGestureRecognizer(panRecognizer)
        gestureView.addGestureRecognizer(pinchRecognizer)
        gestureView.addGestureRecognizer(rotationRecognizer)

        crosshairView.translatesAutoresizingMaskIntoConstraints = false
        crosshairView.isHidden = true

        view.addSubview(mapView)
        view.addSubview(overlayView)
        view.addSubview(gestureView)
        view.addSubview(crosshairView)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlayView.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: mapView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),

            gestureView.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            gestureView.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
            gestureView.topAnchor.constraint(equalTo: mapView.topAnchor),
            gestureView.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),

            crosshairView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            crosshairView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
            crosshairView.widthAnchor.constraint(equalToConstant: 64),
            crosshairView.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncOverlay(animated: false)
        reportVisibleRegion()
    }

    func applyCameraIfNeeded(_ request: CalibrationCameraRequest) {
        guard request.nonce != lastCameraNonce else { return }
        lastCameraNonce = request.nonce
        if let rect = request.mapRect {
            let padding = UIEdgeInsets(top: 120, left: 32, bottom: 200, right: 32)
            mapView.setVisibleMapRect(rect, edgePadding: padding, animated: request.animated)
        } else if let coord = request.centerCoordinate {
            let region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: request.spanMeters,
                longitudinalMeters: request.spanMeters
            )
            mapView.setRegion(region, animated: request.animated)
        }
        DispatchQueue.main.async { [weak self] in
            self?.syncOverlay(animated: false)
            self?.reportVisibleRegion()
        }
    }

    func syncOverlay(animated: Bool) {
        overlayView.update(
            on: mapView,
            transform: currentTransform,
            opacity: currentOpacity,
            showBorder: showBorder,
            isInteracting: isSheetInteracting,
            pendingSourceMapPoint: pendingSourceMapPoint,
            animated: animated
        )
    }

    private func shouldClaimSheetTouch(at point: CGPoint, event: UIEvent?) -> Bool {
        // Keep an active multi-touch gesture locked to the sheet even if a second finger drifts slightly outside.
        if isSheetInteracting
            || panRecognizer.numberOfTouches > 0
            || pinchRecognizer.numberOfTouches > 0
            || rotationRecognizer.numberOfTouches > 0 {
            return true
        }

        if let touches = event?.allTouches {
            let activeTouches = touches.filter {
                $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
            }
            if activeTouches.contains(where: { $0.view === gestureView }) {
                return true
            }
            // If the basemap already claimed an active touch, let subsequent fingers go to the basemap too.
            if activeTouches.contains(where: { $0.view != nil && $0.view !== gestureView }) {
                return false
            }
            // If two fingers land simultaneously, route by their midpoint so straddling pinches still grab the sheet.
            if activeTouches.count >= 2 {
                var sumX: CGFloat = 0
                var sumY: CGFloat = 0
                for touch in activeTouches {
                    let loc = touch.location(in: gestureView)
                    sumX += loc.x
                    sumY += loc.y
                }
                let centroid = CGPoint(
                    x: sumX / CGFloat(activeTouches.count),
                    y: sumY / CGFloat(activeTouches.count)
                )
                return isScreenPointInsideSheet(centroid)
            }
        }

        return isScreenPointInsideSheet(point)
    }

    private func isScreenPointInsideSheet(_ point: CGPoint) -> Bool {
        guard currentImageSize.width > 0, currentImageSize.height > 0,
              let projection = CalibrationOverlayLayerView.screenProjection(for: mapView) else {
            return false
        }
        let mapPoint = projection.mapPoint(for: point)
        guard let imagePoint = currentTransform.inverse(mapPoint) else { return false }

        let screenPixelsPerImagePixel = currentTransform.averageMapPointsPerPixel * projection.scaleX
        let minScreenSide = min(Double(currentImageSize.width), Double(currentImageSize.height)) * screenPixelsPerImagePixel
        let screenMargin = max(6.0, (44.0 - minScreenSide) * 0.5)
        let imageMargin = screenMargin / max(1e-6, screenPixelsPerImagePixel)

        return Double(imagePoint.x) >= -imageMargin
            && Double(imagePoint.x) <= Double(currentImageSize.width) + imageMargin
            && Double(imagePoint.y) >= -imageMargin
            && Double(imagePoint.y) <= Double(currentImageSize.height) + imageMargin
    }

    func syncPins(_ items: [CalibrationPinDisplayItem]) {
        guard items != lastPinItems else { return }
        lastPinItems = items
        let existing = mapView.annotations.compactMap { $0 as? CalibrationPinAnnotation }
        mapView.removeAnnotations(existing)
        let annotations = items.map { CalibrationPinAnnotation(item: $0) }
        mapView.addAnnotations(annotations)
    }

    private func reportVisibleRegion() {
        guard let projection = CalibrationOverlayLayerView.screenProjection(for: mapView) else { return }
        let centerScreen = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
        let centerMapPoint = projection.mapPoint(for: centerScreen)
        let visibleWidth = Double(mapView.bounds.width) * projection.mapPointsPerScreenPoint
        onVisibleRegionChanged?(centerMapPoint, visibleWidth)
    }

    // MARK: MKMapViewDelegate

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        syncOverlay(animated: false)
        reportVisibleRegion()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let pin = annotation as? CalibrationPinAnnotation else { return nil }
        let identifier = "CalibrationPinBadge"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: pin, reuseIdentifier: identifier)
        view.annotation = pin
        view.canShowCallout = false
        view.image = Self.makePinBadgeImage(index: pin.index, fillColor: pin.badgeColor)
        view.centerOffset = .zero
        return view
    }

    private static func makePinBadgeImage(index: Int, fillColor: UIColor) -> UIImage {
        let size = CGSize(width: 26, height: 26)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(x: 2, y: 2, width: 22, height: 22)
            let path = UIBezierPath(rect: rect)
            fillColor.setFill()
            path.fill()
            MonolithPalette.uiCanvas.setStroke()
            path.lineWidth = 1.8
            path.stroke()

            let text = "\(index)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: MonolithPalette.uiCanvas
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = CGRect(
                x: (size.width - textSize.width) * 0.5,
                y: (size.height - textSize.height) * 0.5,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        }
    }

    // MARK: Stage 1 Sheet Gestures

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            syncOverlay(animated: false)
        case .changed:
            guard let projection = CalibrationOverlayLayerView.screenProjection(for: mapView) else { return }
            let translation = recognizer.translation(in: gestureView)
            recognizer.setTranslation(.zero, in: gestureView)

            let deltaMapX = Double(translation.x) / projection.scaleX
            let deltaMapY = Double(translation.y) / projection.scaleY
            let focal = projection.mapPoint(for: recognizer.location(in: gestureView))
            onRoughGesture?(deltaMapX, deltaMapY, 1.0, 0.0, focal)
        case .ended, .cancelled, .failed:
            syncOverlay(animated: false)
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            syncOverlay(animated: false)
        case .changed:
            guard let projection = CalibrationOverlayLayerView.screenProjection(for: mapView) else { return }
            let scale = Double(recognizer.scale)
            recognizer.scale = 1.0
            let focal = projection.mapPoint(for: recognizer.location(in: gestureView))
            onRoughGesture?(0, 0, scale, 0.0, focal)
        case .ended, .cancelled, .failed:
            syncOverlay(animated: false)
        default:
            break
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            syncOverlay(animated: false)
        case .changed:
            guard let projection = CalibrationOverlayLayerView.screenProjection(for: mapView) else { return }
            let rotation = Double(recognizer.rotation)
            recognizer.rotation = 0.0
            let focal = projection.mapPoint(for: recognizer.location(in: gestureView))
            onRoughGesture?(0, 0, 1.0, rotation, focal)
        case .ended, .cancelled, .failed:
            syncOverlay(animated: false)
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let ours: [UIGestureRecognizer] = [panRecognizer, pinchRecognizer, rotationRecognizer]
        return ours.contains(gestureRecognizer) && ours.contains(otherGestureRecognizer)
    }
}

private struct CalibrationMapCanvas: UIViewControllerRepresentable {
    let image: UIImage
    let transform: MapAffineTransform
    let opacity: Float
    let showBorder: Bool
    let isSheetGestureEnabled: Bool
    let showCrosshair: Bool
    let crosshairColor: UIColor
    let pendingSourceMapPoint: MKMapPoint?
    let pins: [CalibrationPinDisplayItem]
    let cameraRequest: CalibrationCameraRequest
    let animateOverlay: Bool
    let onVisibleRegionChanged: (MKMapPoint, Double) -> Void
    let onRoughGesture: (Double, Double, Double, Double, MKMapPoint) -> Void
    let onConsumedOverlayAnimation: () -> Void

    func makeUIViewController(context: Context) -> CalibrationMapViewController {
        let controller = CalibrationMapViewController()
        controller.currentImageSize = image.size
        controller.overlayView.setImage(image)
        controller.onVisibleRegionChanged = onVisibleRegionChanged
        controller.onRoughGesture = onRoughGesture
        return controller
    }

    func updateUIViewController(_ controller: CalibrationMapViewController, context: Context) {
        controller.onVisibleRegionChanged = onVisibleRegionChanged
        controller.onRoughGesture = onRoughGesture
        controller.currentImageSize = image.size
        controller.overlayView.setImage(image)
        controller.currentTransform = transform
        controller.currentOpacity = opacity
        controller.showBorder = showBorder
        controller.pendingSourceMapPoint = pendingSourceMapPoint
        controller.gestureView.isUserInteractionEnabled = isSheetGestureEnabled
        controller.crosshairView.isHidden = !showCrosshair
        controller.crosshairView.reticleColor = crosshairColor

        controller.applyCameraIfNeeded(cameraRequest)
        controller.syncOverlay(animated: animateOverlay)
        controller.syncPins(pins)

        if animateOverlay {
            DispatchQueue.main.async {
                onConsumedOverlayAnimation()
            }
        }
    }
}
