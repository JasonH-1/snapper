import XCTest

/// Scripts for the clips in the Snapper Guide: each test uses one feature
/// the way a person would, between the "DEMO START" and "DEMO END" marks.
/// `scripts/record-guide-demo.sh <test> <topic>` records the Simulator while
/// one runs and keeps only that part. Not part of the Snapper scheme or CI.
///
/// Each script also directs the clip: `focus` eases the camera in on the
/// controls being used, `wide` pulls back to the whole phone, and `hold`
/// keeps a pause at full length (other pauses are shortened). After the
/// clip, each script puts back what it changed, so they can run in any order.
///
/// The scripts expect the Simulator's Library as `scripts/seed-guide-library.sh`
/// leaves it (photo 0, a birthday cake; photo 5, a street at night, unedited),
/// no personal presets, and the camera options as `testPrepareCamera` leaves
/// them. The Simulator has no camera: the preview is a demo photo that still
/// shows exposure, white balance and focus changes. Every photo in the clips
/// is free to use, with no credit or model release needed.
final class GuideDemoTests: XCTestCase {
    /// Photos in the Simulator's Library when no demo is running.
    static let libraryCount = 12

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Setup

    /// Not a clip: timer off, grid and level off, exposure at 0, the Blue Hour look.
    @MainActor
    func testPrepareCamera() {
        let app = launch()
        tap(button("Camera options", in: app))
        while !button("Timer Off", in: app).exists { tap(buttonStarting("Timer", in: app)) }
        for option in ["Grid", "Level"] where button(option, in: app).isSelected { tap(button(option, in: app)) }
        tap(button("Exposure", in: app))
        if button("Reset exposure", in: app).isEnabled { tap(button("Reset exposure", in: app)) }
        tap(button("Hide camera options", in: app))
        chooseLook("Blue Hour", in: app)
    }

