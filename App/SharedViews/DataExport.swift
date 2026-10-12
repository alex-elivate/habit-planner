import HabitKit
import HabitStore
import SwiftUI
import UniformTypeIdentifiers

/// The export as files: everything as JSON, and completions as CSV for a spreadsheet.
nonisolated struct ExportFiles: Sendable {
    let name: String
    let json: Data
    let csv: Data

    var jsonName: String { "\(name).json" }
    var csvName: String { "\(name) completions.csv" }

    /// Written to a fresh temporary folder, for the share sheet, which takes file URLs.
    /// Exports more than an hour old are removed first, so opening Settings again does not
    /// leave another copy of everything behind. A recent one may still be in a share sheet.
    func write() throws -> [URL] {
        let files = FileManager.default
        let temporary = files.temporaryDirectory
        let stale = Date.now.addingTimeInterval(-3_600)
        for old in (try? files.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("Export-")
            && ((try? old.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < stale {
            try? files.removeItem(at: old)
        }
        let folder = temporary.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = [folder.appendingPathComponent(jsonName), folder.appendingPathComponent(csvName)]
        try json.write(to: urls[0])
        try csv.write(to: urls[1])
        return urls
    }
}

extension AppModel {
    /// Reads every record and makes the files. Named for today, so exports sort by date.
    func exportFiles() async throws -> ExportFiles {
        let export = try await store.export(at: .now)
        return ExportFiles(name: "Habit Planner \(today)",
                           json: try export.json(),
                           csv: Data(export.completionsCSV().utf8))
    }
}

/// Both files in one folder, for the Mac's save panel, which saves one document.
///
/// Nonisolated, since the save panel may ask for the file wrapper off the main thread.
nonisolated struct ExportFolder: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let files: ExportFiles

    init(_ files: ExportFiles) { self.files = files }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: [
            files.jsonName: FileWrapper(regularFileWithContents: files.json),
            files.csvName: FileWrapper(regularFileWithContents: files.csv),
        ])
    }
}
