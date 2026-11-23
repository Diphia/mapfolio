enum AppText {
    static let libraryLabel = "Map Collection"

    static let libraryHint = "Manage historical map layers, visibility, and opacity"

    static let locateLabel = "Current Location"

    static let locateHint = "Show and center your current location on the map"

    static let doneLabel = "Done"

    static let locationAlertTitle = "Location Access Needed"

    static let locationAlertOpenSettings = "Open Settings"

    static let locationAlertOK = "OK"

    static let locationAlertMessage = "Allow Mapfolio to access your location while using the app in Settings so your current position can be shown on the historical and modern maps."

    static func activeLayersCount(enabled: Int, total: Int) -> String {
        "\(enabled) / \(total) Active"
    }

    static func viewToggleLabel(isGridPresented: Bool) -> String {
        isGridPresented ? "Back to Gallery View" : "Switch to Overview Grid"
    }

    static let modernBasemapOnlyNotice = "Showing modern basemap only"

    static let enableAllTitle = "Enable All"

    static let enableAllAccessibilityLabel = "Enable all available layers"

    static let emptyLibraryTitle = "No Maps in Collection"

    static let emptyLibraryMessage = "Your map collection is empty. Restore the built-in historical maps to overlay and compare historical streets against the modern basemap."

    static let restoreBuiltInMapsTitle = "Restore Built-in Maps"

    static func missingLocalArchiveWarning(yearLabel: String) -> String {
        "Local map archive for \(yearLabel) not found"
    }

    static let archiveSourceTitle = "Archive Source"

    static func archiveSourceAccessibilityLabel(displayTitle: String) -> String {
        "View archive source for \(displayTitle)"
    }

    static let viewMapSheetTitle = "View Map Sheet"

    static func viewMapSheetAccessibilityLabel(displayTitle: String) -> String {
        "View \(displayTitle) map sheet"
    }

    static func viewMapSheetAccessibilityHint(regionLabel: String) -> String {
        "Return to the map and move the camera to \(regionLabel)"
    }

    static func previewAccessibilityLabel(displayTitle: String, modeTitle: String) -> String {
        "\(displayTitle) preview sheet, currently \(modeTitle)"
    }

    static func gridCardAccessibilityLabel(displayTitle: String, modeTitle: String) -> String {
        "\(displayTitle), \(modeTitle)"
    }

    static func triStateAccessibilityLabel(displayTitle: String, modeTitle: String) -> String {
        "\(displayTitle), \(modeTitle)"
    }

    static let importMapLabel = "Import Map from Photos"

    static let userMapDefaultTag = "CUSTOM"

    static let userMapDefaultTitle = "Imported Map"

    static let userMapDefaultRegion = "Photos"

    static func userMapAttribution(pinCount: Int) -> String {
        if pinCount == 0 {
            return "Imported from Photos · Rough alignment"
        } else if pinCount == 1 {
            return "Imported from Photos · 1 alignment pin"
        } else {
            return "Imported from Photos · \(pinCount) alignment pins"
        }
    }

    static let recalibrateTitle = "Recalibrate"

    static let deleteMapTitle = "Delete"

    static let deleteMapAlertTitle = "Delete Imported Map?"

    static func deleteMapAlertMessage(title: String) -> String {
        "“\(title)” and its local tiles will be permanently removed."
    }

    static let cancelLabel = "Cancel"

    static let saveLabel = "Save"

    static let backLabel = "Back"

    static let calibrationStagePlaceTitle = "1. Place"

    static func calibrationStagePinsTitle(count: Int) -> String {
        count > 0 ? "2. Pins (\(count))" : "2. Pins"
    }

    static let calibrationSearchPlaceholder = "Search city or landmark..."

    static let calibrationAdjustSheetMode = "Adjust Map"

    static let calibrationMoveBasemapMode = "Move Basemap"

    static let calibrationCenterSheetHere = "Bring Map Here"

    static let calibrationRotate90Label = "Rotate 90°"

    static let calibrationPeekHoldLabel = "Hold to peek modern map"

    static let calibrationPinsLockNotice = "Controlled by pins · Clear pins to drag freely"

    static let calibrationResetPinsTitle = "Clear Pins"

    static let calibrationAddPinTitle = "Add Alignment Pin"

    static let calibrationAddAnotherPinTitle = "Add Pin"

    static let calibrationFinishAndSaveTitle = "Done & Save"

    static let calibrationStage1Hint = "Drag, pinch & twist on the map to adjust it, or outside to move the basemap."

    static let calibrationPickSourceBanner = "Step 1/2 · Aim crosshair at a landmark on your map"

    static let calibrationPickSourceOutsideHint = "Move the crosshair onto your uploaded map"

    static let calibrationLockMapPointTitle = "Lock Map Point"

    static let calibrationPickTargetBanner = "Step 2/2 · Aim at the same spot on the modern map"

    static let calibrationMatchHereTitle = "Match Here"

    static func calibrationFitSummary(mode: CalibrationFitMode, pinCount: Int, meanErrorMeters: Double) -> String {
        switch mode {
        case .rough:
            return "Rough alignment · Add pins for higher accuracy"
        case .translation:
            return "1 pin · Position locked"
        case .similarity:
            return "\(pinCount) pins · Scale & rotation locked"
        case .affine:
            if pinCount >= 4 && meanErrorMeters >= 1 {
                return "\(pinCount) pins · Affine fit (±\(Int(meanErrorMeters.rounded())) m avg)"
            }
            return "\(pinCount) pins · Affine fit"
        }
    }

    static let calibrationSaveSheetTitle = "Save to Collection"

    static let calibrationTitleFieldLabel = "Map Title"

    static let calibrationYearFieldLabel = "Year (Optional)"

    static let calibrationRegionFieldLabel = "Place / Area (Optional)"

    static let calibrationBakingProgressLabel = "Generating local map tiles..."

    static let calibrationImportFailedTitle = "Could Not Open Photo"

    static let calibrationImportFailedMessage = "Please choose a standard image from your Photos library."

    static let calibrationSaveFailedTitle = "Could Not Save Map"

    static let calibrationGhostToggleLabel = "Toggle overlay ghost"
}
