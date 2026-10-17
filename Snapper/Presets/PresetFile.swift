import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let snapperPreset = UTType(exportedAs: "app.snapper.preset", conformingTo: .json)
}

/// Portable style only: no photos, file paths, device IDs, crops or dates.
struct PresetFile: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    var name: String
    let lookID: String
    let strength: Double
    let adjustments: PhotoAdjustments
    var id: String { "\(lookID)-\(name)" }
    static let maximumBytes = 65_536

    init(_ preset: SavedPreset) {
        version = 1
        name = preset.name
        lookID = preset.lookID
        strength = preset.strength
        adjustments = preset.adjustments
    }
    var recipe: PhotoRecipe { PhotoRecipe(lookID: lookID, strength: strength, adjustments: adjustments) }

    enum FileError: LocalizedError {
        case tooLarge, invalid, newerVersion, unavailableLook
        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "This preset file is too large. Choose a Snapper preset smaller than 64 KB.")
            case .invalid: String(localized: "This file isn't a valid Snapper preset. No presets were changed.")
            case .newerVersion: String(localized: "This preset needs a different version of Snapper. Update the app and try again.")
            case .unavailableLook: String(localized: "This preset uses a look that isn't available in this version of Snapper.")
            }
        }
    }

    static func decode(_ data: Data, looks: LookLibrary) throws -> PresetFile {
        guard data.count <= maximumBytes else { throw FileError.tooLarge }
        guard let file = try? JSONDecoder().decode(Self.self, from: data) else { throw FileError.invalid }
        guard file.version == 1 else { throw FileError.newerVersion }
        guard looks.look(id: file.lookID) != nil else { throw FileError.unavailableLook }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              file.strength.isFinite, (0...1).contains(file.strength),
              PhotoAdjustments.Kind.allCases.allSatisfy({
                  file.adjustments[$0].isFinite && $0.range.contains(file.adjustments[$0])
              }) else { throw FileError.invalid }
        var result = file
        result.name = name
        return result
    }

    static func read(_ url: URL, looks: LookLibrary) throws -> PresetFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data, looks: looks)
    }
}

struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.snapperPreset] }
    let data: Data
    init(_ preset: SavedPreset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(PresetFile(preset))
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= PresetFile.maximumBytes else {
            throw PresetFile.FileError.invalid
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
