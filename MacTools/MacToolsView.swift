import SwiftUI

@MainActor
final class ToolNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case tools = "Alle Werkzeuge"
        case containers = "Container"
        case mcp = "MacTools MCP"
        case infrapilot = "InfraPilot"
        case alphaTrader = "AlphaTrader"
        case codexLimit = "Codex-Limit"
        case disk = "Disk & Sicherheit"
        case apps = "Apps"
        case monitoring = "Systemmonitor"
        case wallpaper = "Live-Hintergrund"
        case windows = "Fenster vorn halten"
        case codex = "Codex-Chats"
        case settings = "Einstellungen"
        static var pinnable: [Section] { [.codex, .codexLimit, .mcp, .monitoring, .disk, .containers, .apps, .wallpaper, .windows] + (PrivateMCPAccess.enabled ? [.infrapilot, .alphaTrader] : []) }
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .tools: return "square.grid.2x2"
            case .containers: return "shippingbox"
            case .mcp: return "point.3.connected.trianglepath.dotted"
            case .infrapilot: return "server.rack"
            case .alphaTrader: return "chart.line.uptrend.xyaxis"
            case .codexLimit: return "gauge.with.dots.needle.33percent"
            case .codex: return "bubble.left.and.bubble.right"
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
            case .tools: return "Alle verfügbaren Tools"
            case .containers: return "Docker & Podman"
            case .mcp: return "Lokale Werkzeuge für Codex"
            case .infrapilot: return "Cluster-Health · privater MCP"
            case .alphaTrader: return "Trader-Health · privater MCP"
            case .codexLimit: return "Kontingent & Rücksetzzeiten"
            case .codex: return "Chats & neue Aufgaben"
            case .apps: return "Apps & zugehörige Daten"
            case .disk: return "Speicher & Schutz im Überblick"
            case .monitoring: return "CPU · RAM · GPU · I/O"
            case .wallpaper: return "Videos für deinen Desktop"
            case .windows: return "Always on top"
            case .settings: return "MacTools & deine Tools"
            }
        }
    }
    @Published var section: Section = .tools
    @Published var diskTab = "Übersicht"
    @Published var settingsCategory: SettingsCategory = .general

    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
        section = .settings
    }
}

struct MacToolsView: View {
    @ObservedObject var navigation: ToolNavigation
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var disk = DiskScanStore.shared
    @ObservedObject private var security = SecurityScanStore.shared
    @State private var showQuickPanel = false
    @AppStorage("macToolsSidebarBeforeCodex") private var sidebarBeforeCodex = true
    @State private var codexCollapsedSidebar = false
    @AppStorage("macToolsSidebarWidth") private var sidebarWidth = 250.0
    @State private var sidebarDrop = false
    @State private var draggedSidebarEntry: SidebarEntry?
    @AppStorage("macToolsSidebarExpanded") private var sidebarExpanded = true

