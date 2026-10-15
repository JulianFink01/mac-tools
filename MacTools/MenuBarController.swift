import AppKit
import SwiftUI
import Combine

extension Notification.Name { static let showMacToolsQuickPanel = Notification.Name("showMacToolsQuickPanel") }

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var observer: NSObjectProtocol?

    init(settings: SettingsStore, library: VideoLibraryStore,
         openSection: @escaping (ToolNavigation.Section) -> Void,
         openSettings: @escaping (SettingsCategory) -> Void,
         randomWallpaper: @escaping () -> Void) {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "MacTools Schnellaktionen")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.toolTip = "MacTools · Live-Übersicht & Schnellaktionen"
            button.target = self; button.action = #selector(togglePanel)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 660)
        popover.contentViewController = NSHostingController(rootView: QuickPanelView(settings: settings, library: library,
            openSection: { [weak self] section in self?.popover.close(); openSection(section) },
            openSettings: { [weak self] category in self?.popover.close(); openSettings(category) },
            pin: { [weak self] in self?.popover.close(); WindowPinController.shared.toggleCurrentWindow(useMenuSelection: true) },
            randomWallpaper: randomWallpaper))
        observer = NotificationCenter.default.addObserver(forName: .showMacToolsQuickPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.togglePanel() }
        }
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.close(); return }
        guard let button = statusItem.button else { return }
        WindowPinController.shared.prepareMenuSelection()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/// A single measured text block avoids NSButtonCell's different baselines for two fonts.
/// The parent status button retains native highlighting, accessibility and mouse handling.
final class MonitorWidgetLabel: NSView {
    let metric: MonitorMetric
    var value = "—" { didSet { if oldValue != value { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    init(metric: MonitorMetric, frame: NSRect) {
        self.metric = metric
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: metric.title.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.labelColor])
        let number = NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let labelSize = label.size(), numberSize = number.size()
        let spacing: CGFloat = -1
        let height = labelSize.height + numberSize.height + spacing
        let top = (bounds.height - height) / 2
        label.draw(at: NSPoint(x: (bounds.width - labelSize.width) / 2, y: top))
        number.draw(at: NSPoint(x: (bounds.width - numberSize.width) / 2, y: top + labelSize.height + spacing))
    }
}

struct MonitorWidgetPreview: NSViewRepresentable {
    let metric: MonitorMetric
    @ObservedObject private var monitor = SystemMonitor.shared
    func makeNSView(context: Context) -> MonitorWidgetLabel {
        MonitorWidgetLabel(metric: metric, frame: NSRect(x: 0, y: 0, width: 42, height: NSStatusBar.system.thickness))
    }
    func updateNSView(_ view: MonitorWidgetLabel, context: Context) {
        view.value = monitorPercent(metric.value(in: monitor.reading)).replacingOccurrences(of: " ", with: "")
    }
}

@MainActor
final class MonitorMenuWidgets: NSObject {
    private var items: [MonitorMetric: NSStatusItem] = [:]
    private var labels: [MonitorMetric: MonitorWidgetLabel] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private let settings: SettingsStore
    private let openMonitor: () -> Void
    private let openSettings: () -> Void
    private let popover = NSPopover()
    private var selected: MonitorMetric?

