import Foundation

func diskBytes(_ value: Int64) -> String { String(value) }

@main
struct FileValidationChecks {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MacTools-validation-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let path = root.appendingPathComponent("test.txt")
        try Data("original".utf8).write(to: path)
        let file = try DiskScanner.scan(root: root, findDuplicates: false).files[0]
        try FileActions.validate(file)
        try Data("modified-data".utf8).write(to: path)
        do { try FileActions.validate(file); fatalError("Changed file must be rejected") } catch {}
        try manager.removeItem(at: path)
        try manager.createSymbolicLink(at: path, withDestinationURL: manager.homeDirectoryForCurrentUser)
        do { try FileActions.validate(file); fatalError("Symlink replacement must be rejected") } catch {}
        print("PASS: unchanged files accepted; changed files and symlink replacements rejected before cleanup")
    }
}