    var body: some View {
        NativeSidebarSplit(width: $sidebarWidth, expanded: sidebarExpanded, collapsedWidth: 54, minimum: 210) {
            appSidebar
        } detail: {
            pageContent
        }.frame(minWidth: 1240, minHeight: 760)
            .onChange(of: navigation.section) { section in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if section == .codex { sidebarBeforeCodex = sidebarExpanded; codexCollapsedSidebar = true; sidebarExpanded = false }
                    else if codexCollapsedSidebar { sidebarExpanded = sidebarBeforeCodex; codexCollapsedSidebar = false }
                }
            }
            .sheet(isPresented: $showQuickPanel) { quickPanelSheet }
    }

    @ViewBuilder private var appSidebar: some View {
            if sidebarExpanded {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacTools").font(.title3.bold())
                        Text("Dein Mac. Deine Werkzeuge.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(.easeInOut(duration: 0.2)) { sidebarExpanded = false } } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("App-Menü ausblenden").accessibilityLabel("App-Menü ausblenden")
                }.padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                sectionButton(.tools)
                Text("FAVORITEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 18)
                ForEach(settings.sidebarEntries) { entry in
                    favorite(entry, compact: false)
                        .onDrag { draggedSidebarEntry = entry; return NSItemProvider(object: entry.id as NSString) }
                        .onDrop(of: [.text], delegate: SidebarEntryDrop(target: entry, settings: settings, dragged: $draggedSidebarEntry))
                }
                if settings.sidebarEntries.isEmpty {
                    Text("Hefte deine Werkzeuge unter Alle Werkzeuge an.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 11)
                }

                    }
                }.scrollIndicators(.hidden)
                Spacer(minLength: 0)
                Divider()
                if disk.isScanning || disk.isSaving || security.isScanning || security.isUpdating { ScanActivityBadge(disk: disk, security: security) }
                Button { WindowPinController.shared.prepareMenuSelection(); showQuickPanel = true } label: { Label("Schnellaktionen", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain)

                sectionButton(.settings)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
                .onDrop(of: [.text], isTargeted: $sidebarDrop) { providers in ToolDrop.receiveSidebar(providers) }
                .overlay { if sidebarDrop { RoundedRectangle(cornerRadius: 10).stroke(Color.mint, lineWidth: 2).padding(5).allowsHitTesting(false) } }
            } else {
                VStack(spacing: 18) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { sidebarExpanded = true } } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("App-Menü einblenden").accessibilityLabel("App-Menü einblenden").padding(.top, 18)
                    railButton(.tools)
                    Divider().padding(.horizontal, 10)
                    ForEach(settings.sidebarEntries) { entry in
                        favorite(entry, compact: true)
                            .onDrag { draggedSidebarEntry = entry; return NSItemProvider(object: entry.id as NSString) }
                            .onDrop(of: [.text], delegate: SidebarEntryDrop(target: entry, settings: settings, dragged: $draggedSidebarEntry))
                    }
                    Spacer()
                    Button { showQuickPanel = true } label: { Image(systemName: "bolt.circle") }.buttonStyle(.plain).help("Schnellaktionen").accessibilityLabel("Schnellaktionen")
                    railButton(.settings).padding(.bottom, 18)
                }.frame(width: 54).background(Color(nsColor: .controlBackgroundColor))
                    .onDrop(of: [.text], isTargeted: $sidebarDrop) { providers in ToolDrop.receiveSidebar(providers) }
            }
    }

    private var pageContent: some View {
            Group {
                switch navigation.section {
                case .tools: ToolsView(navigation: navigation)
                case .containers: ContainersView()
                case .mcp: MCPPageView()
                case .infrapilot: PrivateMCPPage(kind: .infrapilot)
                case .alphaTrader: PrivateMCPPage(kind: .alphatrader)
                case .codexLimit: CodexUsageView()
                case .disk: DiskVolumesView(navigation: navigation)
                case .codex: CodexChatsView()
                case .apps: AppsView()
                case .monitoring: SystemMonitorView()
                case .wallpaper: LibraryView(onOpenSettings: { navigation.openSettings(.wallpaper) })
                case .windows: WindowToolView(onOpenSettings: { navigation.openSettings(.windows) })
                case .settings: SettingsView(selectedCategory: $navigation.settingsCategory)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quickPanelSheet: some View {
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
                                }, closePanel: { showQuickPanel = false })
                            Button("Schließen") { showQuickPanel = false }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                        }
    }

    @ViewBuilder private func favorite(_ entry: SidebarEntry, compact: Bool) -> some View {
        switch entry {
        case .tool(let section):
            Group { if compact { railButton(section) } else { sectionButton(section) } }
                .contextMenu { Button("Aus Favoriten entfernen") { settings.setSidebarFavorite(section, enabled: false) } }
        case .folder(let path):
            CodexFolderFavorite(path: path, compact: compact) { navigation.section = .codex }
        }
    }

    private func railButton(_ section: ToolNavigation.Section) -> some View {
        Button { navigation.section = section } label: {
            Image(systemName: section.icon).font(.system(size: 17)).frame(width: 36, height: 36)
                .foregroundStyle(navigation.section == section ? Color.mint : Color.secondary)
                .background(navigation.section == section ? Color.mint.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(section.rawValue).accessibilityLabel(section.rawValue)
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

struct ToolTab<Value: Hashable> {
    let value: Value
    let title: String
    let icon: String
}

struct ToolTabBar<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [ToolTab<Value>]
    let accessibilityName: String
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(options, id: \.value) { option in tab(option) } }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 4) {
                let middle = (options.count + 1) / 2
                HStack(spacing: 4) { ForEach(Array(options.prefix(middle)), id: \.value) { option in tab(option).frame(maxWidth: .infinity) } }
                HStack(spacing: 4) { ForEach(Array(options.dropFirst(middle)), id: \.value) { option in tab(option).frame(maxWidth: .infinity) } }
            }
        }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain).accessibilityLabel(accessibilityName)
            .onMoveCommand { direction in
                guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
                if direction == .left, index > 0 { selection = options[index - 1].value }
                if direction == .right, index + 1 < options.count { selection = options[index + 1].value }
            }
    }
    private func tab(_ option: ToolTab<Value>) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = option.value } } label: {
            Label(option.title, systemImage: option.icon)
                .font(.system(size: 12, weight: selection == option.value ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(selection == option.value ? Color.primary : .secondary)
                .padding(.horizontal, 14).frame(height: 38)
                .background {
                    if selection == option.value {
                        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.23), lineWidth: 1))
                            .matchedGeometryEffect(id: "active", in: highlight)
                    }
                }.contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(ToolTabButtonStyle()).accessibilityAddTraits(selection == option.value ? .isSelected : [])
    }
}

