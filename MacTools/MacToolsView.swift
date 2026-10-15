import SwiftUI

@MainActor
final class ToolNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case disk = "Disk & Sicherheit"
        case apps = "Apps"
        case monitoring = "Systemmonitor"
        case wallpaper = "Live-Hintergrund"
        case windows = "Fenster vorn halten"
        case settings = "Einstellungen"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .apps: return "app.badge"
            case .disk: return "internaldrive"
            case .monitoring: return "waveform.path.ecg"
            case .wallpaper: return "play.rectangle"
            case .windows: return "pin"
            case .settings: return "gearshape"
            }
        }
        var detail: String {
            switch self {
            case .apps: return "Apps & zugehörige Daten"
            case .disk: return "Speicher & Schutz im Überblick"
            case .monitoring: return "CPU · RAM · GPU · I/O"
            case .wallpaper: return "Videos für deinen Desktop"
            case .windows: return "Always on top"
            case .settings: return "MacTools & deine Tools"
            }
        }
    }
    @Published var section: Section = .monitoring
    @Published var diskTab = "Übersicht"
    @Published var settingsCategory: SettingsCategory = .general

    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
        section = .settings
    }
}

struct MacToolsView: View {
    @ObservedObject var navigation: ToolNavigation
    @ObservedObject private var disk = DiskScanStore.shared
    @ObservedObject private var security = SecurityScanStore.shared
    @State private var showQuickPanel = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacTools").font(.title3.bold())
                        Text("Dein Mac. Deine Werkzeuge.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                sectionButton(.monitoring)
                sectionButton(.disk)
                Group {
                    VStack(spacing: 2) {
                        ForEach(["Übersicht", "Dateien & Ordner", "Duplikate", "Virenscan", "Warnungen"], id: \.self) { tab in
                            Button { navigation.section = .disk; navigation.diskTab = tab } label: {
                                Label(tab, systemImage: tabIcon(tab))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).padding(.horizontal, 12)
                                    .foregroundStyle(navigation.section == .disk && navigation.diskTab == tab ? Color.accentColor : Color.secondary)
                                    .background(navigation.section == .disk && navigation.diskTab == tab ? Color.accentColor.opacity(0.1) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.leading, 16)
                }
                Text("TOOLS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 18)
                sectionButton(.apps)
                sectionButton(.wallpaper)
                sectionButton(.windows)
                    }
                }
                Spacer(minLength: 0)
                Divider()
                if disk.isScanning || disk.isSaving || security.isScanning || security.isUpdating { ScanActivityBadge(disk: disk, security: security) }
                Button { WindowPinController.shared.prepareMenuSelection(); showQuickPanel = true } label: { Label("Schnellaktionen", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain)
                    .sheet(isPresented: $showQuickPanel) {
                        VStack(spacing: 0) {
                            QuickPanelView(settings: SettingsStore.shared, library: VideoLibraryStore.shared,
                                openSection: { section in showQuickPanel = false; navigation.section = section },
                                openSettings: { category in showQuickPanel = false; navigation.openSettings(category) },
                                pin: { showQuickPanel = false; WindowPinController.shared.toggleCurrentWindow(useMenuSelection: true) },
                                randomWallpaper: {
                                    let library = VideoLibraryStore.shared
                                    if let random = library.randomVideo(excluding: SettingsStore.shared.currentVideoID) {
                                        SettingsStore.shared.setCurrentVideo(random.id); SettingsStore.shared.setPaused(false)
                                    }
                                })
                            Button("Schließen") { showQuickPanel = false }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                        }
                    }
                sectionButton(.settings)
            }.padding(16).frame(width: 250).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Group {
                switch navigation.section {
                case .disk: DiskDashboardView(store: disk, security: security, navigation: navigation)
                case .apps: AppsView()
                case .monitoring: SystemMonitorView()
                case .wallpaper: LibraryView(onOpenSettings: { navigation.openSettings(.wallpaper) })
                case .windows: WindowToolView(onOpenSettings: { navigation.openSettings(.windows) })
                case .settings: SettingsView(selectedCategory: $navigation.settingsCategory)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 1240, minHeight: 760)
    }

    private func sectionButton(_ section: ToolNavigation.Section) -> some View {
        Button { navigation.section = section } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 17)).frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.rawValue).font(.subheadline.weight(.semibold))
                    Text(section.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(navigation.section == section ? Color.accentColor.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private func tabIcon(_ tab: String) -> String {
        switch tab {
        case "Übersicht": return "chart.bar.xaxis"
        case "Dateien & Ordner": return "folder"
        case "Duplikate": return "square.on.square"
        case "Virenscan": return "shield"
        default: return "exclamationmark.triangle"
        }
    }
}

struct ToolPageHeader: View {
    let title: String
    let description: String
    let icon: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48).background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.largeTitle.bold())
                Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolSettingsCard<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ScanActivityBadge: View {
    @ObservedObject var disk: DiskScanStore
    @ObservedObject var security: SecurityScanStore
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(security.isScanning || security.isUpdating ? "Virenschutz" : disk.isSaving ? "Scan speichern" : "Gesamtscan läuft")
                    .font(.caption.weight(.semibold)).foregroundStyle(.cyan)
            }
            Text(security.isScanning || security.isUpdating ? security.status : disk.progress.phase)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let fraction = security.isScanning ? security.progressFraction : disk.progress.fraction {
                ProgressView(value: fraction).tint(.cyan)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cyan.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
