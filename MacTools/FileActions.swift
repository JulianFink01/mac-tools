import AppKit
import Combine
import SwiftUI
import Quartz
import Darwin

struct FileRemoval: Sendable {
    let paths: [String]
    let directories: Set<String>
}

@MainActor
final class FileActions: ObservableObject {
    static let shared = FileActions()
    @Published var status: String? {
        didSet {
            statusClearTask?.cancel()
            guard let message = status else { return }
            statusClearTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) }
                catch { return }
                guard self?.status == message else { return }
                self?.status = nil
            }
        }
    }
    private var statusClearTask: Task<Void, Never>?
    @Published private(set) var isCleaning = false
    let removals = PassthroughSubject<FileRemoval, Never>()
    func recordRemoval(paths: [String], directories: Set<String> = []) { if !paths.isEmpty { removals.send(FileRemoval(paths: paths, directories: directories)) } }

    func trash(_ files: [DiskFile], completion: @escaping ([String]) -> Void) {
        guard !isCleaning, !files.isEmpty else { return }
        isCleaning = true
        status = nil
        Task {
            let messages = await Task.detached(priority: .utility) {
                var failures: [String] = []
                var moved: [String] = []
                var missing: [String] = []
                for file in files {
                    var current = stat()
                    if lstat(file.path, &current) != 0, errno == ENOENT {
                        missing.append(file.path)
                        continue
                    }
                    do {
                        try Self.validateForRemoval(file)
                        try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                        moved.append(file.path)
                    } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
                }
                return (moved + missing, "\(moved.count) von \(files.count) Dateien in den Papierkorb verschoben."
                    + (missing.isEmpty ? "" : " \(missing.count) bereits fehlende Dateien aus der Anzeige entfernt.")
                    + (failures.isEmpty ? "" : "\n" + failures.prefix(10).joined(separator: "\n")))
            }.value
            status = messages.1
            recordRemoval(paths: messages.0)
            isCleaning = false
            completion(messages.0)
        }
    }

    nonisolated static func validateForRemoval(_ file: DiskFile) throws {
        guard !file.isManagedVirtualDisk else { throw FileActionError.managedDisk }
        try validate(file)
    }
    nonisolated static func validate(_ file: DiskFile) throws {
        var info = stat()
        guard lstat(file.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              "\(info.st_dev):\(info.st_ino)" == file.identity,
              info.st_size == file.bytes,
              file.modified.map({ abs(DiskScanner.modificationDate(info).timeIntervalSince($0)) < 0.000001 }) ?? false else {
            throw FileActionError.changed
        }
    }
}

private enum FileActionError: LocalizedError {
    case changed, managedDisk
    var errorDescription: String? {
        switch self {
        case .changed: return "Datei fehlt oder wurde seit dem Scan verändert. Bitte erneut scannen."
        case .managedDisk: return "Verwaltete virtuelle Festplatte. Bitte Daten über Docker oder die zugehörige VM-App bereinigen."
        }
    }
}

struct FilePreviewSelection: Identifiable {
    let id = UUID()
    let files: [DiskFile]
}

private struct QuickLookFileView: NSViewRepresentable {
    let file: DiskFile
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = file.url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != file.url as NSURL { view.previewItem = file.url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct FileComparisonView: View {
    let files: [DiskFile]
    @Environment(\.dismiss) private var dismiss
    @State private var leftIndex = 0
    @State private var rightIndex = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(files.count > 1 ? "Duplikate vergleichen" : "Dateivorschau").font(.title2.bold())
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if files.count > 1 {
                Text("Diese Dateien hatten beim Scan denselben SHA-256-Inhalt. Prüfe Pfad und Inhalt, bevor du eine Kopie entfernst.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    previewColumn(index: $leftIndex)
                    Divider()
                    previewColumn(index: $rightIndex)
                }
            } else { previewColumn(index: $leftIndex) }
        }.padding(22).frame(width: files.count > 1 ? 1020 : 800, height: 670)
    }