    init(settings: SettingsStore, openMonitor: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.settings = settings; self.openMonitor = openMonitor; self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        settings.$enabledMonitorWidgets.sink { [weak self] metrics in self?.synchronize(metrics) }.store(in: &subscriptions)
        SystemMonitor.shared.$reading.sink { [weak self] reading in self?.update(reading) }.store(in: &subscriptions)
    }
    private func synchronize(_ enabled: Set<MonitorMetric>) {
        for metric in MonitorMetric.allCases {
            if enabled.contains(metric), items[metric] == nil {
                let item = NSStatusBar.system.statusItem(withLength: 42)
                items[metric] = item
                if let button = item.button {
                    button.target = self; button.action = #selector(widgetClicked(_:))
                    button.image = nil; button.imagePosition = .noImage
                    button.title = ""
                    let label = MonitorWidgetLabel(metric: metric, frame: button.bounds)
                    labels[metric] = label
                    button.addSubview(label)
                    button.setAccessibilityLabel("MacTools " + metric.title)
                }
            } else if !enabled.contains(metric), let item = items.removeValue(forKey: metric) {
                if selected == metric { popover.close(); selected = nil }
                labels.removeValue(forKey: metric)
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        update(SystemMonitor.shared.reading)
    }
    private func update(_ reading: SystemReading?) {
        for (metric, item) in items {
            guard let button = item.button else { continue }
            let value = monitorPercent(metric.value(in: reading)).replacingOccurrences(of: " ", with: "")
            labels[metric]?.value = value
            button.toolTip = "MacTools · " + metric.title + " " + value + " · " + metric.settingsDetail
            button.setAccessibilityValue(value)
        }
    }
    @objc private func widgetClicked(_ sender: NSStatusBarButton) {
        guard let metric = items.first(where: { $0.value.button === sender })?.key else { return }
        if popover.isShown && selected == metric { popover.close(); selected = nil; return }
        popover.close(); selected = metric
        popover.contentViewController = NSHostingController(rootView: MonitorDetailView(metric: metric,
            openMonitor: { [weak self] in self?.popover.close(); self?.openMonitor() },
            openSettings: { [weak self] in self?.popover.close(); self?.openSettings() }))
        popover.contentSize = NSSize(width: 360, height: metric == .ram || metric == .cpu ? 700 : 580)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

struct QuickPanelView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: VideoLibraryStore
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var disk = DiskScanStore.shared
    @ObservedObject private var security = SecurityScanStore.shared
    @ObservedObject private var window = WindowPinController.shared
    @ObservedObject private var warnings = AutomaticScans.shared
    let openSection: (ToolNavigation.Section) -> Void
    let openSettings: (SettingsCategory) -> Void
    let pin: () -> Void
    let randomWallpaper: () -> Void
    @State private var selectedMetric: MonitorMetric?
    @State private var selectedEvent = 0
    @State private var previousTopEvent = ""
    private var points: [MonitorPoint] { Array(monitor.history.suffix(60)) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("MacTools").font(.title3.bold())
                Spacer()
                Label("Live", systemImage: "circle.fill").font(.caption2).foregroundStyle(.green)
                Button { openSection(.monitoring) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("Systemmonitor öffnen")
            }
            liveEvents
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button { selectedMetric = .cpu } label: { MonitorMetricCard(title: "CPU", icon: "cpu", value: monitorPercent(monitor.reading?.point.cpu), detail: "Gesamte Auslastung", color: .cyan, points: points, key: \.cpu, compact: true) }.buttonStyle(.plain)
                Button { selectedMetric = .ram } label: { MonitorMetricCard(title: "RAM", icon: "memorychip", value: monitorPercent(monitor.reading?.point.memory), detail: monitor.reading.map { diskBytes(Int64($0.totalMemory)) + " gesamt" } ?? "Wird gemessen", color: .purple, points: points, key: \.memory, compact: true) }.buttonStyle(.plain)
                Button { selectedMetric = .gpu } label: { MonitorMetricCard(title: "GPU", icon: "square.3.layers.3d", value: monitorPercent(monitor.reading?.point.gpu), detail: monitor.reading?.point.gpu == nil ? "Nicht verfügbar" : (monitor.reading?.gpuName ?? "GPU"), color: .mint, points: points, key: \.gpu, compact: true) }.buttonStyle(.plain)
                Button { selectedMetric = .disk } label: { MonitorMetricCard(title: "Disk · Lesen", icon: "internaldrive", value: monitorRate(monitor.reading?.point.diskRead), detail: "Schreiben " + monitorRate(monitor.reading?.point.diskWrite), color: .orange, points: points, key: \.diskRead, percent: false, compact: true) }.buttonStyle(.plain)
            }
            if let volume = monitor.reading?.volumes.first { MonitorVolumeCard(volume: volume, compact: true) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                quickButton("Fenster anheften / lösen", icon: window.isPinned ? "pin.slash" : "pin.fill", color: .blue, action: pin)
                    .help(window.isPinned ? window.windowTitle : "Aktuelles Fenster · " + window.shortcutTitle)
                quickButton(disk.isScanning ? "Scan öffnen" : "Speicher scannen", icon: "magnifyingglass", color: .cyan) {
                    if !disk.isScanning && !security.isScanning && !security.isUpdating { warnings.runNow() }
                    openSection(.disk)
                }
                quickButton("Systemmonitor", icon: "waveform.path.ecg", color: .mint) { openSection(.monitoring) }
                quickButton(settings.isPaused ? "Hintergrund starten" : "Hintergrund pausieren", icon: settings.isPaused ? "play.fill" : "pause.fill", color: .purple) { settings.setPaused(!settings.isPaused) }
                    .disabled(library.videos.isEmpty)
            }
            HStack {
                Button { openSection(.disk) } label: {
                    Label(security.report?.threatCount ?? 0 > 0 ? "Funde prüfen" : warnings.warnings.isEmpty ? "Disk & Sicherheit" : "\(warnings.warnings.count) Warnungen", systemImage: "shield")
                }.buttonStyle(.plain).font(.caption)
                Spacer()
                Button { randomWallpaper() } label: { Label("Video wechseln", systemImage: "shuffle").font(.caption) }.buttonStyle(.plain).disabled(library.videos.isEmpty).help("Zufälliger Hintergrund")
                Button { openSettings(.general) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Einstellungen")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).help("MacTools beenden")
            }.foregroundStyle(.secondary)
        }.padding(16).frame(width: 420, height: 660, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $selectedMetric) { metric in
                VStack(spacing: 0) {
                    MonitorDetailView(metric: metric)
                    Button("Zurück") { selectedMetric = nil }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                }
            }
    }
    private struct LiveEvent: Identifiable {
        let id: String
        let priority: Int
        let title: String
        let detail: String
        let icon: String
        let color: Color
        let section: ToolNavigation.Section
        var pinID: UUID? = nil
        var fraction: Double? = nil
    }
    private var events: [LiveEvent] {
        var values: [LiveEvent] = []
        if let report = security.report, report.threatCount > 0 {
            values.append(LiveEvent(id: "threats", priority: 100, title: "\(report.threatCount) verdächtige Dateien", detail: "Funde in Disk & Sicherheit prüfen", icon: "shield.lefthalf.filled", color: .red, section: .disk))
        }
        if disk.isScanning || disk.isSaving || security.isScanning || security.isUpdating {
            values.append(LiveEvent(id: "scan", priority: 90, title: disk.isScanning ? "Scan läuft · \(disk.progress.files.formatted()) Dateien" : "Virenschutz läuft", detail: disk.isScanning ? disk.progress.phase : security.status, icon: "waveform.path", color: .cyan, section: .disk, fraction: disk.isScanning ? disk.progress.fraction : security.progressFraction))
        }
        for item in window.pinnedWindows {
            values.append(LiveEvent(id: item.id.uuidString, priority: 80, title: item.application + " · angeheftet", detail: item.title, icon: "pin.fill", color: .blue, section: .windows, pinID: item.id))
        }
        if let volume = monitor.reading?.volumes.first, volume.free < 10_000_000_000 {
            values.append(LiveEvent(id: "disk", priority: 70, title: "Wenig freier Speicher", detail: diskBytes(volume.free) + " frei", icon: "externaldrive.badge.exclamationmark", color: .orange, section: .disk))
        }
        if let result = disk.result {
            values.append(LiveEvent(id: "last-scan", priority: 10, title: "Letzter Scan · \(result.files.count.formatted()) Dateien", detail: diskBytes(result.bytes) + " · " + result.completedAt.formatted(date: .abbreviated, time: .shortened), icon: "chart.bar.xaxis", color: .cyan, section: .disk))
        }
        if values.isEmpty { values.append(LiveEvent(id: "ready", priority: 0, title: "Dein Mac im Blick", detail: "Live-Messungen aktiv · Starte einen Gesamtscan", icon: "checkmark.shield", color: .green, section: .disk)) }
        return values.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
    }
    private var liveEvents: some View {
        let values = events
        let page = min(selectedEvent, values.count - 1)
        let event = values[page]
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: event.icon).foregroundStyle(event.color).font(.title3)
                Button { openSection(event.section) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let fraction = event.fraction { ProgressView(value: fraction).tint(event.color) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                if let id = event.pinID {
                    Button("Lösen") { window.unpin(id: id) }.controlSize(.small).accessibilityLabel(event.title + " lösen")
                } else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(height: 72).frame(maxWidth: .infinity)
                .background(event.color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Text("Live-Ereignisse").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { selectedEvent = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(page == 0).accessibilityLabel("Vorheriges Ereignis")
                Text("\(page + 1) / \(values.count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Button { selectedEvent = min(values.count - 1, page + 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(page + 1 == values.count).accessibilityLabel("Nächstes Ereignis")
            }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            selectedEvent = min(values.count - 1, max(0, page + (value.translation.width < 0 ? 1 : -1)))
        }).onChange(of: values.map(\.id)) { ids in
            if previousTopEvent != ids.first { selectedEvent = 0; previousTopEvent = ids.first ?? "" }
            else { selectedEvent = min(selectedEvent, max(0, ids.count - 1)) }
        }
    }

    private func quickButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity).background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}
