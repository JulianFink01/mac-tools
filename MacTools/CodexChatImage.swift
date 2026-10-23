import SwiftUI
import ImageIO

struct CodexChatImage: View {
    let source: String
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var preview = false
    private var remote: URL? { guard let url = URL(string: source), ["https", "http"].contains(url.scheme) else { return nil }; return url }
    var body: some View {
        Button { preview = true } label: {
            Group {
                if let remote { AsyncImage(url: remote) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() } }
                else if let image { Image(nsImage: image).resizable().scaledToFit() }
                else if loaded { Label("Bild nicht mehr verfügbar", systemImage: "photo.badge.exclamationmark").font(.caption).foregroundStyle(.secondary).padding(16) }
                else { ProgressView().padding(20) }
            }.frame(maxWidth: 480, maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("Bildanhang öffnen").help("Bild vergrößern")
            .task(id: source) {
                let source = source
                let result = await Task.detached(priority: .utility) { Self.thumbnailData(source, maximum: 1600) }.value
                image = result.flatMap(NSImage.init(data:)); loaded = true
            }
            .sheet(isPresented: $preview) {
                VStack(spacing: 12) {
                    HStack { Text("Bildanhang").font(.headline); Spacer(); Button("Schließen") { preview = false }.keyboardShortcut(.cancelAction) }
                    if let remote { AsyncImage(url: remote) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() } }
                    else if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Text("Das Bild ist auf diesem Mac nicht verfügbar.") }
                }.padding(20).frame(width: 900, height: 680)
            }
    }
    nonisolated static func thumbnailData(_ source: String, maximum: Int) -> Data? {
        let cgSource: CGImageSource?
        if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","), let data = Data(base64Encoded: String(source[source.index(after: comma)...])) { cgSource = CGImageSourceCreateWithData(data as CFData, nil) }
        else if source.hasPrefix("/") { cgSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil) }
        else if let url = URL(string: source), url.isFileURL { cgSource = CGImageSourceCreateWithURL(url as CFURL, nil) }
        else { return nil }
        guard let cgSource, let image = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
