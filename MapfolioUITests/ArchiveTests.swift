import XCTest

final class ArchiveTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-UITestingResetLibrary", "-UITestingObservePeek"]
        app.launch()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testCleanMainCanvasAndSystemToolbarTargets() throws {
        let navBar = app.navigationBars.firstMatch
        let libraryButton = navBar.buttons["archive.library"]
        let locateButton = navBar.buttons["archive.locate"]

        XCTAssertTrue(navBar.waitForExistence(timeout: 5))
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(locateButton.waitForExistence(timeout: 5))
        XCTAssertFalse(navBar.buttons["archive.peek"].exists, "Toolbar eye button must be removed.")
        XCTAssertTrue(libraryButton.isHittable)
        XCTAssertTrue(locateButton.isHittable)
        XCTAssertFalse(libraryButton.frame.intersects(locateButton.frame))
        XCTAssertLessThan(abs(libraryButton.frame.midY - locateButton.frame.midY), 1.0)
        XCTAssertGreaterThanOrEqual(libraryButton.frame.width, 35.99)
        XCTAssertGreaterThanOrEqual(libraryButton.frame.height, 35.99)
        XCTAssertGreaterThanOrEqual(locateButton.frame.width, 35.99)
        XCTAssertGreaterThanOrEqual(locateButton.frame.height, 35.99)

        XCTAssertEqual(app.sliders.count, 0, "Continuous opacity slider must not exist.")
        XCTAssertFalse(app.descendants(matching: .any)["archive.title"].exists, "Upper-left title card must be removed.")
        XCTAssertFalse(app.descendants(matching: .any)["archive.overlay"].exists, "Bottom dock toggle must be removed.")
        XCTAssertFalse(app.descendants(matching: .any)["archive.opacityMode"].exists, "Bottom opacity dock must be removed.")
        XCTAssertFalse(app.descendants(matching: .any)["archive.modernOnly"].exists, "Canvas modern-only badge must be removed.")

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let initialLon = waitForLongitude(of: map, timeout: 5) { abs($0 - 121.4698) < 0.02 }
        XCTAssertNotNil(initialLon, "Initial camera should center on 1946 Shanghai bounds.")

        let peekState = app.descendants(matching: .any)["archive.peek.state"]
        XCTAssertTrue(peekState.waitForExistence(timeout: 3))
        XCTAssertEqual(peekState.value as? String, "count:0,peeking:false")

        // Press and hold directly on the map canvas to peek the modern basemap, then release.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6)
        XCTAssertEqual(peekState.value as? String, "count:1,peeking:false")
        XCTAssertNotNil(
            waitForLongitude(of: map, timeout: 2) { abs($0 - 121.4698) < 0.02 },
            "Long-pressing the map to peek must not drift the camera."
        )

        // Normal map panning must not trigger long-press peek.
        panMap(map, from: CGVector(dx: 0.35, dy: 0.5), to: CGVector(dx: 0.65, dy: 0.55))
        XCTAssertEqual(peekState.value as? String, "count:1,peeking:false")

        attachScreenshot("Main clean portrait layers icon")
    }

    func testLibraryPerMapControlsPersistenceCameraPreservationAndExplicitFocus() throws {
        let libraryButton = app.navigationBars.buttons["archive.library"]
        let map = app.maps.firstMatch

        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForLongitude(of: map, timeout: 5) { abs($0 - 121.4698) < 0.02 })

        // Pan smoothly away from Shanghai bounds and wait for MapKit inertia to settle.
        panMap(map, from: CGVector(dx: 0.25, dy: 0.5), to: CGVector(dx: 0.75, dy: 0.65))
        guard let pannedLon = waitForSettledLongitude(of: map, timeout: 4, awayFrom: 121.4698, minimumDelta: 0.025) else {
            XCTFail("Panning should move camera away from Shanghai bounds and settle.")
            return
        }

        libraryButton.tap()

        let closeButton = app.buttons["archive.library.close"]
        let viewToggle = app.buttons["archive.library.viewToggle"]
        let preview = app.descendants(matching: .any)["archive.library.shanghai1946.preview"]
        let hidden = app.buttons["archive.library.shanghai1946.display.hidden"]
        let translucent = app.buttons["archive.library.shanghai1946.opacity.translucent"]
        let opaque = app.buttons["archive.library.shanghai1946.opacity.opaque"]
        let focusButton = app.buttons["archive.library.shanghai1946.focus"]
        let sourceLink = app.descendants(matching: .any)["archive.library.shanghai1946.source"]

        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Map Collection"].exists)
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(hidden.waitForExistence(timeout: 3))
        XCTAssertTrue(translucent.exists)
        XCTAssertTrue(opaque.exists)
        XCTAssertTrue(translucent.isSelected, "Shanghai 1946 should default to Translucent.")
        XCTAssertFalse(hidden.isSelected)
        XCTAssertFalse(opaque.isSelected)
        XCTAssertGreaterThanOrEqual(hidden.frame.height, 43.99)
        XCTAssertGreaterThanOrEqual(translucent.frame.height, 43.99)
        XCTAssertGreaterThanOrEqual(opaque.frame.height, 43.99)
        XCTAssertTrue(focusButton.exists)
        XCTAssertTrue(focusButton.isHittable)
        XCTAssertGreaterThanOrEqual(focusButton.frame.height, 43.99)
        XCTAssertTrue(sourceLink.exists)
        XCTAssertTrue(sourceLink.isHittable)
        XCTAssertGreaterThanOrEqual(sourceLink.frame.height, 43.99)

        XCTAssertFalse(app.descendants(matching: .any)["archive.library.accuracy"].exists, "Removed accuracy block must not exist.")
        attachScreenshot("Gallery default 2.5D translucent")

        // Change display mode to opaque.
        opaque.tap()
        XCTAssertTrue(opaque.isSelected)
        XCTAssertFalse(translucent.isSelected)
        XCTAssertFalse(hidden.isSelected)
        attachScreenshot("Gallery 2.5D opaque")

        // Hide the layer: surfaces subtle disabled strip while remembering opaque underneath.
        hidden.tap()
        XCTAssertTrue(hidden.isSelected)
        XCTAssertFalse(opaque.isSelected)
        let disabledState = app.descendants(matching: .any)["archive.library.disabledState"]
        let enableAllButton = app.buttons["archive.library.enableAll"]
        XCTAssertTrue(disabledState.waitForExistence(timeout: 3))
        XCTAssertTrue(enableAllButton.exists)
        XCTAssertGreaterThanOrEqual(enableAllButton.frame.height, 43.99)
        attachScreenshot("Gallery 2.5D hidden")

        // Close sheet and verify canvas stays clean AND camera did NOT jump.
        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["archive.modernOnly"].exists)
        let afterCloseLon = waitForLongitude(of: map, timeout: 3) { abs($0 - pannedLon) < 0.005 }
        XCTAssertNotNil(afterCloseLon, "Opening/closing library and toggling layer must preserve camera.")

        // Long-pressing when all overlays are hidden must be a no-op.
        let peekState = app.descendants(matching: .any)["archive.peek.state"]
        XCTAssertEqual(peekState.value as? String, "count:0,peeking:false")
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6)
        XCTAssertEqual(peekState.value as? String, "count:0,peeking:false")

        // Relaunch without reset argument to verify local persistence.
        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForLongitude(of: map, timeout: 5) { abs($0 - 121.4698) < 0.02 })

        // Pan away again and wait for settle before opening library.
        panMap(map, from: CGVector(dx: 0.75, dy: 0.5), to: CGVector(dx: 0.25, dy: 0.5))
        guard let secondPannedLon = waitForSettledLongitude(of: map, timeout: 4, awayFrom: 121.4698, minimumDelta: 0.025) else {
            XCTFail("Second pan should move camera away from Shanghai bounds and settle.")
            return
        }

        libraryButton.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(hidden.isSelected, "Hidden state must persist across relaunch.")
        XCTAssertTrue(disabledState.exists)

        // Re-enable using the disabled-state action; should restore remembered opaque mode without moving camera.
        enableAllButton.tap()
        XCTAssertTrue(disabledState.waitForNonExistence(timeout: 3))
        XCTAssertTrue(opaque.isSelected, "Remembered opaque mode must be restored when re-enabling.")

        // Toggle overview grid and return via card selection.
        XCTAssertTrue(viewToggle.exists)
        viewToggle.tap()
        let gridItem = app.buttons["archive.library.grid.shanghai1946"]
        XCTAssertTrue(gridItem.waitForExistence(timeout: 3))
        attachScreenshot("Gallery overview grid")
        gridItem.tap()
        XCTAssertTrue(focusButton.waitForExistence(timeout: 3))

        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
        XCTAssertNotNil(
            waitForLongitude(of: map, timeout: 3, matching: { abs($0 - secondPannedLon) < 0.005 }),
            "Re-enabling overlay and closing library must preserve camera."
        )

        // Explicit View Map Sheet should dismiss sheet and recenter on Shanghai bounds.
        libraryButton.tap()
        XCTAssertTrue(focusButton.waitForExistence(timeout: 5))
        focusButton.tap()
        XCTAssertTrue(focusButton.waitForNonExistence(timeout: 3))
        XCTAssertNotNil(
            waitForLongitude(of: map, timeout: 5, matching: { abs($0 - 121.4698) < 0.02 }),
            "Explicit View Map Sheet action must focus camera back on Shanghai bounds."
        )
    }

    func testMultiCityCatalogGalleryAndFocus() throws {
        let libraryButton = app.navigationBars.buttons["archive.library"]
        let map = app.maps.firstMatch

        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        libraryButton.tap()

        let viewToggle = app.buttons["archive.library.viewToggle"]
        XCTAssertTrue(viewToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 / 4 Active"].waitForExistence(timeout: 3))

        let expectations: [(id: String, targetLon: Double, mode: String)] = [
            ("beijing1930", 116.390, "opacity.translucent"),
            ("paris1811", 2.344, "opacity.translucent"),
            ("london1765", -0.093, "opacity.opaque")
        ]

        for entry in expectations {
            if !app.buttons["archive.library.grid.\(entry.id)"].exists {
                XCTAssertTrue(viewToggle.waitForExistence(timeout: 3))
                viewToggle.tap()
            }
            if entry.id == "beijing1930" {
                for expectedID in ["shanghai1946", "beijing1930", "paris1811", "london1765"] {
                    XCTAssertTrue(app.buttons["archive.library.grid.\(expectedID)"].waitForExistence(timeout: 3))
                }
                attachScreenshot("Gallery 4-map overview grid")
            }

            let gridCard = app.buttons["archive.library.grid.\(entry.id)"]
            XCTAssertTrue(gridCard.waitForExistence(timeout: 3))
            gridCard.tap()

            let hidden = app.buttons["archive.library.\(entry.id).display.hidden"]
            let targetControl = app.buttons["archive.library.\(entry.id).\(entry.mode)"]
            let focusButton = app.buttons["archive.library.\(entry.id).focus"]

            XCTAssertTrue(hidden.waitForExistence(timeout: 3))
            XCTAssertTrue(hidden.isSelected, "\(entry.id) should default to Hidden.")
            XCTAssertTrue(targetControl.exists)
            targetControl.tap()
            XCTAssertTrue(targetControl.isSelected)
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            attachScreenshot("Gallery 2.5D \(entry.id)")

            XCTAssertTrue(focusButton.exists)
            focusButton.tap()
            XCTAssertTrue(focusButton.waitForNonExistence(timeout: 3))
            XCTAssertNotNil(
                waitForLongitude(of: map, timeout: 6, matching: { abs($0 - entry.targetLon) < 0.05 }),
                "Focusing \(entry.id) must move map camera to \(entry.targetLon)."
            )

            if entry.id != expectations.last?.id {
                XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
                libraryButton.tap()
            }
        }

        // Reopening the library sheet must remember the last viewed map (london1765) instead of resetting to shanghai1946.
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()
        XCTAssertTrue(app.buttons["archive.library.london1765.focus"].waitForExistence(timeout: 3))
        let closeButton = app.buttons["archive.library.close"]
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))

        // Relaunching must also preserve the last selected map position.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()
        XCTAssertTrue(app.buttons["archive.library.london1765.focus"].waitForExistence(timeout: 5))
    }

    func testEmptyLibraryCatalogStateAndRestore() throws {
        app.terminate()
        app.launchArguments = ["-UITestingResetLibrary", "-UITestingEmptyCatalog"]
        app.launch()

        let libraryButton = app.navigationBars.buttons["archive.library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()

        let restoreButton = app.buttons["archive.library.restore"]
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5))
        XCTAssertTrue(restoreButton.isHittable)
        attachScreenshot("Library empty catalog")

        restoreButton.tap()
        let translucent = app.buttons["archive.library.shanghai1946.opacity.translucent"]
        XCTAssertTrue(translucent.waitForExistence(timeout: 3))
        XCTAssertTrue(translucent.isSelected)
    }

    func testWideLandscapeToolbarAndSheetLayout() throws {
        let navBar = app.navigationBars.firstMatch
        let libraryButton = navBar.buttons["archive.library"]
        let locateButton = navBar.buttons["archive.locate"]

        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 3))
        XCTAssertTrue(locateButton.waitForExistence(timeout: 3))
        XCTAssertFalse(navBar.buttons["archive.peek"].exists)
        XCTAssertTrue(libraryButton.isHittable)
        XCTAssertTrue(locateButton.isHittable)
        XCTAssertFalse(libraryButton.frame.intersects(locateButton.frame))
        XCTAssertLessThan(abs(libraryButton.frame.midY - locateButton.frame.midY), 1.0)
        XCTAssertGreaterThanOrEqual(libraryButton.frame.width, 35.99)
        XCTAssertGreaterThanOrEqual(libraryButton.frame.height, 35.99)
        XCTAssertGreaterThanOrEqual(locateButton.frame.width, 35.99)
        XCTAssertGreaterThanOrEqual(locateButton.frame.height, 35.99)

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(windowFrame.width, 560)
        XCTAssertTrue(windowFrame.contains(libraryButton.frame))
        XCTAssertTrue(windowFrame.contains(locateButton.frame))
        XCTAssertFalse(app.descendants(matching: .any)["archive.title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["archive.opacityMode"].exists)
        attachScreenshot("Wide landscape clean")

        libraryButton.tap()
        let closeButton = app.buttons["archive.library.close"]
        let translucent = app.buttons["archive.library.shanghai1946.opacity.translucent"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(translucent.waitForExistence(timeout: 3))
        attachScreenshot("Wide landscape library gallery")

        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
    }

    func testAccessibilityLargeTextLayout() throws {
        app.terminate()
        app.launchArguments = ["-UITestingResetLibrary", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityLarge"]
        app.launch()

        let libraryButton = app.navigationBars.buttons["archive.library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()

        let focusButton = app.buttons["archive.library.shanghai1946.focus"]
        let sourceLink = app.descendants(matching: .any)["archive.library.shanghai1946.source"]
        let hidden = app.buttons["archive.library.shanghai1946.display.hidden"]
        let translucent = app.buttons["archive.library.shanghai1946.opacity.translucent"]
        let opaque = app.buttons["archive.library.shanghai1946.opacity.opaque"]

        XCTAssertTrue(focusButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceLink.exists)
        XCTAssertTrue(hidden.exists)
        XCTAssertTrue(translucent.exists)
        XCTAssertTrue(opaque.exists)
        XCTAssertFalse(focusButton.frame.intersects(sourceLink.frame))
        XCTAssertFalse(translucent.frame.intersects(opaque.frame))
        XCTAssertFalse(hidden.frame.intersects(translucent.frame))
        attachScreenshot("Library accessibility large")
    }

    func testImportTwoStageCalibrationPersistenceRecalibrateAndDelete() throws {
        app.terminate()
        app.launchArguments = ["-UITestingResetLibrary", "-UITestingEnableSampleImport"]
        app.launch()

        let libraryButton = app.navigationBars.buttons["archive.library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()

        let importButton = app.buttons["archive.library.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(importButton.isHittable)
        importButton.tap()

        // Stage 1: Direct Rough Placement (no mode switcher: drag inside moves sheet, outside moves basemap)
        let stagePlace = app.buttons["calibration.stage.place"]
        let stagePins = app.buttons["calibration.stage.pins"]
        let rotateButton = app.buttons["calibration.rotate90"]
        let centerHereButton = app.buttons["calibration.centerHere"]
        let nextPinsButton = app.buttons["calibration.nextPins"]
        let earlySaveButton = app.buttons["calibration.earlySave"]

        XCTAssertTrue(stagePlace.waitForExistence(timeout: 5))
        XCTAssertTrue(stagePlace.isSelected)
        XCTAssertTrue(stagePins.exists)
        XCTAssertFalse(app.buttons["calibration.save"].exists, "Redundant top-right Save button must be removed.")
        XCTAssertFalse(app.buttons["calibration.mode.adjust"].exists, "Stage 1 mode toggle must be removed.")
        XCTAssertFalse(app.buttons["calibration.mode.basemap"].exists, "Stage 1 mode toggle must be removed.")
        XCTAssertTrue(rotateButton.exists)
        XCTAssertTrue(centerHereButton.exists)
        XCTAssertTrue(nextPinsButton.exists)
        XCTAssertTrue(earlySaveButton.exists)
        XCTAssertGreaterThan(nextPinsButton.frame.width, earlySaveButton.frame.width)
        attachScreenshot("Calibration Stage 1 Place")

        let canvas = app.maps.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        guard let beforeDragLon = waitForLongitude(of: canvas, timeout: 5, matching: { abs($0 - 121.482) < 0.05 }) else {
            XCTFail("Calibration map should initialize near EXIF coordinate.")
            return
        }

        // Drag inside the historical map sheet -> should move sheet only, leaving basemap longitude unchanged.
        panMap(canvas, from: CGVector(dx: 0.48, dy: 0.48), to: CGVector(dx: 0.56, dy: 0.52))
        XCTAssertNotNil(
            waitForLongitude(of: canvas, timeout: 2, matching: { abs($0 - beforeDragLon) < 0.002 }),
            "Dragging inside the uploaded map must move the sheet without panning the basemap."
        )

        // Drag outside the historical map sheet (upper region above sheet) -> should pan the basemap directly.
        panMap(canvas, from: CGVector(dx: 0.20, dy: 0.25), to: CGVector(dx: 0.80, dy: 0.25))
        XCTAssertNotNil(
            waitForSettledLongitude(of: canvas, timeout: 4, awayFrom: beforeDragLon, minimumDelta: 0.005),
            "Dragging outside the uploaded map must pan the modern basemap directly."
        )

        rotateButton.tap()
        centerHereButton.tap()

        // Stage 2: Advance via the bottom Next: Add Pins button into Stage 2 browsing mode
        nextPinsButton.tap()
        let addPinButton = app.buttons["calibration.addPin"]
        XCTAssertTrue(addPinButton.waitForExistence(timeout: 3))
        XCTAssertTrue(stagePins.isSelected)
        XCTAssertFalse(app.buttons["calibration.lockSource"].exists, "Advancing from Stage 1 must land in Stage 2 browsing mode.")
        XCTAssertFalse(app.buttons["calibration.finishSave"].exists, "Done & Save must not appear before 3 pins.")
        XCTAssertTrue(earlySaveButton.exists)
        XCTAssertGreaterThan(addPinButton.frame.width, earlySaveButton.frame.width)
        attachScreenshot("Calibration Stage 2 Pins idle")

        let pinDrags: [(panBeforeLock: (CGVector, CGVector)?, panBeforeMatch: (CGVector, CGVector))] = [
            (nil, (CGVector(dx: 0.50, dy: 0.50), CGVector(dx: 0.53, dy: 0.51))),
            ((CGVector(dx: 0.56, dy: 0.50), CGVector(dx: 0.44, dy: 0.50)), (CGVector(dx: 0.50, dy: 0.50), CGVector(dx: 0.52, dy: 0.49))),
            ((CGVector(dx: 0.50, dy: 0.58), CGVector(dx: 0.50, dy: 0.42)), (CGVector(dx: 0.50, dy: 0.50), CGVector(dx: 0.49, dy: 0.52)))
        ]

        for (idx, step) in pinDrags.enumerated() {
            XCTAssertTrue(addPinButton.waitForExistence(timeout: 3))
            addPinButton.tap()

            if let moveToLandmark = step.panBeforeLock {
                panMap(canvas, from: moveToLandmark.0, to: moveToLandmark.1)
            }

            let lockSource = app.buttons["calibration.lockSource"]
            XCTAssertTrue(lockSource.waitForExistence(timeout: 3))
            XCTAssertTrue(lockSource.isEnabled, "Crosshair should be inside uploaded map for pin \(idx + 1).")
            if idx == 0 {
                attachScreenshot("Calibration Stage 2 Pick Source")
            }
            lockSource.tap()

            let matchTarget = app.buttons["calibration.matchTarget"]
            XCTAssertTrue(matchTarget.waitForExistence(timeout: 3))
            panMap(canvas, from: step.panBeforeMatch.0, to: step.panBeforeMatch.1)
            if idx == 0 {
                attachScreenshot("Calibration Stage 2 Pick Target")
            }
            matchTarget.tap()

            if idx < 2 {
                XCTAssertTrue(addPinButton.waitForExistence(timeout: 3))
                XCTAssertTrue(earlySaveButton.exists)
                XCTAssertFalse(app.buttons["calibration.finishSave"].exists, "Done & Save must stay hidden until 3 pins are placed.")
                XCTAssertGreaterThan(addPinButton.frame.width, earlySaveButton.frame.width)
            }

            if idx == 0 {
                // Verify early Save warns that at least 3 pins are recommended before allowing save.
                earlySaveButton.tap()
                let fewPinsAlert = app.alerts["At Least 3 Pins Recommended"]
                XCTAssertTrue(fewPinsAlert.waitForExistence(timeout: 3))
                XCTAssertTrue(fewPinsAlert.buttons["Save Anyway"].exists)
                let addMorePins = fewPinsAlert.buttons["Add More Pins"]
                XCTAssertTrue(addMorePins.exists)
                addMorePins.tap()
                XCTAssertTrue(fewPinsAlert.waitForNonExistence(timeout: 3))
                XCTAssertFalse(app.textFields["calibration.saveSheet.titleField"].exists)
            }
        }

        XCTAssertTrue(app.buttons["calibration.pin.3.delete"].waitForExistence(timeout: 3))
        let finishSaveButton = app.buttons["calibration.finishSave"]
        XCTAssertTrue(finishSaveButton.waitForExistence(timeout: 3))
        XCTAssertFalse(earlySaveButton.exists, "Secondary early Save button must give way to Done & Save at 3+ pins.")
        XCTAssertGreaterThan(finishSaveButton.frame.width, addPinButton.frame.width)
        attachScreenshot("Calibration Stage 2 Three Pins")

        // Save calibrated map via the Stage 2 Done & Save button (no fewer-than-3-pins warning)
        finishSaveButton.tap()
        XCTAssertFalse(app.alerts["At Least 3 Pins Recommended"].exists)
        let titleField = app.textFields["calibration.saveSheet.titleField"]
        let confirmSave = app.buttons["calibration.saveSheet.confirm"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        attachScreenshot("Calibration Save Overlay")
        titleField.tap()
        if let existing = titleField.value as? String, !existing.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
            titleField.typeText(deleteString)
        }
        titleField.typeText("Sample Park Plan")
        confirmSave.tap()

        // Should return to gallery with 5 maps total and new map active & selected
        XCTAssertTrue(app.staticTexts["2 / 5 Active"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Sample Park Plan"].waitForExistence(timeout: 5))
        attachScreenshot("Gallery With Imported Map")

        // Relaunch without reset to confirm persistence of user map + tiles
        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()
        XCTAssertTrue(app.staticTexts["2 / 5 Active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample Park Plan"].waitForExistence(timeout: 5))

        // Open Recalibrate and verify the 3 control points are preserved
        let recalibrateButton = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.recalibrate'")).firstMatch
        XCTAssertTrue(recalibrateButton.waitForExistence(timeout: 5))
        recalibrateButton.tap()
        XCTAssertTrue(app.buttons["calibration.pin.3.delete"].waitForExistence(timeout: 5))
        app.buttons["calibration.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sample Park Plan"].waitForExistence(timeout: 5))

        // Delete the user map and verify clean return to 4 built-in maps
        let deleteButton = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.delete'")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()
        let confirmDelete = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.tap()

        XCTAssertTrue(app.staticTexts["1 / 4 Active"].waitForExistence(timeout: 5))
    }

    func testEarlySaveWithFewPinsWarnsAndAllowsSavingAnyway() throws {
        app.terminate()
        app.launchArguments = ["-UITestingResetLibrary", "-UITestingEnableSampleImport"]
        app.launch()

        let libraryButton = app.navigationBars.buttons["archive.library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5))
        libraryButton.tap()

        let importButton = app.buttons["archive.library.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        let earlySaveButton = app.buttons["calibration.earlySave"]
        XCTAssertTrue(earlySaveButton.waitForExistence(timeout: 5))

        // Early Save from Stage 1 (0 pins) warns and "Add Pins" routes to Stage 2 browsing.
        earlySaveButton.tap()
        let alert = app.alerts["At Least 3 Pins Recommended"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let addPinsChoice = alert.buttons["Add Pins"]
        XCTAssertTrue(addPinsChoice.exists)
        addPinsChoice.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["calibration.stage.pins"].isSelected)
        XCTAssertTrue(app.buttons["calibration.addPin"].waitForExistence(timeout: 3))

        // Choosing "Save Anyway" proceeds to the Save overlay.
        earlySaveButton.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let saveAnywayChoice = alert.buttons["Save Anyway"]
        XCTAssertTrue(saveAnywayChoice.exists)
        saveAnywayChoice.tap()
        XCTAssertTrue(app.textFields["calibration.saveSheet.titleField"].waitForExistence(timeout: 5))
    }

    private func panMap(_ map: XCUIElement, from start: CGVector, to end: CGVector) {
        let startCoordinate = map.coordinate(withNormalizedOffset: start)
        let endCoordinate = map.coordinate(withNormalizedOffset: end)
        startCoordinate.press(forDuration: 0.05, thenDragTo: endCoordinate, withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    private func waitForSettledLongitude(
        of map: XCUIElement,
        timeout: TimeInterval,
        awayFrom referenceLon: Double,
        minimumDelta: Double
    ) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousLon: Double?
        while Date() < deadline {
            if let value = map.value as? String, let currentLon = parseLongitude(from: value) {
                if let prev = previousLon,
                   abs(currentLon - prev) < 0.0005,
                   abs(currentLon - referenceLon) >= minimumDelta {
                    return currentLon
                }
                previousLon = currentLon
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if let value = map.value as? String,
           let currentLon = parseLongitude(from: value),
           abs(currentLon - referenceLon) >= minimumDelta {
            return currentLon
        }
        return nil
    }

    private func waitForLongitude(
        of map: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (Double) -> Bool
    ) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = map.value as? String, let lon = parseLongitude(from: value), predicate(lon) {
                return lon
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if let value = map.value as? String, let lon = parseLongitude(from: value), predicate(lon) {
            return lon
        }
        return nil
    }

    private func parseLongitude(from text: String) -> Double? {
        guard let range = text.range(of: "\"lon\":") else { return nil }
        let suffix = text[range.upperBound...]
        let number = suffix.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(number)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
