import Foundation

struct WallpaperVideo: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var fileName: String
    var originalFileName: String
    var thumbnailFileName: String?
    var duration: TimeInterval
    var importedAt: Date

    var fileURL: URL {
        VideoLibraryStore.videosDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    var thumbnailURL: URL? {
        guard let thumbnailFileName else { return nil }
        return VideoLibraryStore.thumbnailsDirectory.appendingPathComponent(thumbnailFileName, isDirectory: false)
    }
}