    /// Not a clip: undoes what a demo that stopped part-way may have left:
    /// edits on the photos the demos use, the demo preset and favourite.
    @MainActor
    func testRestoreState() {
        let app = launch()
        tap(button("Library", in: app))
        // A photo taken by a demo that stopped early.
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' photos · '")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        if let photos = Int(count.label.prefix { $0.isNumber }), photos > Self.libraryCount {
            tap(button("Select", in: app))
            for index in 0..<(photos - Self.libraryCount) { tap(photo(index, in: app)) }
            tap(button("Delete", in: app))
            confirm("Delete", in: app)
            wait(1)
        }
        for index in [0, 4, 5] {
            tap(photo(index, in: app))
            XCTAssertTrue(editorPhoto(in: app).waitForExistence(timeout: 5))
            wait(1)
            deleteAllVersions(in: app)
            // Photo 4 keeps its Midnight look; the demos edit 0 and 5.
            if index != 4, button("Reset", in: app).isEnabled { resetEdits(app) }
            tap(button("Back", in: app))
        }
        tap(button("Back to camera", in: app))
        tap(buttonStarting("My styles", in: app))
        if button("Manage Night Walk", in: app).waitForExistence(timeout: 2) {
            tap(button("Manage Night Walk", in: app))
            tap(button("Delete", in: app))
            confirm("Delete", in: app)
        }
        tap(button("Done", in: app))
        tap(buttonStarting("Browse looks", in: app))
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Afterglow")
        if button("Remove Afterglow from favorites", in: app).waitForExistence(timeout: 2) {
            tap(button("Remove Afterglow from favorites", in: app))
        }
        search.buttons["Clear text"].tap()
        search.typeText("Blue Hour")
        tap(button("Blue Hour", in: app))
    }

    // MARK: - Getting started

    /// guide-first-photo: choose a free look, take a photo, fine-tune it and save.
    @MainActor
    func testFirstPhoto() {
        let app = launch()
        let dial = buttonStarting("Browse looks", in: app)
        start(app)
        hold(0.4)
        focus(dial, padding: 50)
        tap(dial)
        wide()
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Boardwalk")
        hold(0.4)
        tap(button("Boardwalk", in: app))
        hold(0.6)
        let shutter = button("Take photo", in: app)
        focus(shutter, button("Library", in: app), padding: 60)
        tap(shutter)
        hold(0.6)
        tap(button("Library", in: app))
        wide()
        tap(photo(0, in: app))
        let picture = editorPhoto(in: app)
        let strength = slider("Strength", in: app)
        XCTAssertTrue(strength.waitForExistence(timeout: 5))
        focus(picture, strength)
        dragTrack(strength, from: 1, to: 0.6)
        hold(0.3)
        focus(button("Share", in: app), button("Export Options", in: app), padding: 60)
        tap(saveButton(in: app))
        hold(1.2)
        wide()
        hold(0.3)
        end()

        wait(1)
        tap(button("Back", in: app))
        tap(button("Select", in: app))
        tap(photo(0, in: app))
        tap(button("Delete", in: app))
        confirm("Delete", in: app)
        tap(button("Back to camera", in: app))
        chooseLook("Blue Hour", in: app)
    }

    // MARK: - Camera

    /// guide-focus: tap to focus, set exposure, then lock focus and exposure.
    @MainActor
    func testFocus() {
        let app = launch()
        let preview = app.otherElements["Camera preview"]
        start(app)
        hold(0.4)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.38)).tap()
        hold(1.0)
        tap(button("Camera options", in: app))
        let exposure = app.sliders["Exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 3))
        focus(preview, padding: 0)
        slide(exposure, to: 0.8)
        hold(0.6)
        slide(exposure, to: 0.3)
        hold(0.6)
        tap(button("Reset exposure", in: app))
        hold(0.5)
        tap(buttonStarting("AE/AF", in: app))
        hold(0.9)
        tap(buttonStarting("AE/AF", in: app))
        hold(0.4)
        tap(button("Hide camera options", in: app))
        wide()
        hold(0.3)
        end()
    }

    /// guide-composition: grid, level, ratio, and a self-timer you can cancel.
    @MainActor
    func testComposition() {
        let app = launch()
        let preview = app.otherElements["Camera preview"]
        start(app)
        hold(0.4)
        tap(button("Camera options", in: app))
        focus(preview, padding: 0)
        tap(button("Grid", in: app))
        hold(0.6)
        tap(button("Level", in: app))
        hold(0.6)
        tap(button("Aspect Ratio", in: app))
        tap(button("1:1", in: app))
        hold(0.9)
        tap(button("4:3", in: app))
        hold(0.4)
        // Off, 3s, 10s: the long timer leaves time to cancel.
        tap(buttonStarting("Timer", in: app))
        hold(0.3)
        tap(buttonStarting("Timer", in: app))
        hold(0.6)
        tap(button("Hide camera options", in: app))
        wide()
        let shutter = button("Take photo", in: app)
        tap(shutter)
        hold(1.8)
        tap(button("Cancel timer", in: app))
        hold(0.6)
        end()

        tap(button("Camera options", in: app))
        tap(button("Grid", in: app))
        tap(button("Level", in: app))
        while !button("Timer Off", in: app).exists { tap(buttonStarting("Timer", in: app)) }
        tap(button("Exposure", in: app))
        tap(button("Hide camera options", in: app))
    }

    /// guide-white-balance: step through the presets and back to Auto.
    @MainActor
    func testWhiteBalance() {
        let app = launch()
        let preview = app.otherElements["Camera preview"]
        start(app)
        hold(0.4)
        tap(button("Camera options", in: app))
        tap(button("White Balance", in: app))
        focus(preview, padding: 0)
        for preset in ["Daylight", "Cloudy", "Tungsten", "Fluorescent", "Auto"] {
            tap(button(preset, in: app))
            hold(0.8)
        }
        tap(button("Hide camera options", in: app))
        wide()
        hold(0.3)
        end()

        tap(button("Camera options", in: app))
        tap(button("Exposure", in: app))
        tap(button("Hide camera options", in: app))
    }

    /// guide-manual: manual focus distance, then ISO and shutter speed.
    @MainActor
    func testManual() {
        let app = launch()
        let preview = app.otherElements["Camera preview"]
        start(app)
        hold(0.4)
        tap(button("Camera options", in: app))
        tap(button("Focus", in: app))
        focus(preview, padding: 0)
        tap(button("Manual", in: app))
        let distance = app.sliders["Focus distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 3))
        slide(distance, to: 0.05)
        hold(0.6)
        slide(distance, to: 1)
        hold(0.3)
        tap(button("Auto", in: app))
        tap(button("ISO & Shutter", in: app))
        tap(button("Manual", in: app))
        let iso = app.sliders["ISO"]
        XCTAssertTrue(iso.waitForExistence(timeout: 3))
        slide(iso, to: 0.75)
        hold(0.5)
        slide(app.sliders["Shutter speed"], to: 0.25)
        hold(0.6)
        tap(button("Auto", in: app))
        hold(0.4)
        tap(button("Hide camera options", in: app))
        wide()
        hold(0.3)
        end()

        tap(button("Camera options", in: app))
        tap(button("Exposure", in: app))
        tap(button("Hide camera options", in: app))
    }

    // MARK: - Looks & styles

    /// guide-looks: filter, search by mood, star a favourite and shoot with it.
    @MainActor
    func testLooks() {
        let app = launch()
        let dial = buttonStarting("Browse looks", in: app)
        start(app)
        hold(0.4)
        focus(dial, padding: 50)
        tap(dial)
        wide()
        tap(button("Free", in: app))
        hold(0.6)
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("dusk")
        hold(0.6)
        tap(button("Add Afterglow to favorites", in: app))
        hold(0.6)
        tap(button("Afterglow", in: app))
        hold(0.8)
        focus(dial, padding: 40)
        hold(0.4)
        wide()
        hold(0.3)
        end()

        tap(dial)
        let again = app.searchFields.firstMatch
        tap(again)
        again.typeText("Afterglow")
        tap(button("Remove Afterglow from favorites", in: app))
        tap(button("All Looks", in: app))
        again.buttons["Clear text"].tap()
        again.typeText("Blue Hour")
        tap(button("Blue Hour", in: app))
    }

    /// guide-styles: save an edit as a preset, then shoot with it.
    @MainActor
    func testStyles() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        focus(picture, button("Presets", in: app), slider("Strength", in: app))
        pickLook("Boardwalk", in: app)
        hold(0.5)
        tap(button("Presets", in: app))
        let name = app.textFields["Preset name"]
        tap(name)
        name.typeText("Night Walk")
        tap(button("Save Preset", in: app))
        hold(0.9)
        tap(button("Done", in: app))
        tap(button("Back", in: app))
        tap(button("Back to camera", in: app))
        tap(buttonStarting("My styles", in: app))
        hold(0.6)
        tap(buttonStarting("Night Walk", in: app))
        hold(0.9)
        end()

        deletePreset("Night Walk", in: app)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        resetEdits(app)
        tap(button("Back", in: app))
        tap(button("Back to camera", in: app))
        chooseLook("Blue Hour", in: app)
    }

    /// guide-style-sharing: share a preset file and a style card, then import.
    @MainActor
    func testStyleSharing() {
        let app = launch()
        // Not in the clip: a preset to share.
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        XCTAssertTrue(editorPhoto(in: app).waitForExistence(timeout: 5))
        pickLook("Boardwalk", in: app)
        tap(button("Presets", in: app))
        let name = app.textFields["Preset name"]
        tap(name)
        name.typeText("Night Walk")
        tap(button("Save Preset", in: app))
        tap(button("Done", in: app))
        resetEdits(app)
        tap(button("Back", in: app))
        tap(button("Back to camera", in: app))

        start(app)
        hold(0.4)
        focus(buttonStarting("My styles", in: app), padding: 50)
        tap(buttonStarting("My styles", in: app))
        wide()
        tap(button("Manage Night Walk", in: app))
        tap(button("Share Preset File", in: app))
        hold(1.4)
        closeShareSheet(in: app)
        tap(button("Manage Night Walk", in: app))
        tap(button("Share Style Card", in: app))
        hold(1.4)
        closeShareSheet(in: app)
        tap(button("Import Preset File", in: app))
        hold(1.2)
        tap(button("Cancel", in: app))
        hold(0.4)
        end()

        tap(button("Done", in: app))
        deletePreset("Night Walk", in: app)
    }

    /// guide-collections: use a curated recipe on a photo.
    @MainActor
    func testCollections() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        focus(button("Collections", in: app), padding: 70)
        tap(button("Collections", in: app))
        wide()
        hold(0.6)
        scroll(app, by: 460)
        hold(0.5)
        tap(button("Use Neon Walk", in: app))
        hold(0.4)
        focus(picture, padding: 0)
        hold(0.6)
        app.buttons["Compare with original"].tap()
        hold(0.9)
        app.buttons["Compare with original"].tap()
        hold(0.5)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    // MARK: - Editing

    /// guide-adjust: brightness and contrast, compare, undo and redo.
    @MainActor
    func testAdjust() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Adjust", in: app))
        let brightness = app.otherElements["Brightness"]
        XCTAssertTrue(brightness.waitForExistence(timeout: 3))
        focus(picture, brightness)
        ruler(brightness, by: 70)
        hold(0.4)
        tap(button("Contrast", in: app))
        ruler(app.otherElements["Contrast"], by: 55)
        hold(0.4)
        focus(picture, padding: 0)
        picture.press(forDuration: 1.3)
        hold(0.3)
        focus(button("Undo", in: app), picture, padding: 0)
        tap(button("Undo", in: app))
        hold(0.7)
        tap(button("Redo", in: app))
        hold(0.6)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-crop: square crop, straighten, rotate and flip.
    @MainActor
    func testCrop() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        XCTAssertTrue(editorPhoto(in: app).waitForExistence(timeout: 5))
        tap(button("Crop", in: app))
        let box = app.otherElements["Crop box"]
        XCTAssertTrue(box.waitForExistence(timeout: 3))
        focus(box, button("Flip horizontally", in: app))
        tap(button("1:1", in: app))
        hold(0.6)
        ruler(app.otherElements["Straighten"], by: 40)
        hold(0.5)
        tap(button("Rotate 90 degrees", in: app))
        hold(0.7)
        tap(button("Flip horizontally", in: app))
        hold(0.7)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-finish: a frame, a layout and the date stamp.
    @MainActor
    func testFinish() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Finish", in: app))
        let remove = button("Remove All Finishing", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        focus(picture, remove)
        tap(buttonStarting("Frame", in: app))
        tap(button("Cream", in: app))
        hold(0.8)
        tap(buttonStarting("Export layout", in: app))
        tap(button("Post 4:5", in: app))
        hold(0.8)
        tap(app.switches["Date stamp"])
        hold(1.0)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-film-effects: highlights, shadows and bloom on a night photo.
    @MainActor
    func testFilmEffects() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Adjust", in: app))
        let brightness = app.otherElements["Brightness"]
        XCTAssertTrue(brightness.waitForExistence(timeout: 3))
        focus(picture, brightness)
        // Scroll the tool row to the tone and film tools.
        let row = button("Saturation", in: app)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: -4, dy: 0.5)),
                   withVelocity: XCUIGestureVelocity(rawValue: 600), thenHoldForDuration: 0.2)
        hold(0.3)
        tap(button("Highlights", in: app))
        ruler(app.otherElements["Highlights"], by: -60)
        hold(0.3)
        tap(button("Shadows", in: app))
        ruler(app.otherElements["Shadows"], by: 60)
        hold(0.3)
        tap(button("Bloom", in: app))
        ruler(app.otherElements["Bloom"], by: 90)
        hold(0.5)
        focus(picture, padding: 0)
        picture.press(forDuration: 1.2)
        hold(0.5)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-selective: paint the cake and its candles, then brighten them.
    @MainActor
    func testSelective() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(0, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Selective", in: app))
        // The Simulator can't find subjects, so the selection is painted.
        let paint = button("Paint Area", in: app)
        XCTAssertTrue(paint.waitForExistence(timeout: 15))
        focus(picture, paint)
        tap(paint)
        hold(0.4)
        focus(picture, padding: 0)
        for (from, to) in [(CGVector(dx: 0.47, dy: 0.45), CGVector(dx: 0.63, dy: 0.45)),
                           (CGVector(dx: 0.45, dy: 0.56), CGVector(dx: 0.66, dy: 0.56)),
                           (CGVector(dx: 0.42, dy: 0.67), CGVector(dx: 0.68, dy: 0.67)),
                           (CGVector(dx: 0.4, dy: 0.78), CGVector(dx: 0.68, dy: 0.78)),
                           (CGVector(dx: 0.42, dy: 0.87), CGVector(dx: 0.66, dy: 0.87))] {
            stroke(on: picture, from: from, to: to)
        }
        hold(0.4)
        tap(app.segmentedControls.buttons["Adjust"])
        let brightness = slider("Brightness", in: app)
        XCTAssertTrue(brightness.waitForExistence(timeout: 3))
        focus(picture, brightness)
        tap(app.segmentedControls.buttons["Subject"])
        drag(brightness, from: 0, to: 0.5)
        hold(0.5)
        tap(button("Show Selection", in: app))
        hold(1.0)
        tap(button("Show Selection", in: app))
        hold(0.5)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-curves: a lifted mid-tone point, then a touch of blue in the shadows.
    @MainActor
    func testCurves() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Curves", in: app))
        let curve = app.otherElements["RGB curve"]
        XCTAssertTrue(curve.waitForExistence(timeout: 3))
        focus(picture, curve)
        curve.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        hold(0.4)
        stroke(on: curve, from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.5, dy: 0.32), velocity: 60)
        hold(0.6)
        tap(button("Blue curve", in: app))
        let blue = app.otherElements["Blue curve"]
        hold(0.3)
        blue.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
        hold(0.3)
        stroke(on: blue, from: CGVector(dx: 0.25, dy: 0.75), to: CGVector(dx: 0.25, dy: 0.62), velocity: 50)
        hold(0.8)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-split-toning: warm highlights, cool shadows, then the balance.
    @MainActor
    func testSplitToning() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        tap(button("Color", in: app))
        tap(button("Split Toning", in: app))
        let amounts = app.otherElements.matching(identifier: "Amount")
        let balance = slider("Balance", in: app)
        XCTAssertTrue(balance.waitForExistence(timeout: 3))
        focus(picture, balance)
        dragTrack(amounts.element(boundBy: 0), from: 0, to: 0.6)
        hold(0.3)
        dragTrack(amounts.element(boundBy: 1), from: 0, to: 0.6)
        hold(0.3)
        drag(balance, from: 0, to: 0.45)
        hold(0.6)
        wide()
        hold(0.3)
        end()

        wait(1)
        resetEdits(app)
        tap(button("Color Mixer", in: app))
    }

    /// guide-versions: keep an edit as a version, start another from the
    /// original, and switch between them.
    @MainActor
    func testVersions() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        focus(picture, slider("Strength", in: app))
        pickLook("Boardwalk", in: app)
        hold(0.5)
        tap(button("Versions", in: app))
        wide()
        tap(button("Save Current Edit as Version", in: app))
        hold(0.5)
        tap(app.alerts.buttons["Save"])
        hold(0.6)
        tap(button("New Version from Original", in: app))
        hold(0.5)
        tap(app.alerts.buttons["Save"])
        tap(button("Adjust", in: app))
        let brightness = app.otherElements["Brightness"]
        XCTAssertTrue(brightness.waitForExistence(timeout: 3))
        focus(picture, brightness)
        ruler(brightness, by: 90)
        hold(0.5)
        tap(button("Versions", in: app))
        wide()
        hold(0.5)
        let actions = ["Save Current Edit as Version", "Duplicate This Version", "New Version from Original",
                       "Save All Versions to Photos"]
        tap(app.collectionViews.buttons.matching(NSPredicate(
            format: "NOT (label CONTAINS 'Showing') AND NOT (label BEGINSWITH 'Original') AND NOT (label IN %@)", actions)).firstMatch)
        hold(0.8)
        if button("Done", in: app).exists { tap(button("Done", in: app)) }
        hold(0.6)
        end()

        wait(1)
        if button("Done", in: app).exists { tap(button("Done", in: app)) }
        deleteAllVersions(in: app)
        resetEdits(app)
    }

    // MARK: - Library

    /// guide-library: filters, selecting photos, and the import picker.
    @MainActor
    func testLibrary() {
        let app = launch()
        start(app)
        hold(0.4)
        focus(button("Library", in: app), padding: 110)
        tap(button("Library", in: app))
        wide()
        focus(CGRect(x: 0, y: 60, width: 402, height: 560))
        tap(button("Imported", in: app))
        hold(0.6)
        tap(button("Edited", in: app))
        hold(0.6)
        tap(button("All", in: app))
        hold(0.4)
        wide()
        tap(button("Select", in: app))
        tap(photo(5, in: app))
        tap(photo(6, in: app))
        hold(0.6)
        tap(button("Cancel", in: app))
        hold(0.3)
        focus(button("Import photos", in: app), padding: 80)
        tap(button("Import photos", in: app))
        wide()
        hold(1.2)
        tap(button("Cancel", in: app))
        hold(0.4)
        end()
    }

    /// guide-batch: give three photos one look, then undo the batch.
    @MainActor
    func testBatch() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        focus(button("Style a Set", in: app), padding: 60)
        tap(button("Style a Set", in: app))
        wide()
        for index in 5...7 { tap(photo(index, in: app)) }
        hold(0.4)
        tap(button("Style", in: app))
        tap(button("Apply a Look", in: app))
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Boardwalk")
        hold(0.4)
        tap(button("Boardwalk", in: app))
        hold(1.4)
        tap(button("Undo Last Batch", in: app))
        hold(0.9)
        end()
    }

    // MARK: - Saving & sharing

    /// guide-saving: save an edited copy to Photos, then share one.
    @MainActor
    func testSaving() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        let picture = editorPhoto(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        let strength = slider("Strength", in: app)
        focus(picture, strength)
        pickLook("Boardwalk", in: app)
        hold(0.4)
        // A strength that varies a little between recordings, so the edit
        // differs from the copy saved last time and Save isn't "Copy Saved".
        dragTrack(strength, from: 1, to: 0.6 + Double(Int(Date().timeIntervalSince1970) % 25) / 100)
        hold(0.4)
        focus(button("Share", in: app), button("Export Options", in: app), padding: 70)
        tap(saveButton(in: app))
        hold(1.2)
        tap(button("Share", in: app))
        wide()
        hold(1.4)
        closeShareSheet(in: app)
        hold(0.4)
        end()

        wait(1)
        resetEdits(app)
    }

    /// guide-export-options: JPEG and a smaller size, with the file size shown.
    @MainActor
    func testExportOptions() {
        let app = launch()
        start(app)
        hold(0.3)
        tap(button("Library", in: app))
        tap(photo(5, in: app))
        XCTAssertTrue(editorPhoto(in: app).waitForExistence(timeout: 5))
        let gear = button("Export Options", in: app)
        focus(gear, button("Share", in: app), padding: 70)
        tap(gear)
        let jpeg = button("JPEG", in: app)
        XCTAssertTrue(jpeg.waitForExistence(timeout: 3))
        focus(CGRect(x: 0, y: 140, width: 402, height: 590))
        tap(jpeg)
        hold(0.8)
        tap(buttonStarting("Small", in: app))
        hold(0.9)
        tap(button("HEIF", in: app))
        hold(0.6)
        wide()
        tap(button("Done", in: app))
        hold(0.3)
        end()

        tap(gear)
        tap(button("HEIF", in: app))
        tap(buttonStarting("Full Resolution", in: app))
        tap(button("Done", in: app))
    }

    /// guide-settings: a tour of Settings.
    @MainActor
    func testSettings() {
        let app = launch()
        start(app)
        hold(0.4)
        focus(button("Settings", in: app), padding: 90)
        tap(button("Settings", in: app))
        wide()
        hold(0.6)
        scroll(app, by: 300)
        hold(0.5)
        tap(buttonStarting("Format", in: app))
        hold(0.8)
        tap(button("HEIF", in: app))
        hold(0.3)
        scroll(app, by: 420)
        hold(0.6)
        scroll(app, by: 420)
        hold(0.6)
        tap(button("Done", in: app))
        hold(0.3)
        end()
    }

    /// guide-backup: back up the Library and get the file to share.
    @MainActor
    func testBackup() {
        let app = launch()
        start(app)
        hold(0.4)
        tap(button("Settings", in: app))
        wide()
        scroll(app, by: 380)
        scroll(app, by: 380)
        let backUp = button("Back Up Library", in: app)
        XCTAssertTrue(backUp.waitForExistence(timeout: 3))
        focus(backUp, button("Restore from Backup", in: app), padding: 70)
        tap(backUp)
        // The share sheet opens once the file is written.
        _ = app.buttons["Close"].waitForExistence(timeout: 20)
        wide()
        hold(1.4)
        closeShareSheet(in: app)
        hold(0.4)
        end()

        if button("Done", in: app).exists { tap(button("Done", in: app)) }
    }

    // MARK: - Colour

    /// guide-color-mixer: pick a colour and shift its hue and saturation.
    @MainActor
    func testColorMixer() {
        let app = launch()
        start(app)
        hold(0.4)
        focus(app.buttons["Library"], padding: 110)
        app.buttons["Library"].tap()
        wide()
        photo(5, in: app).tap()
        let picture = editorPhoto(in: app)
        focus(picture, app.buttons["Color"])
        app.buttons["Color"].tap()
        focus(picture, slider("Luminance", in: app))
        app.buttons["Blue"].tap()
        hold(0.2)
        drag(slider("Hue", in: app), from: 0, to: 0.65)
        drag(slider("Saturation", in: app), from: 0, to: 0.7)
        hold(0.4)
        focus(picture, padding: 0)
        app.buttons["Compare with original"].tap()
        hold(0.9)
        app.buttons["Compare with original"].tap()
        hold(0.5)
        wide()
        hold(0.3)
        end()
        wait(1.0)
        resetEdits(app)
    }

    // MARK: - Helpers

    /// Launches Snapper; `demoImage`, a photo in Snapper/Resources/Showcase,
    /// replaces the Simulator camera's stand-in photo (a portrait without a
    /// model release). It also stands in for the looks' and collections'
    /// sample photos.
    @MainActor
    private func launch(demoImage: String = "showcase-cafe") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SnapperShowTouches", "YES", "-app.hasCompletedOnboarding", "YES"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        app.launchEnvironment["SNAPPER_DEMO_IMAGE"] = root.appendingPathComponent("Snapper/Resources/Showcase/\(demoImage).jpg").path
        // Saving asks for Photos access the first time.
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow", "Allow Full Access", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        wait(2.0)
        return app
    }

    /// The marks the recording script trims to. The start also notes the
    /// screen's size, which the camera's areas are measured in.
    @MainActor
    private func start(_ app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        mark("SCREEN \(Int(screen.width)) \(Int(screen.height))")
        mark("DEMO START")
    }

    @MainActor private func end() { mark("DEMO END") }

    /// Eases the camera in until these elements, with `padding` points
    /// around them, fill the clip, then waits for it to arrive.
    @MainActor
    private func focus(_ elements: XCUIElement..., padding: CGFloat = 16) {
        focus(elements.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -padding, dy: -padding))
    }

    /// Eases the camera in on an area of the screen, in points.
    @MainActor
    private func focus(_ area: CGRect) {
        mark("CAMERA \(Int(area.minX)) \(Int(area.minY)) \(Int(area.width)) \(Int(area.height))")
        wait(0.6)
    }

    /// Pulls the camera back to the whole phone.
    @MainActor
    private func wide() {
        mark("CAMERA WIDE")
        wait(0.6)
    }

    /// Waits, keeping the whole pause in the clip.
    @MainActor
    private func hold(_ seconds: TimeInterval) {
        mark("HOLD \(seconds)")
        wait(seconds)
    }

    @MainActor private func mark(_ name: String) { XCTContext.runActivity(named: name) { _ in } }

    private func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// Taps an element once it appears, failing the demo if it never does.
    @MainActor
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 6) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element.description)")
        element.tap()
    }

    @MainActor
    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    /// The editor's save button, whatever it says ("Save Copy", "Save to
    /// Photos", "Saved to Photos").
    @MainActor
    private func saveButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save' AND NOT (label BEGINSWITH 'Save Without')")).firstMatch
    }

    @MainActor
    private func buttonStarting(_ prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A Library photo by its place in the grid (0 is the newest).
    @MainActor
    private func photo(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).element(boundBy: index)
    }

    /// The editor's photo.
    @MainActor
    private func editorPhoto(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo in'")).firstMatch
    }

    @MainActor
    private func slider(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: title).firstMatch
    }

    /// Drags a ProSlider from one value to another (both −1…1).
    @MainActor
    private func drag(_ slider: XCUIElement, from: Double, to: Double) {
        dragTrack(slider, from: (from + 1) / 2, to: (to + 1) / 2)
    }

    /// Drags a ProSlider between two places on its track (0 is the left
    /// end, 1 the right) at about 100 pt a second, slow enough to watch the
    /// photo change. Its row is the 84 pt name, a 10 pt gap, the track, a
    /// 10 pt gap and the 44 pt value; the handle's centre stays 11 pt inside
    /// the track's ends.
    @MainActor
    private func dragTrack(_ slider: XCUIElement, from: Double, to: Double) {
        let width = slider.frame.width
        let trackStart = 94.0 + 11, trackEnd = width - 54 - 11
        func point(_ fraction: Double) -> XCUICoordinate {
            let x = trackStart + fraction * (trackEnd - trackStart)
            return slider.coordinate(withNormalizedOffset: CGVector(dx: x / width, dy: 0.5))
        }
        point(from).press(forDuration: 0.15, thenDragTo: point(to), withVelocity: XCUIGestureVelocity(rawValue: 100),
                          thenHoldForDuration: 0.25)
    }

    /// Slides a tick ruler (Adjust, Straighten): dragging left raises the
    /// value, a tick every 8 or 9 points.
    @MainActor
    private func ruler(_ ruler: XCUIElement, by points: CGFloat) {
        let width = ruler.frame.width
        stroke(on: ruler, from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.5 - points / width, dy: 0.5), velocity: 80)
    }

    /// Drags a system slider's thumb from where it is to a position (0…1).
    @MainActor
    private func slide(_ slider: XCUIElement, to position: CGFloat) {
        let width = slider.frame.width
        func point(_ fraction: CGFloat) -> XCUICoordinate {
            slider.coordinate(withNormalizedOffset: CGVector(dx: (14 + fraction * (width - 28)) / width, dy: 0.5))
        }
        point(slider.normalizedSliderPosition).press(forDuration: 0.12, thenDragTo: point(position),
                                                      withVelocity: XCUIGestureVelocity(rawValue: 160),
                                                      thenHoldForDuration: 0.2)
    }

    /// One finger across an element, between two points given as fractions of it.
    @MainActor
    private func stroke(on element: XCUIElement, from: CGVector, to: CGVector, velocity: CGFloat = 220) {
        element.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.1, thenDragTo: element.coordinate(withNormalizedOffset: to),
                   withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0.1)
    }

    /// Scrolls the frontmost list up by about `points`.
    @MainActor
    private func scroll(_ app: XCUIApplication, by points: CGFloat) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75 - points / height)),
                   withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.3)
    }

    /// Taps the button of a confirmation dialog: the last one with that name,
    /// as the button that opened it may share it.
    @MainActor
    private func confirm(_ label: String, in app: XCUIApplication) {
        let matches = app.buttons.matching(identifier: label)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 4))
        wait(0.5)
        matches.element(boundBy: matches.count - 1).tap()
    }

    /// Closes the system share sheet.
    @MainActor
    private func closeShareSheet(in app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 4) {
            close.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        wait(0.6)
    }

    /// Picks a look in the editor's strip, scrolling the strip to it first.
    @MainActor
    private func pickLook(_ name: String, in app: XCUIApplication) {
        let tile = button(name, in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        for _ in 0..<4 where !tile.isHittable {
            let y = tile.frame.midY
            let window = app.windows.firstMatch
            let (from, to) = tile.frame.minX < 0 ? (60.0, 340.0) : (340.0, 60.0)
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: from, dy: y))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: to, dy: y)),
                       withVelocity: XCUIGestureVelocity(rawValue: 900), thenHoldForDuration: 0.3)
        }
        tap(tile)
    }

    /// Sets the camera's look from the Looks sheet, by search.
    @MainActor
    private func chooseLook(_ name: String, in app: XCUIApplication) {
        tap(buttonStarting("Browse looks", in: app))
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText(name)
        tap(button(name, in: app))
        wait(0.6)
    }

    /// Deletes a personal preset from the camera's My Styles.
    @MainActor
    private func deletePreset(_ name: String, in app: XCUIApplication) {
        tap(buttonStarting("My styles", in: app))
        tap(button("Manage \(name)", in: app))
        tap(button("Delete", in: app))
        confirm("Delete", in: app)
        tap(button("Done", in: app))
    }

    /// Deletes every version of the editor's photo, from the Versions sheet.
    /// A version's row reads "name, look · date"; the photo's own Original
    /// ("No look or edits") has no " · " and is left alone.
    @MainActor
    private func deleteAllVersions(in app: XCUIApplication) {
        tap(button("Versions", in: app))
        XCTAssertTrue(button("New Version from Original", in: app).waitForExistence(timeout: 4))
        wait(0.5)
        let rows = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS ' · '"))
        while rows.count > 0 {
            rows.element(boundBy: 0).press(forDuration: 1.0)
            tap(button("Delete", in: app))
            confirm("Delete Version", in: app)
            wait(0.6)
        }
        tap(button("Done", in: app))
    }

    /// Puts the photo back as it was, after the clip.
    @MainActor
    private func resetEdits(_ app: XCUIApplication) {
        app.buttons["Reset"].tap()
        app.buttons["Reset All Edits"].tap()
        wait(0.5)
    }
}
