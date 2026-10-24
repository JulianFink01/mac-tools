import AppKit
import SwiftUI
import Charts

struct DiskDashboardView: View {
    @ObservedObject var store: DiskScanStore
    @ObservedObject var security: SecurityScanStore
    @ObservedObject private var actions = FileActions.shared
    @ObservedObject private var automatic = AutomaticScans.shared
    @ObservedObject private var fileBrowser = FileBrowserStore.shared
    @State private var inventoryConsumer = UUID()
    private var needsInventory: Bool { volumeMounted && ["Dateien & Ordner","Duplikate"].contains(tab) }
    @State private var filePage = 0
    @State private var folderPage = 0
    @State private var largestPage = 0
    @State private var showSecurityDetails = false
    @State private var preview: FilePreviewSelection?
    @State private var selectedCopies: [String: DiskFile] = [:]
    @State private var duplicatePage = 0
    @State private var mediaOnly = true
    private var duplicateIndex: DuplicateViewIndex? { store.duplicateIndex }
    @State private var expandedDuplicateID: String?
    @State private var duplicateFilePage = 0
    @State private var showDuplicateFolders = false
    @State private var duplicateFolder: String?
    @State private var duplicateFolders: [DuplicateFolderSummary] = []
    @State private var duplicateFoldersLoading = false
    @State private var duplicateFolderPage = 0
    @State private var pendingTrash: [DiskFile] = []
    @State private var confirmTrash = false
    @ObservedObject var navigation: ToolNavigation
    var volumeStore: DiskVolumeStore? = nil
    var volume: DiskScanVolume? = nil
    private var volumeMounted: Bool { volume?.isMounted ?? true }
    private var usesAutomaticPipeline: Bool { volume?.isPrimary != false }
    private var volumePathMatches: Bool { volume.map { $0.isPrimary || DiskVolumeStore.contains(store.root, in: $0.root) } ?? true }
    private var tab: String { navigation.diskTab }
    @State private var query = ""
    @State private var folder: String?
    @State private var backFolders: [String] = []
    @State private var forwardFolders: [String] = []
    private let tabs = ["Übersicht", "Dateien & Ordner", "Duplikate", "Virenscan", "Warnungen"]
    private let colors: [Color] = [.cyan, .purple, .orange, .green, .pink, .blue, .gray]

