import XCTest
@testable import Snapper

@MainActor
final class EditorModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeEditor(width: Int = 64, height: Int = 48) async throws -> (EditorModel, CaptureLibrary, AppSettings) {
        let looks = LookLibrary.bundled()
        let library = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(TestImages.jpeg(width: width, height: height))
        let settings = AppSettings(defaults: defaults)
        let editor = EditorModel(library: library, looks: looks, settings: settings, id: record.id,
                                 hasPremium: { true }, requestPremium: { _, _, _ in })
        return (editor, library, settings)
    }

    private func someLook(_ looks: LookLibrary = .bundled(), index: Int = 0) throws -> Look {
        try XCTUnwrap(looks.looks.filter { !$0.isOriginal }.dropFirst(index).first)
    }

    func testTapsUndoAndRedoOneAtATime() async throws {
        let (editor, library, _) = try await makeEditor()
        let first = try someLook(), second = try someLook(index: 1)
        XCTAssertFalse(editor.canUndo)

        editor.select(first)
        editor.select(second)
        XCTAssertEqual(editor.recipe.lookID, second.id)

        editor.undo()
        XCTAssertEqual(editor.recipe.lookID, first.id, "each tap is its own step")
        editor.undo()
        XCTAssertEqual(editor.recipe.lookID, Look.original.id)
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(library.record(id: editor.id)?.recipe.lookID, Look.original.id, "undo is stored on the photo")

        editor.redo()
        XCTAssertEqual(editor.recipe.lookID, first.id)
        XCTAssertTrue(editor.canRedo)

        // A new change after undoing drops the redo history.
        editor.setValue(0.2, for: .warmth)
        XCTAssertFalse(editor.canRedo)
    }

    /// A slider drag is many changes but one undo step.
    func testADragIsOneUndoStep() async throws {
        let (editor, _, _) = try await makeEditor()
        for value in [0.05, 0.1, 0.15, 0.2, 0.25, 0.3] {
            editor.setValue(value, for: .brightness)
        }
        editor.commit() // the drag ends
        editor.setValue(0.6, for: .brightness)
        editor.commit()

        editor.undo()
        XCTAssertEqual(editor.value(of: .brightness), 0.3, accuracy: 1e-9)
        editor.undo()
        XCTAssertEqual(editor.value(of: .brightness), 0)
        XCTAssertFalse(editor.canUndo)
    }

    func testResettingOnePartKeepsTheRestAndCanBeUndone() async throws {
        let (editor, _, _) = try await makeEditor()
        let look = try someLook()
        editor.select(look)
        editor.setValue(0.4, for: .contrast)
        editor.rotate()
        XCTAssertTrue(editor.isLookChanged && editor.isLightChanged && editor.isCropChanged)

        editor.resetLight()
        XCTAssertEqual(editor.recipe.adjustments, .none)
        XCTAssertEqual(editor.recipe.lookID, look.id, "the look stays")
        XCTAssertEqual(editor.recipe.crop.quarterTurns, 1, "the crop stays")

        editor.undo()
        XCTAssertEqual(editor.value(of: .contrast), 0.4, accuracy: 1e-9)

        editor.reset()
        XCTAssertFalse(editor.isEdited)
        editor.undo()
        XCTAssertTrue(editor.isEdited, "Reset All can be undone, so it needs no confirmation")
    }

    func testEditsKeptNoteShowsOnce() async throws {
        let (editor, _, settings) = try await makeEditor()
        XCTAssertFalse(editor.showsEditsKeptHint)
        editor.setValue(0.1, for: .fade)
        XCTAssertTrue(editor.showsEditsKeptHint)
        XCTAssertTrue(settings.hasSeenEditsKeptHint)
        editor.dismissEditsKeptHint()

        let again = EditorModel(library: editor.library, looks: editor.looks, settings: settings, id: editor.id,
                                hasPremium: { true }, requestPremium: { _, _, _ in })
        again.setValue(0.2, for: .fade)
        XCTAssertFalse(again.showsEditsKeptHint)
    }

    /// However long a finger pauses mid-drag, lifting it ends one undo step.
    func testAPausedDragIsStillOneUndoStep() async throws {
        let (editor, _, _) = try await makeEditor()
        editor.interaction(began: true)
        editor.setValue(0.1, for: .contrast)
        try await Task.sleep(for: .milliseconds(600)) // longer than the store delay
        editor.setValue(0.4, for: .contrast)
        editor.interaction(began: false)

        editor.undo()
        XCTAssertEqual(editor.value(of: .contrast), 0, "both halves of the drag undo together")
    }

    func testEditingTurnsCompareOff() async throws {
        let (editor, _, _) = try await makeEditor()
        editor.isShowingOriginal = true
        editor.setValue(0.2, for: .warmth)
        XCTAssertFalse(editor.isShowingOriginal)
        editor.isShowingOriginal = true
        editor.tab = .adjust
        XCTAssertFalse(editor.isShowingOriginal)
    }

    /// Crop shapes come from the uncropped photo, not the cropped preview.
    func testCropShapesUseTheWholePhoto() async throws {
        let (editor, _, _) = try await makeEditor(width: 64, height: 48)
        editor.setShape(.square)
        XCTAssertFalse(editor.cropShapes.contains(.fourThree), "still a 4:3 photo underneath the square crop")
        XCTAssertEqual(editor.frameSize, CGSize(width: 64, height: 48))
        editor.rotate()
        XCTAssertEqual(editor.frameSize, CGSize(width: 48, height: 64), "a quarter turn swaps the frame")
    }

    func testFourThreeOnlyWhenItDiffersFromOriginal() async throws {
        let (fourThree, _, _) = try await makeEditor(width: 64, height: 48)
        XCTAssertFalse(fourThree.cropShapes.contains(.fourThree), "4:3 would repeat Original")
        let (threeTwo, _, _) = try await makeEditor(width: 60, height: 40)
        XCTAssertTrue(threeTwo.cropShapes.contains(.fourThree))
    }
}