    private func previewColumn(index: Binding<Int>) -> some View {
        let file = files[min(index.wrappedValue, files.count - 1)]
        return VStack(alignment: .leading, spacing: 8) {
            if files.count > 1 {
                Picker("Datei", selection: index) {
                    ForEach(Array(files.enumerated()), id: \.offset) { position, candidate in
                        Text("\(position + 1). \(candidate.url.lastPathComponent)").tag(position)
                    }
                }
            }
            Text(file.path).font(.caption).textSelection(.enabled).lineLimit(3)
            Text("\(diskBytes(file.bytes)) · auf Datenträger \(diskBytes(file.allocatedBytes))").font(.caption)
            Text("Geändert: \(file.modified?.formatted(date: .abbreviated, time: .standard) ?? "unbekannt")").font(.caption).foregroundStyle(.secondary)
            if (try? FileActions.validate(file)) != nil {
                QuickLookFileView(file: file).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Datei fehlt oder wurde seit dem Scan verändert. Bitte erneut scannen.").foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Im Finder anzeigen") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Classifies display warnings; manual selection remains available for all files.
enum DuplicateMediaSafety {
    private static func eligible(_ file: DiskFile, home: URL = FileManager.default.homeDirectoryForCurrentUser, personalFolder: String = "Downloads") -> Bool {
        let downloads = home.appendingPathComponent(personalFolder).standardizedFileURL.path + "/"
        // Foundation normalizes /private/var to /var; use the same normalization
        // on both sides while still rejecting any symlink to another location.
        let candidate = file.url.standardizedFileURL.path
        guard candidate.hasPrefix(downloads), file.bytes > 0,
              ["jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp", "mp4", "mov", "m4v", "mkv", "mp3", "wav", "m4a", "flac", "aac", "aiff", "pdf", "nef", "cr2", "arw", "heif", "svg", "xls", "xlsx", "xlsm", "csv", "ods", "doc", "docx", "ppt", "pptx", "odt", "rtf", "opus", "ogg", "avi", "webm"].contains(file.url.pathExtension.lowercased()),
              file.url.resolvingSymlinksInPath().standardizedFileURL.path == file.url.standardizedFileURL.path else { return false }
        let relative = String(candidate.dropFirst(downloads.count))
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") || ["node_modules", "vendor", "src", "build", "dist", "target", "coding", "projects", "developer", "library"].contains($0.lowercased()) }) else { return false }
        var directory = file.url.deletingLastPathComponent()
        let base = home.appendingPathComponent(personalFolder).standardizedFileURL.path
        while directory.standardizedFileURL.path.hasPrefix(base) {
            if ["app", "bundle", "framework", "plugin", "saver", "xcodeproj", "xcworkspace", "photoslibrary", "vmwarevm", "pvm"].contains(directory.pathExtension.lowercased()) { return false }
            if (try? directory.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return false }
            if [".git", "package.json", "Cargo.toml", "Package.swift", "pyproject.toml", "CMakeLists.txt", "Dockerfile"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return false }
            if directory.standardizedFileURL.path == base { break }
            directory.deleteLastPathComponent()
        }
        return true
    }
    /// A display warning, not a lock: manual deletion remains possible.
    /// This deliberately performs no directory or network reads in SwiftUI.
    static func requiresCaution(_ file: DiskFile, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard DuplicateViewIndex.isMedia(file) else { return true }
        let base = home.path + "/"
        let roots = ["Downloads/", "Desktop/", "Pictures/", "Movies/", "Music/", "Documents/", "Library/Mobile Documents/com~apple~CloudDocs/"]
        guard let root = roots.first(where: { file.path.hasPrefix(base + $0) }) else { return true }
        return file.path.dropFirst((base + root).count).split(separator: "/").contains {
            $0.hasPrefix(".") || ["node_modules", "vendor", "src", "build", "dist", "target", "coding", "projects", "developer", "library"].contains($0.lowercased())
            || ["app", "bundle", "framework", "plugin", "saver", "xcodeproj", "xcworkspace", "photoslibrary", "vmwarevm", "pvm"].contains((String($0) as NSString).pathExtension.lowercased())
        }
    }
    static func eligibleMedia(_ file: DiskFile, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard ["jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp", "nef", "cr2", "arw", "mp4", "mov", "m4v", "mkv", "mp3", "wav", "m4a", "flac", "aac", "aiff", "pdf", "heif", "svg", "xls", "xlsx", "xlsm", "csv", "ods", "doc", "docx", "ppt", "pptx", "odt", "rtf", "opus", "ogg", "avi", "webm"].contains(file.url.pathExtension.lowercased()) else { return false }
        // Reuse package/project/symlink guards with an explicit personal-folder root.
        for name in ["Downloads", "Desktop", "Pictures", "Movies", "Music", "Documents", "Library/Mobile Documents/com~apple~CloudDocs"] {
            let root = home.appendingPathComponent(name).standardizedFileURL.path + "/"
            guard file.url.standardizedFileURL.path.hasPrefix(root) else { continue }
            return eligible(file, home: home, personalFolder: name)
        }
        return false
    }
}