    private func tabIcon(_ tab: String) -> String {
        switch tab {
        case "Übersicht": return "chart.bar.xaxis"
        case "Dateien & Ordner": return "folder"
        case "Duplikate": return "square.on.square"
        case "Virenscan": return "shield"
        default: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let volumeStore { DiskVolumeSelector(store: volumeStore) }
            if !volumeMounted {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Laufwerk nicht verbunden", systemImage: "externaldrive.badge.xmark").font(.title2.bold())
                    Text("Der letzte Scanstand bleibt gespeichert. Verbinde dieses Laufwerk, um es erneut zu prüfen oder seine Dateien zu öffnen.").foregroundStyle(.secondary)
                    if let summary = store.summary {
                        Text("\(summary.fileCount.formatted()) Dateien · \(diskBytes(summary.bytes)) · " + summary.completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 20)
            } else {
            ToolTabBar(selection: $navigation.diskTab, options: tabs.map { ToolTab(value: $0, title: $0, icon: tabIcon($0)) }, accessibilityName: "Disk & Sicherheit")
            if tab == "Übersicht" {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(usesAutomaticPipeline ? (automatic.enabled ? "Automatische Scans aktiv" : "Automatische Scans aus") : "Separater Laufwerks-Scan", systemImage: "clock.arrow.circlepath")
                        .font(.callout.weight(.medium))
                    Text(usesAutomaticPipeline ? automatic.status : "Dieser Scan verändert weder den Scanstand noch den Zeitplan deines Macs.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan-Einstellungen") { navigation.openSettings(.disk) }
            }

            }
            if let status = actions.status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if tab == "Übersicht" {
            if let result = store.result {
                Text(store.resultIsProvisional ? "Dateiliste bereit · Inhaltsprüfung läuft weiter" : "Ergebnis vom " + result.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(security.isScanning || security.isUpdating ? security.status : store.status)
                .font(.callout.monospacedDigit()).foregroundStyle(security.isScanning || security.isUpdating ? Color.cyan : Color.secondary)
            if store.isScanning {
                Text("\(store.progress.phase) · \(store.progress.files.formatted()) Dateien · \(diskBytes(store.progress.bytes))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.cyan)
            }
            }
            if tab == "Dateien & Ordner", let result = store.result {
                browserNavigation(root: result.root.path, scope: folder ?? result.root.path)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == "Virenscan" { securityPanel }
                    else if tab == "Warnungen" {
                        if !usesAutomaticPipeline {
                            let warnings = (store.result?.warningSamples ?? []) + (security.issue.map { [$0] } ?? [])
                            if warnings.isEmpty { Text("Keine gespeicherten Warnungen für dieses Laufwerk.") }
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.callout).textSelection(.enabled) }
                        } else {
                        if automatic.warnings.isEmpty { Text("Keine gespeicherten Warnungen.") }
                        ForEach(automatic.warnings) { warning in
                            panel(warning.title) {
                                Text(warning.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Text(warning.detail).font(.callout).textSelection(.enabled)
                            }
                        }
                        }
                    }
                    else if let result = store.result {
                        if tab == "Übersicht", result.reachedLimit || result.skipped > 0 { coverage(result) }
                        switch tab {
                        case "Dateien & Ordner": fileDetails(result)
                        case "Duplikate": duplicateDetails(searchEnabled: result.duplicateSearch, totalBytes: result.bytes)
                        default: overview(result)
                        }
                    } else if store.isRestoring {
                        VStack(spacing:14) { ProgressView(); Text("Gespeicherte Dateiliste wird geladen …").foregroundStyle(.secondary) }.frame(maxWidth:.infinity).padding(.vertical,90)
                    } else if let summary = store.summary {
                        VStack(alignment:.leading,spacing:14) {
                            Label("Gespeicherter Scan",systemImage:"internaldrive").font(.title2.bold())
                            Text(summary.completedAt.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.secondary)
                            Text("\(summary.fileCount.formatted()) Dateien · \(diskBytes(summary.bytes)) · \(summary.duplicateCount.formatted()) Duplikatgruppen")
                            Text("Die Dateiliste bleibt auf dem Datenträger und wird beim Öffnen der Dateien oder Duplikate geladen.").font(.callout).foregroundStyle(.secondary)
                            Button("Dateien öffnen") { navigation.diskTab = "Dateien & Ordner" }
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,40)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 52)).foregroundStyle(.cyan)
                            Text(store.isScanning ? "Dein Speicher wird analysiert" : "Wo bleibt der Speicher?").font(.title2.bold())
                            Text("Analysiere einen Ordner oder ein Volume. Du erhältst Größen, Dateitypen, Verzeichnisdetails und optional geprüfte Duplikate.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
                        }.frame(maxWidth: .infinity).padding(.vertical, 90)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!volumePathMatches)
            }
        }.padding(22)
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id:needsInventory) {
                if needsInventory { await store.beginInventoryAccess(inventoryConsumer) }
                else { store.endInventoryAccess(inventoryConsumer) }
            }
            .onDisappear { selectedCopies = [:]; pendingTrash = []; store.endInventoryAccess(inventoryConsumer) }
            .onReceive(actions.removals) { _ in selectedCopies = selectedCopies.filter { !store.isRemoved($0.key) } }
            .onChange(of: store.result?.root) { _ in folder = nil; duplicateFolder = nil; query = ""; backFolders = []; forwardFolders = [] }
            .onChange(of: store.result?.completedAt) { _ in selectedCopies = [:]; duplicatePage = 0; expandedDuplicateID = nil; duplicateFilePage = 0 }
            .sheet(item: $preview) { selection in FileComparisonView(files: selection.files) }
            .alert("Dateien in den Papierkorb verschieben?", isPresented: $confirmTrash) {
                Button("Abbrechen", role: .cancel) { pendingTrash = [] }
                Button("In den Papierkorb", role: .destructive) {
                    let files = pendingTrash
                    pendingTrash = []
                    actions.trash(files) { paths in
                        selectedCopies = [:]
                        // The shared removal event updates every store, including other tabs.
                    }
                }
            } message: {
                Text("\(pendingTrash.count) Dateien · \(diskBytes(pendingTrash.reduce(0) { $0 + $1.bytes }))\n" + pendingTrash.prefix(5).map(\.path).joined(separator: "\n") + (pendingTrash.contains { DuplicateMediaSafety.requiresCaution($0) } ? "\nOrange markierte Dateien können von Apps, Projekten oder WhatsApp-Nachrichten benötigt werden. Auch identische Dateien können an mehreren Stellen erforderlich sein." : "") + "\nWiederherstellen ist über den Finder-Papierkorb möglich.")
            }
            .disabled(actions.isCleaning || store.isSaving)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Disk & Sicherheit").font(.largeTitle.bold())
                Text(tabDescription).foregroundStyle(.secondary)
                Text("Scanbereich: " + store.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Button("Ordner wählen …") { if let volumeStore { volumeStore.chooseFolder() } else { store.chooseFolder() } }
                        .disabled(!volumeMounted || store.isScanning || security.isScanning || security.isUpdating)
                    if store.isScanning || security.isScanning || security.isUpdating {
                        Button(store.isSaving ? "Speichert …" : "Abbrechen", role: .cancel) {
                            if let volumeStore { volumeStore.cancelSelected() }
                            else if usesAutomaticPipeline { automatic.cancelCombined() }
                            else { store.cancel(); security.cancel() }
                        }.disabled(store.isSaving)
                    } else {
                        Button(usesAutomaticPipeline ? "Gesamtscan starten" : "Laufwerk scannen") {
                            if let volumeStore { volumeStore.startSelectedDiskScan() }
                            else if usesAutomaticPipeline { automatic.runNow() }
                            else { store.start() }
                        }.buttonStyle(.borderedProminent).disabled(!volumeMounted || store.isRestoring || store.isSaving || security.isScanning || security.isUpdating)
                    }
                }
                Text(usesAutomaticPipeline ? (store.findDuplicates ? "Speicher · Duplikate · Virenschutz" : "Speicher · Virenschutz") : "Speicher · Duplikate · Virenprüfung separat")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tabDescription: String {
        switch tab {
        case "Dateien & Ordner": return "Entdecke große Dateien und finde heraus, welche Ordner den meisten Platz belegen."
        case "Duplikate": return "Vergleiche identische Dateien und bereinige die Kopien, die du nicht mehr brauchst."
        case "Virenscan": return "Prüfe deine Dateien auf bekannte Bedrohungen und sieh, ob etwas deine Aufmerksamkeit braucht."
        case "Warnungen": return "Kritische Meldungen zu Speicher und Sicherheit."
        default: return "Sieh, was deinen Speicher belegt, und behalte die Sicherheit deiner Dateien im Blick."
        }
    }

    private func overview(_ result: DiskScanResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                metric("Dateigrößen", value: diskBytes(result.bytes), detail: "Logische Größe im Scan", icon: "doc")
                metric("Auf Datenträger", value: diskBytes(result.allocatedBytes), detail: "Gemeldete Dateibelegung", icon: "internaldrive")
                metric("Dateien", value: result.files.count.formatted(), detail: "Hardlinks einmal gezählt", icon: "doc.on.doc")
                metric("Doppelte Inhalte", value: result.duplicateSearch ? diskBytes(result.redundantBytes) : "–",
                       detail: store.resultIsProvisional ? "Inhaltsprüfung läuft" : result.duplicateSearch ? "\(result.duplicates.count) Gruppen · logische Größe" : "Prüfung deaktiviert", icon: "square.on.square")
            }
            HStack(alignment: .top, spacing: 16) {
                panel("Speicher nach Dateityp") {
                    Chart(result.categories) { item in
                        BarMark(x: .value("Bytes", item.bytes), y: .value("Dateityp", item.name))
                            .foregroundStyle(by: .value("Dateityp", item.name))
                            .annotation(position: .trailing) { Text(diskBytes(item.bytes)).font(.caption2) }
                    }.chartForegroundStyleScale(domain: result.categories.map(\.name), range: Array(colors.prefix(result.categories.count)))
                    .chartLegend(.hidden).chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let bytes = value.as(Int64.self) { Text(diskBytes(bytes)) } }
                        }
                    }.frame(height: 235).padding(.trailing, 55)
                    ForEach(Array(result.categories.enumerated()), id: \.element.id) { index, bucket in
                        HStack {
                            Circle().fill(colors[index % colors.count]).frame(width: 7, height: 7)
                            Text(bucket.name)
                            Spacer()
                            Text("\(bucket.count.formatted()) Dateien · \(percent(bucket.bytes, of: result.bytes))")
                                .foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
                panel("Volume & Verlauf") {
                    if result.volumeTotal > 0 {
                        HStack {
                            Text("Volume insgesamt").foregroundStyle(.secondary)
                            Spacer(); Text(diskBytes(result.volumeTotal)).bold()
                        }
                        ProgressView(value: Double(max(0, result.volumeTotal - result.volumeFree)), total: Double(result.volumeTotal)).tint(.cyan)
                        Text("\(diskBytes(result.volumeFree)) frei · \(diskBytes(max(0, result.volumeTotal - result.volumeFree))) belegt")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Volume-Belegung umfasst auch Systemdaten und APFS-Snapshots außerhalb des Scan-Ordners.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 8)
                    let history = store.history.filter { $0.root == result.root.path }
                    Text("Scan-Verlauf · gleicher Ordner").font(.subheadline.bold())
                    if history.count > 1 {
                        Chart(history) { point in
                            LineMark(x: .value("Zeit", point.date), y: .value("Dateigröße", point.bytes)).foregroundStyle(.cyan)
                            PointMark(x: .value("Zeit", point.date), y: .value("Dateigröße", point.bytes)).foregroundStyle((point.skipped ?? 0) > 0 ? .orange : .cyan)
                        }.chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel { if let bytes = value.as(Int64.self) { Text(diskBytes(bytes)) } }
                            }
                        }.frame(height: 165)
                    } else {
                        Text("Ab zwei Gesamtscans zeigt die Zeitreihe, wie sich die erfassten Dateigrößen verändern.")
                            .foregroundStyle(.secondary).font(.callout).frame(height: 130)
                    }
                }
            }
            panel("Größte Speicherverursacher") {
                let pageCount = max(1, (result.files.count + 7) / 8)
                let page = min(largestPage, pageCount - 1)
                HStack {
                    Text("\(result.files.count.formatted()) Dateien · größte zuerst").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { largestPage = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                        .help("Vorherige Speicherverursacher").disabled(page == 0)
                    Text("\(page + 1) / \(pageCount.formatted())").font(.caption.monospacedDigit())
                    Button { largestPage = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                        .help("Weitere Speicherverursacher").disabled(page + 1 >= pageCount)
                }
                ForEach(Array(result.files.dropFirst(page * 8).prefix(8))) { file in fileRow(file, total: result.bytes) }
            }
            Text("APFS-Klone, Kompression und Sparse-Dateien können Größen beeinflussen. Die Duplikatgröße ist keine garantierte Speicherersparnis.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fileDetails(_ result: DiskScanResult) -> some View {
        let scope = folder ?? result.root.path
        let request = FileBrowserRequest(date: result.completedAt, scope: scope, query: query, fileCount: result.files.count)
        let size = 25
        return LazyVStack(alignment: .leading, spacing: 16) {
            if fileBrowser.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Ansicht wird im Hintergrund vorbereitet …").foregroundStyle(.secondary) }.padding(20)
            } else if let index = fileBrowser.index, fileBrowser.loadedRequest == request {
                HStack(spacing: 12) {
                    metric("Dateien", value: index.files.count.formatted(), detail: "Im aktuellen Bereich", icon: "doc.on.doc")
                    metric("Größe", value: diskBytes(index.bytes), detail: "Logische Größe der Treffer", icon: "internaldrive")
                    metric("Unterordner", value: index.folders.count.formatted(), detail: "Direkt in diesem Ordner", icon: "folder")
                }
                panel("Unterordner") {
                    browserPager(page: $folderPage, count: index.folders.count, size: size)
                    if index.folders.isEmpty { Text("Keine passenden Unterordner.").foregroundStyle(.secondary) }
                    ForEach(Array(index.folders.dropFirst(folderPage * size).prefix(size))) { item in
                        HStack(spacing: 16) {
                            Button { navigateFolder(item.name, root: result.root.path) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(.cyan).font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: item.name).lastPathComponent).font(.callout.weight(.medium))
                                        Text("\(item.count.formatted()) Dateien · inklusive Unterordner").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text(diskBytes(item.bytes)).font(.callout.monospacedDigit().weight(.semibold))
                                        ProgressView(value: Double(item.bytes), total: Double(max(1, result.bytes))).tint(.cyan).frame(width: 160)
                                    }
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("In MacTools öffnen")
                            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.name) } label: { Image(systemName: "arrow.up.forward.square") }.help("Im Finder öffnen")
                        }.padding(10).background(Color.cyan.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                panel("Dateien · größte zuerst") {
                    browserPager(page: $filePage, count: index.files.count, size: size)
                    if index.files.isEmpty { Text("Keine passenden Dateien.").foregroundStyle(.secondary) }
                    ForEach(Array(index.files.dropFirst(filePage * size).prefix(size)), id: \.self) { offset in fileRow(result.files[offset], total: result.bytes) }
                }
            } else if !fileBrowser.error.isEmpty {
                Text(fileBrowser.error).foregroundStyle(.orange)
            }
        }.task(id: request) {
            filePage = 0; folderPage = 0
            await fileBrowser.load(result, request: request)
        }
    }

    private func navigateFolder(_ path: String, root: String) {
        let current = folder ?? root
        if current != path { backFolders.append(current); forwardFolders = [] }
        folder = path == root ? nil : path
        query = ""; filePage = 0; folderPage = 0
    }

    private func browserNavigation(root: String, scope: String) -> some View {
        let parts = scope == root ? [] : String(scope.dropFirst(root.count)).split(separator: "/").map(String.init)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    Button {
                        guard let previous = backFolders.popLast() else { return }
                        forwardFolders.append(scope); folder = previous == root ? nil : previous; query = ""
                    } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                        .disabled(backFolders.isEmpty).help("Zurück").accessibilityLabel("Zurück im Ordnerverlauf")
                    Button {
                        guard let next = forwardFolders.popLast() else { return }
                        backFolders.append(scope); folder = next == root ? nil : next; query = ""
                    } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26) }
                        .disabled(forwardFolders.isEmpty).help("Vorwärts").accessibilityLabel("Vorwärts im Ordnerverlauf")
                    Divider().frame(height: 16)
                    Button {
                        navigateFolder((scope as NSString).deletingLastPathComponent, root: root)
                    } label: { Image(systemName: "arrow.up").frame(width: 26, height: 26) }
                        .disabled(scope == root).help("Eine Ebene höher").accessibilityLabel("Eine Ebene höher")
                }.buttonStyle(.plain).padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button { navigateFolder(root, root: root) } label: {
                            Label(URL(fileURLWithPath: root).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: root).lastPathComponent, systemImage: "house")
                        }.help("Zur Scan-Wurzel; Suchfilter zurücksetzen").accessibilityLabel("Scan-Wurzel")
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, name in
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Button(name) { navigateFolder(root + "/" + parts.prefix(index + 1).joined(separator: "/"), root: root) }
                                .font(.callout.weight(index == parts.count - 1 ? .semibold : .regular))
                                .foregroundStyle(index == parts.count - 1 ? Color.cyan : Color.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(index == parts.count - 1 ? Color.cyan.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }.buttonStyle(.plain).font(.callout)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Dateien & Ordner suchen", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .help("Suche löschen").accessibilityLabel("Suche löschen").buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(8).frame(width: 240).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(scope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    private func browserPager(page: Binding<Int>, count: Int, size: Int) -> some View {
        let pages = max(1, (count + size - 1) / size)
        return HStack {
            Text("\(count.formatted()) Treffer").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { page.wrappedValue = max(0, page.wrappedValue - 1) } label: { Image(systemName: "chevron.left") }.help("Vorherige Seite").disabled(page.wrappedValue == 0)
            Text("\(page.wrappedValue + 1) / \(pages.formatted())").font(.caption.monospacedDigit())
            Button { page.wrappedValue = min(pages - 1, page.wrappedValue + 1) } label: { Image(systemName: "chevron.right") }.help("Nächste Seite").disabled(page.wrappedValue + 1 >= pages)
        }
    }

    private func duplicateDetails(searchEnabled: Bool, totalBytes: Int64) -> some View {
        let size = 25
        let visible = mediaOnly ? duplicateIndex?.media ?? [] : duplicateIndex?.all ?? []
        let pageCount = max(1, (visible.count + size - 1) / size)
        let currentPage = min(duplicatePage, pageCount - 1)
        let groups = Array(visible.dropFirst(currentPage * size).prefix(size))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                metric("Medien & Dokumente", value: duplicateIndex?.media.count.formatted() ?? "…", detail: "\((duplicateIndex?.mediaCopies ?? 0).formatted()) zusätzliche Kopien · \(diskBytes(duplicateIndex?.mediaBytes ?? 0))", icon: "photo.on.rectangle")
                metric("Alle Dateitypen", value: duplicateIndex?.all.count.formatted() ?? "…", detail: "\((duplicateIndex?.totalCopies ?? 0).formatted()) zusätzliche Kopien · \(diskBytes(duplicateIndex?.allBytes ?? 0))", icon: "square.on.square")
            }
            HStack {
                Toggle("Nur Medien & Dokumente", isOn: $mediaOnly).toggleStyle(.switch)
                    .help("Bilder, GIFs, Videos, Audio, PDF, Office und CSV. Ausschalten zeigt auch Programm- und Library-Dateien.")
                Spacer()
                Text(mediaOnly ? "Programme & Libraries ausgeblendet" : "Alle Dateitypen sichtbar").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isScanning && !store.isSaving ? "Duplikate werden geprüft …" : "\(visible.count.formatted()) angezeigte Duplikatgruppen").font(.title3.bold())
                    Text("SHA-256 geprüft · Keine automatische Löschung").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Alle Duplikate auswählen") {
                    selectedCopies = duplicateIndex?.copiesForRemoval(mediaOnly: mediaOnly) ?? [:]
                }.disabled(visible.isEmpty || store.isScanning || store.isApplyingRemovals)
                    .help("Alle Seiten des aktuellen Filters auswählen; je Gruppe bleibt eine Kopie erhalten")
                if !selectedCopies.isEmpty {
                    Button("Auswahl leeren") { selectedCopies = [:] }
                }
                Button("In Papierkorb (\(selectedCopies.count)) …") {
                    pendingTrash = Array(selectedCopies.values).sorted { $0.path < $1.path }
                    confirmTrash = true
                }.disabled(selectedCopies.isEmpty || store.isScanning)
            }
            HStack {
                Text("Auswahl gilt für dieses Laufwerk und den aktuellen Filter, über alle Seiten. Je Gruppe bleibt eine Kopie erhalten.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Zurück") { duplicatePage = max(0, currentPage - 1); expandedDuplicateID = nil; duplicateFilePage = 0 }.disabled(currentPage == 0)
                Text("Seite \(currentPage + 1) / \(pageCount)").font(.caption).monospacedDigit()
                Button("Weiter") { duplicatePage = min(pageCount - 1, currentPage + 1); expandedDuplicateID = nil; duplicateFilePage = 0 }.disabled(currentPage + 1 >= pageCount)
            }
            if searchEnabled, duplicateIndex != nil { duplicateFolderPicker }
            if !searchEnabled { Text("Duplikatprüfung einschalten und erneut scannen.") }
            else if duplicateIndex == nil { ProgressView("Duplikatübersicht wird vorbereitet …") }
            else if visible.isEmpty { Text(store.isScanning ? "Die Dateiliste ist bereit. Die Inhaltsprüfung läuft im Hintergrund." : "Keine Duplikate gefunden.").font(.title3) }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        expandedDuplicateID = expandedDuplicateID == group.id ? nil : group.id
                        duplicateFilePage = 0
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: expandedDuplicateID == group.id ? "chevron.down" : "chevron.right").font(.caption)
                            Image(systemName: "square.on.square").foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.files.first?.url.lastPathComponent ?? "Identische Dateien").font(.headline).lineLimit(1)
                                Text("\(group.files.count.formatted()) Kopien · \(diskBytes(group.files.first?.bytes ?? 0)) je Datei").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(diskBytes(group.redundantBytes)).font(.headline).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    // Closed groups construct no file rows or Quick Look pickers.
                    if expandedDuplicateID == group.id { duplicateFiles(group, total: totalBytes) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("Mindestens eine Kopie bleibt erhalten. Beim Entfernen wird nur die Dateimetadaten-Prüfung verwendet, kein neuer Scan.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: mediaOnly) { _ in duplicatePage = 0; duplicateFolderPage = 0; expandedDuplicateID = nil; selectedCopies = [:] }

    }

    private var duplicateFolderPicker: some View {
        let directory = duplicateFolder ?? store.root.path
        let request = "\(showDuplicateFolders)-\(mediaOnly)-\(directory)-\(duplicateIndex.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
        return DisclosureGroup("Duplikate nach Ordner auswählen", isExpanded: $showDuplicateFolders) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wähle z. B. Unsorted gesammelt aus. Nur doppelte Dateien werden ausgewählt; eine Kopie bleibt erhalten, bevorzugt außerhalb des Ordners.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Alle Ordner") { duplicateFolder = nil; duplicateFolderPage = 0 }.disabled(duplicateFolder == nil)
                    Button { duplicateFolder = (directory as NSString).deletingLastPathComponent; duplicateFolderPage = 0 } label: { Image(systemName: "arrow.up") }
                        .disabled(duplicateFolder == nil || DiskScanner.canonicalPath(directory) == DiskScanner.canonicalPath(store.root.path)).help("Übergeordneten Ordner anzeigen")
                    Text(directory).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Diesen Ordner auswählen") { selectedCopies = duplicateIndex?.copiesForRemoval(mediaOnly: mediaOnly, inFolder: directory) ?? [:] }
                        .disabled(store.isScanning || store.isApplyingRemovals)
                }
                if duplicateFoldersLoading { ProgressView("Ordner werden gebündelt …") }
                else if duplicateFolders.isEmpty { Text("Keine weiteren Unterordner mit Duplikaten.").font(.caption).foregroundStyle(.secondary) }
                else {
                    let page = min(duplicateFolderPage, max(0, (duplicateFolders.count - 1) / 50))
                    ForEach(Array(duplicateFolders.dropFirst(page * 50).prefix(50))) { item in
                        HStack(spacing: 12) {
                            Button { duplicateFolder = item.path; duplicateFolderPage = 0 } label: {
                                Label((item.path as NSString).lastPathComponent, systemImage: "folder").font(.callout.weight(.semibold))
                            }.buttonStyle(.plain).help("Unterordner von " + item.path + " anzeigen")
                            Text("\(item.copies.formatted()) Kopien · \(diskBytes(item.bytes))").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Kopien auswählen") { selectedCopies = duplicateIndex?.copiesForRemoval(mediaOnly: mediaOnly, inFolder: item.path) ?? [:] }
                                .disabled(store.isScanning || store.isApplyingRemovals).accessibilityLabel("Duplikate in " + item.path + " auswählen")
                        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if duplicateFolders.count > 50 { browserPager(page: $duplicateFolderPage, count: duplicateFolders.count, size: 50) }
                }
            }.padding(.top, 10)
        }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .task(id: request) {
                duplicateFolders = []
                guard showDuplicateFolders, let index = duplicateIndex else { duplicateFoldersLoading = false; return }
                duplicateFoldersLoading = true
                let filter = mediaOnly
                let worker = Task.detached(priority: .userInitiated) { try index.folders(mediaOnly: filter, directory: directory) }
                do {
                    let values = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    duplicateFolders = values; duplicateFoldersLoading = false
                } catch { if !Task.isCancelled { duplicateFoldersLoading = false } }
            }
    }

    private func duplicateFiles(_ group: DuplicateGroup, total: Int64) -> some View {
        let size = 20
        let pageCount = max(1, (group.files.count + size - 1) / size)
        let page = min(duplicateFilePage, pageCount - 1)
        let files = Array(group.files.dropFirst(page * size).prefix(size))
        // Calculate once for the open group, rather than rescanning every group for every row.
        let unselected = group.files.reduce(0) { $0 + (selectedCopies[$1.path] == nil ? 1 : 0) }
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Button("Diese Seite vergleichen") { preview = FilePreviewSelection(files: files) }.disabled(files.count < 2)
                Button("Kopien dieser Seite auswählen") {
                    let retainedPath = group.files.first?.path
                    if let retainedPath { selectedCopies.removeValue(forKey: retainedPath) }
                    for file in files where file.path != retainedPath { selectedCopies[file.path] = file }
                }.disabled(!files.contains { $0.path != group.files.first?.path })
                Button("Alle Kopien dieser Gruppe auswählen") {
                    if let retained = group.files.first { selectedCopies.removeValue(forKey: retained.path) }
                    for file in group.files.dropFirst() { selectedCopies[file.path] = file }
                }
                Button("Gruppe abwählen") { for file in group.files { selectedCopies.removeValue(forKey: file.path) } }
            }
            let protectedCount = files.filter { DuplicateMediaSafety.requiresCaution($0) }.count
            if protectedCount > 0 {
                Text("\(protectedCount) Dateien dieser Seite gehören möglicherweise zu einer App, Library oder einem Projekt. Löschen kann Funktionen oder lokale Anhänge beeinträchtigen.").font(.caption).foregroundStyle(.secondary)
            }
            if pageCount > 1 {
                HStack {
                    Text("Dateien \(page * size + 1)–\(page * size + files.count) von \(group.files.count.formatted())").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Vorherige Dateien") { duplicateFilePage = max(0, page - 1) }.disabled(page == 0)
                    Button("Weitere Dateien") { duplicateFilePage = min(pageCount - 1, page + 1) }.disabled(page + 1 >= pageCount)
                }
            }
            ForEach(files) { file in
                HStack {
                    Toggle("Bereinigen: " + file.url.lastPathComponent, isOn: Binding(
                        get: { selectedCopies[file.path] != nil },
                        set: { selected in
                            if selected {
                                guard group.files.contains(where: { $0.path != file.path && selectedCopies[$0.path] == nil }) else { return }
                                selectedCopies[file.path] = file
                            } else { selectedCopies.removeValue(forKey: file.path) }
                        }
                    )).labelsHidden().disabled(selectedCopies[file.path] == nil && unselected <= 1)
                        .help("Kopie auswählen; mindestens eine Datei bleibt erhalten")
                    if DuplicateMediaSafety.requiresCaution(file) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("App-, Library- oder Projektdatei: Nur entfernen, wenn du diese Kopie nicht mehr benötigst.")
                    }
                    fileRow(file, total: total, allowTrash: false)
                    Button {
                        pendingTrash = [file]; confirmTrash = true
                    } label: { Image(systemName: "trash") }
                    .help("Diese Kopie in den Papierkorb verschieben")
                    .disabled(!group.files.contains { $0.path != file.path && selectedCopies[$0.path] == nil }
                        || store.isScanning)
                }
            }
        }
    }

    private var securityPanel: some View {
        SecurityScanPanel(store: store, security: security) { files in
            pendingTrash = files
            confirmTrash = true
        }
    }

    private func coverage(_ result: DiskScanResult) -> some View {
        Group {
            if result.skipped > 0 || result.reachedLimit {
                DisclosureGroup("Scan-Details · \(result.skipped.formatted()) Dateien nicht vollständig geprüft") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Einzelne geschützte oder während des Scans geänderte Dateien sind kein kritischer Befund. Diese Dateien werden bei der automatischen Bereinigung ausgelassen.")
                        if result.reachedLimit { Text("Dieses ältere Ergebnis hatte eine Dateigrenze. Neue Scans erfassen den gesamten gewählten Bereich.") }
                        ForEach(result.warningSamples, id: \.self) { Text($0).textSelection(.enabled) }
                        HStack {
                            Button("Zugriff prüfen") { store.checkAccess() }.disabled(store.isCheckingAccess)
                            Button("Festplattenvollzugriff") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                        }
                        if !store.accessStatus.isEmpty { Text(store.accessStatus) }
                    }.padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cyan.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.16)))
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private func fileRow(_ file: DiskFile, total: Int64, allowTrash: Bool = true) -> some View {
        if !store.isRemoved(file.path) {
        HStack(spacing: 12) {
            Image(systemName: "doc").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent).font(.callout).lineLimit(1)
                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(diskBytes(file.displayedBytes)).font(.callout.monospacedDigit().bold())
                    .help(file.isManagedVirtualDisk ? "Tatsächlich belegter Speicher. Virtuelle Maximalgröße: " + diskBytes(file.bytes) : "Logische Dateigröße")
                if file.isManagedVirtualDisk {
                    Label("Virtuelle Festplatte · geschützt", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                } else if file.bytes > 1_048_576 {
                    Text("Belegt: " + diskBytes(file.allocatedBytes)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Von macOS gemeldete Dateibelegung beim Scan. Die logische Dateigröße ist kein Maß dafür, wie viel Speicher das Entfernen freigibt.")
                }
                if !file.isManagedVirtualDisk { Text(percent(file.bytes, of: total)).font(.caption2).foregroundStyle(.secondary) }
            }
            Button { preview = FilePreviewSelection(files: [file]) } label: { Image(systemName: "eye") }
                .help("Dateivorschau")
            if allowTrash && !file.isManagedVirtualDisk {
                Button {
                    pendingTrash = [file]; confirmTrash = true
                } label: { Image(systemName: "trash") }
                    .help("In den Papierkorb verschieben").disabled(store.isScanning)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                .help("Im Finder anzeigen")
        }.padding(.vertical, 5)
        }
    }

    private func percent(_ bytes: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0 %" }
        return (Double(bytes) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }
}