private struct ToolTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Hover(configuration: configuration) }
    private struct Hover: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
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

/// Native tracking changes only AppKit frames while the user drags. SwiftUI and
/// preferences receive the final width once tracking has finished.
struct NativeSidebarSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var width: Double
    let expanded: Bool
    var collapsedWidth: CGFloat = 0
    var minimum: CGFloat = 200
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.left = NSHostingController(rootView: AnyView(sidebar()))
        controller.right = NSHostingController(rootView: AnyView(detail()))
        controller.left.sizingOptions = []; controller.right.sizingOptions = []
        controller.side = NSSplitViewItem(viewController: controller.left)
        controller.side.canCollapse = true
        controller.side.minimumThickness = minimum; controller.side.maximumThickness = 600
        controller.side.holdingPriority = NSLayoutConstraint.Priority(260)
        controller.side.isCollapsed = !expanded && collapsedWidth == 0
        let detailItem = NSSplitViewItem(viewController: controller.right)
        detailItem.minimumThickness = 340
        controller.addSplitViewItem(controller.side); controller.addSplitViewItem(detailItem)
        controller.splitView.isVertical = true; controller.splitView.dividerStyle = .thin
        controller.apply(self)
        return controller
    }
    func updateNSViewController(_ controller: Controller, context: Context) { controller.apply(self) }
    static func dismantleNSViewController(_ controller: Controller, coordinator: ()) { controller.pending?.cancel() }
    final class Controller: NSSplitViewController {
        var left: NSHostingController<AnyView>!
        var right: NSHostingController<AnyView>!
        var side: NSSplitViewItem!
        var binding: Binding<Double>?
        var expanded = false
        var requestedWidth: Double = -1
        var applying = false
        var pending: DispatchWorkItem?
        func apply(_ parent: NativeSidebarSplit) {
            binding = parent.$width
            left.rootView = AnyView(parent.sidebar()); right.rootView = AnyView(parent.detail())
            guard expanded != parent.expanded || requestedWidth != parent.width else { return }
            applying = true; expanded = parent.expanded; requestedWidth = parent.width
            side.maximumThickness = 600
            side.minimumThickness = expanded || parent.collapsedWidth == 0 ? parent.minimum : parent.collapsedWidth
            side.maximumThickness = expanded || parent.collapsedWidth == 0 ? 600 : parent.collapsedWidth
            side.isCollapsed = !expanded && parent.collapsedWidth == 0
            let desired = expanded ? min(600, max(parent.minimum, CGFloat(parent.width))) : parent.collapsedWidth
            left.preferredContentSize = NSSize(width: desired, height: 0)
            view.layoutSubtreeIfNeeded()
            if !side.isCollapsed { splitView.setPosition(desired, ofDividerAt: 0) }
            applying = false
            // SwiftUI attaches the controller after its first update. Reapply the
            // initial width once the native controller has a real container size.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.side.isCollapsed else { return }
                self.applying = true; self.splitView.setPosition(desired, ofDividerAt: 0); self.applying = false
            }
        }
        override func splitViewDidResizeSubviews(_ notification: Notification) {
            super.splitViewDidResizeSubviews(notification)
            guard !applying, expanded, let binding else { return }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.expanded else { return }
                if NSEvent.pressedMouseButtons != 0 { self.splitViewDidResizeSubviews(notification); return }
                let value = Double(self.left.view.frame.width)
                guard value >= self.side.minimumThickness else { return }
                self.requestedWidth = value
                if abs(binding.wrappedValue - value) > 0.5 { binding.wrappedValue = value }
            }
            pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

enum ToolDrop {
    static let prefix = "mactools-tool:"
    static let folderPrefix = "mactools-codex-folder:"
    static let chatPrefix = "mactools-codex-chat:"
    static func receiveMenu(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            DispatchQueue.main.async {
                if text.hasPrefix(chatPrefix) { SettingsStore.shared.setChatPinned(String(text.dropFirst(chatPrefix.count)), enabled: true) }
                else if text.hasPrefix(folderPrefix) { SettingsStore.shared.pinCodexFolder(String(text.dropFirst(folderPrefix.count))) }
                else if text.hasPrefix(prefix), let tool = ToolNavigation.Section(rawValue: String(text.dropFirst(prefix.count))), ToolNavigation.Section.pinnable.contains(tool) { SettingsStore.shared.setPinned(tool, enabled: true) }
            }
        }
        return true
    }
    static func receiveSidebar(_ providers: [NSItemProvider], before target: SidebarEntry? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let raw = value as? String, let entry = SidebarEntry(raw) else { return }
            DispatchQueue.main.async { SettingsStore.shared.moveSidebarEntry(entry, before: target) }
        }
        return true
    }
    static func receive(_ providers: [NSItemProvider], action: @escaping (ToolNavigation.Section) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, text.hasPrefix(prefix), let tool = ToolNavigation.Section(rawValue: String(text.dropFirst(prefix.count))), ToolNavigation.Section.pinnable.contains(tool) else { return }
            DispatchQueue.main.async { action(tool) }
        }
        return true
    }
}

