import SwiftUI

struct DiskVolumesView: View {
    @ObservedObject var volumes: DiskVolumeStore = .shared
    @ObservedObject var navigation: ToolNavigation
    var body: some View {
        Group {
            if let profile = volumes.selectedProfile {
                DiskDashboardView(store: profile.disk, security: profile.security, navigation: navigation, volumeStore: volumes, volume: profile.volume).id(profile.volume.id)
            } else { ProgressView("Laufwerke werden geladen …") }
        }.onAppear { volumes.refresh() }
    }
}

struct DiskVolumeSelector: View {
    @ObservedObject var store: DiskVolumeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Laufwerke").font(.headline)
                Text("Eigene Scanstände je Laufwerk").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Angeschlossene Laufwerke aktualisieren").accessibilityLabel("Laufwerke aktualisieren")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.volumes) { volume in
                        DiskVolumeChoice(volume: volume, disk: store.profile(for: volume.id).disk, selected: store.selectedVolume?.id == volume.id) { store.selectedID = volume.id }
                    }
                }.padding(.vertical, 2)
            }
        }
    }
}

private struct DiskVolumeChoice: View {
    let volume: DiskScanVolume
    @ObservedObject var disk: DiskScanStore
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: volume.icon).font(.system(size: 22)).foregroundStyle(selected ? Color.cyan : .secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(volume.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan) }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(volume.isMounted ? (disk.isScanning ? Color.cyan : .green) : .secondary).frame(width: 5, height: 5)
                        Text(!volume.isMounted ? "Nicht verbunden" : disk.isScanning ? "Scan läuft" : volume.isPrimary ? "Dieser Mac" : "Verbunden").font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = disk.summary {
                        Text("\(summary.fileCount.formatted()) Dateien · " + summary.completedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if let free = volume.free { Text(diskBytes(free) + " frei").font(.caption2).foregroundStyle(.secondary) }
                    else { Text("Noch kein gespeicherter Scan").font(.caption2).foregroundStyle(.secondary) }
                }
            }.padding(13).frame(width: 236, alignment: .leading)
                .background(selected ? Color.cyan.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.cyan.opacity(0.65) : Color.primary.opacity(0.08)))
        }.buttonStyle(.plain).accessibilityLabel("Laufwerk " + volume.name + (volume.isMounted ? " verbunden" : " nicht verbunden") + (selected ? ", ausgewählt" : ""))
    }
}
