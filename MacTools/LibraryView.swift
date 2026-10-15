import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var library = VideoLibraryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    var onOpenSettings: () -> Void = {}
    @State private var selection: UUID?
    @State private var isImporting = false

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                ToolPageHeader(title: "Live-Hintergrund", description: "Bring Bewegung auf deinen Desktop. Wähle ein Video aus deiner Bibliothek.", icon: "play.rectangle")
                Button("Tool-Einstellungen", action: onOpenSettings)
            }.padding(24)
            header
            Divider()
            content
            if let error = library.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).padding(18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selection = settings.currentVideoID ?? library.videos.first?.id }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(settings.isPaused ? "Hintergrund pausiert" : "Hintergrund läuft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Darstellung", selection: Binding(
                get: { settings.aspectMode },
                set: { settings.setAspectMode($0) }
            )) {
                ForEach(AspectMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 155)

            Button {
                settings.setPaused(!settings.isPaused)
            } label: {
                Label(settings.isPaused ? "Fortsetzen" : "Pause", systemImage: settings.isPaused ? "play.fill" : "pause.fill")
            }
            .controlSize(.regular)

            Button {
                if let random = library.randomVideo(excluding: settings.currentVideoID) {
                    setWallpaper(random)
                }
            } label: {
                Label("Zufällig", systemImage: "shuffle")
            }
            .controlSize(.regular)
            .disabled(library.videos.isEmpty)

            Button(action: importVideos) {
                Label(isImporting ? "Wird importiert …" : "Videos importieren", systemImage: "plus")
            }.buttonStyle(.borderedProminent).disabled(isImporting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(height: 62)
    }

    @ViewBuilder
    private var content: some View {
        if library.videos.isEmpty {
            EmptyLibraryView(importAction: importVideos)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(library.videos) { video in
                        VideoCard(
                            video: video,
                            isCurrent: settings.currentVideoID == video.id,
                            setWallpaperAction: {
                                setWallpaper(video)
                            },
                            removeAction: {
                                remove(video)
                            }
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.25))
        }
    }

    private var currentTitle: String {
        if let current = library.video(with: settings.currentVideoID) {
            return current.displayName
        }
        return "Noch kein Hintergrund ausgewählt"
    }

    private func setWallpaper(_ video: WallpaperVideo) {
        selection = video.id
        settings.setCurrentVideo(video.id)
        settings.setPaused(false)
    }

    private func importVideos() {
        let panel = NSOpenPanel()
        panel.title = "Videos importieren"
        panel.prompt = "Importieren"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var contentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v") {
            contentTypes.append(m4v)
        }
        panel.allowedContentTypes = contentTypes

        guard panel.runModal() == .OK else { return }

        isImporting = true
        Task {
            let imported = await library.importVideos(from: panel.urls)
            if let first = imported.first {
                setWallpaper(first)
            }
            isImporting = false
        }
    }

    private func remove(_ video: WallpaperVideo) {
        let wasCurrent = settings.currentVideoID == video.id
        library.remove(video)

        if wasCurrent {
            if let replacement = library.videos.first {
                setWallpaper(replacement)
            } else {
                selection = nil
                settings.setCurrentVideo(nil)
            }
        } else if selection == video.id {
            selection = settings.currentVideoID ?? library.videos.first?.id
        }
    }
}

private struct VideoCard: View {
    let video: WallpaperVideo
    let isCurrent: Bool
    let setWallpaperAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(video: video)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .font(.title2)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(video.originalFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(formatDuration(video.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(action: setWallpaperAction) {
                    Label(isCurrent ? "Aktiv" : "Auswählen", systemImage: isCurrent ? "checkmark" : "desktopcomputer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(role: .destructive, action: removeAction) {
                    Label("Entfernen", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: setWallpaperAction)
    }
}

private struct ThumbnailView: View {
    let video: WallpaperVideo

    var body: some View {
        Group {
            if let thumbnailURL = video.thumbnailURL,
               let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.black)
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct EmptyLibraryView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Noch keine Videos importiert")
                .font(.title3.weight(.semibold))
            Text("Importiere eine .mp4-, .mov- oder .m4v-Datei. Das erste Video wird sofort als Hintergrund verwendet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: importAction) {
                Label("Videos importieren", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    guard duration.isFinite else { return "--:--" }
    let totalSeconds = Int(duration.rounded())
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}