struct SidebarFavoriteDrop: DropDelegate {
    let target: ToolNavigation.Section
    let settings: SettingsStore
    @Binding var dragged: ToolNavigation.Section?
    func dropEntered(info: DropInfo) {
        guard let source = dragged, source != target else { return }
        withAnimation(.easeInOut(duration: 0.18)) { settings.moveSidebar(source, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragged == nil ? .copy : .move) }
    func performDrop(info: DropInfo) -> Bool {
        if let source = dragged { settings.moveSidebar(source, before: target); dragged = nil; return true }
        return ToolDrop.receive(info.itemProviders(for: [.text])) { source in settings.moveSidebar(source, before: target) }
    }
}


enum SidebarEntry: Identifiable, Equatable {
    case tool(ToolNavigation.Section), folder(String)
    var id: String { switch self { case .tool(let tool): return ToolDrop.prefix + tool.rawValue; case .folder(let path): return ToolDrop.folderPrefix + path } }
    init?(_ raw: String) {
        if raw.hasPrefix(ToolDrop.folderPrefix), raw.count > ToolDrop.folderPrefix.count { self = .folder(String(raw.dropFirst(ToolDrop.folderPrefix.count))) }
        else if raw.hasPrefix(ToolDrop.prefix), let tool = ToolNavigation.Section(rawValue: String(raw.dropFirst(ToolDrop.prefix.count))), ToolNavigation.Section.pinnable.contains(tool) { self = .tool(tool) }
        else { return nil }
    }
}

struct SidebarEntryDrop: DropDelegate {
    let target: SidebarEntry
    let settings: SettingsStore
    @Binding var dragged: SidebarEntry?
    func dropEntered(info: DropInfo) {
        guard let source = dragged, source != target else { return }
        withAnimation(.easeInOut(duration: 0.18)) { settings.moveSidebarEntry(source, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragged == nil ? .copy : .move) }
    func performDrop(info: DropInfo) -> Bool {
        if let source = dragged { settings.moveSidebarEntry(source, before: target); dragged = nil; return true }
        return ToolDrop.receiveSidebar(info.itemProviders(for: [.text]), before: target)
    }
}

/// Own observation boundary: live updates do not invalidate the entire app shell.
private struct CodexFolderFavorite: View {
    let path: String
    let compact: Bool
    let open: () -> Void
    @ObservedObject private var store = CodexStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showing = false
    private var running: [CodexChat] { store.liveChats.filter { store.folder(for: $0) == path && $0.status == "active" } }
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 17)).frame(width: 22)
                if !compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.folderName(path)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(running.count) laufende Chats").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }.padding(compact ? 7 : 11).frame(maxWidth: compact ? 36 : .infinity, minHeight: compact ? 36 : 48, alignment: .leading)
                .background(showing ? Color.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(store.folderName(path) + " · laufende Chats").accessibilityLabel("Ordnerfavorit " + store.folderName(path))
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.folderName(path)).font(.headline)
                if running.isEmpty { Text("Keine laufenden Chats").foregroundStyle(.secondary) }
                ForEach(running) { chat in
                    Button { showing = false; open(); Task { await store.select(chat.id) } } label: {
                        HStack { Circle().fill(.green).frame(width: 6, height: 6); Text(chat.title).lineLimit(2); Spacer(minLength: 0) }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(18).frame(width: 280)
        }
        .contextMenu {
            Button("Aus Favoriten entfernen") { settings.setSidebarFolder(path, enabled: false) }
            Toggle("In Mac-Menüleiste anheften", isOn: Binding(get: { settings.pinnedCodexFolders.contains(path) }, set: { enabled in if enabled { settings.pinCodexFolder(path) } else { settings.pinnedCodexFolders.removeAll { $0 == path } } }))
        }.onAppear { store.start() }
    }
}

/// Scoped to the surrounding SwiftUI scroll view; global macOS preferences stay intact.
struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure() }
    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        func configure() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
                scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
            }
        }
    }
}
