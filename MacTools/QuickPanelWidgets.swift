import SwiftUI

/// Shared, quiet navigation for the live cards. The full button is clickable.
struct CompactCardPager: View {
    let index: Int
    let count: Int
    let item: String
    var compact = false
    let previous: () -> Void
    let next: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", label: "Vorheriger " + item, enabled: index > 0, action: previous)
            Text("\(index + 1) / \(count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: compact ? 28 : 38)
                .accessibilityLabel("\(item) \(index + 1) von \(count)")
            arrow("chevron.right", label: "Nächster " + item, enabled: index + 1 < count, action: next)
        }.padding(2).background(Color.primary.opacity(0.045), in: Capsule())
    }
    private func arrow(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), action) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: compact ? 18 : 26, height: 22).contentShape(Capsule())
        }.buttonStyle(CardPagerButtonStyle()).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}

private struct CardPagerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardPagerButton(configuration: configuration)
    }
    private struct CardPagerButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label.foregroundStyle(Color.primary.opacity(enabled ? 0.8 : 0.2))
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.08 : 0), in: Capsule())
                .onHover { hovering = $0 }
        }
    }
}

enum QuickPanelWidget: String, CaseIterable, Identifiable, Codable {
    case liveFeed, codex, codexLimit, cpu, ram, gpu, disk, volume, pin, scan, monitor, wallpaper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liveFeed: return "Live-Ereignisse"
        case .codex: return "Codex-Chats"
        case .codexLimit: return "Codex-Limit"
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .gpu: return "GPU"
        case .disk: return "Disk · Lesen"
        case .volume: return "Freier Speicher"
        case .pin: return "Fenster anheften"
        case .scan: return "Speicher scannen"
        case .monitor: return "Systemmonitor öffnen"
        case .wallpaper: return "Hintergrund pausieren"
        }
    }
    var group: Int { switch self { case .cpu, .ram, .gpu, .disk: return 1; case .pin, .scan, .monitor, .wallpaper: return 2; default: return 0 } }
    static func rows(_ widgets: [QuickPanelWidget], usagePlacement: String = "separate") -> [[QuickPanelWidget]] {
        var widgets = widgets
        if widgets.contains(.codexLimit), usagePlacement != "separate" {
            let target = usagePlacement == "chats" ? widgets.firstIndex(of: .codex) : widgets.firstIndex(where: { $0.group == 1 })
            if target != nil { widgets.removeAll { $0 == .codexLimit }; let destination = usagePlacement == "chats" ? widgets.firstIndex(of: .codex) : widgets.firstIndex(where: { $0.group == 1 }); widgets.insert(.codexLimit, at: destination ?? widgets.count) }
        }
        var result: [[QuickPanelWidget]] = []
        for widget in widgets {
            if usagePlacement == "chats", widget == .codex, result.last == [.codexLimit] { result[result.count - 1].append(widget) }
            else if let last = result.last, (widget.group != 0 || widget == .codexLimit && usagePlacement == "metrics"),
                    (last.first?.group == widget.group || last.first == .codexLimit && usagePlacement == "metrics" && widget.group == 1), last.count < (widget.group == 1 ? 4 : 2) { result[result.count - 1].append(widget) }
            else { result.append([widget]) }
        }
        // Avoid a single narrow orphan when five metrics share the available width.
        if usagePlacement == "metrics", let index = result.firstIndex(where: { $0.contains(.codexLimit) && $0.count == 4 }), result.indices.contains(index + 1), result[index + 1].count == 1, result[index + 1][0].group == 1 {
            result[index + 1].insert(result[index].removeLast(), at: 0)
        }
        return result
    }

}

struct QuickPanelSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        ToolSettingsCard(title: "Schnellansicht anpassen", description: "Verschiebe die sichtbaren Widgets direkt in der Vorschau. Über − und + entfernst du Widgets oder fügst sie wieder hinzu. Dieselbe Bearbeitung öffnest du auch direkt oben in der Schnellansicht.") {
            HStack(alignment: .top, spacing: 28) {
                QuickPanelView(settings: settings, library: VideoLibraryStore.shared, openSection: { _ in }, openSettings: { _ in }, pin: {}, randomWallpaper: {}, startsEditing: true)
                    .frame(width: 420, height: 640).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Deine Anordnung wird sofort übernommen.").font(.headline)
                    Text("Ziehe an den Widgets, um die Reihenfolge live zu verändern. Die Karten und Messwerte entsprechen der echten Schnellansicht.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Ereignisse mit Tabs", isOn: $settings.quickPanelEventTabs)
                    Picker("Codex-Limit platzieren", selection: $settings.codexLimitPlacement) { Text("Eigene Zeile").tag("separate"); Text("Neben Codex-Chats").tag("chats"); Text("Neben Messwerten").tag("metrics") }
                    Toggle("Kompakte Speicherkachel", isOn: $settings.quickPanelCompactVolume)
                    Button("Standard wiederherstellen") { withAnimation { settings.quickPanelWidgets = QuickPanelWidget.allCases } }
                }.frame(maxWidth: 340, alignment: .leading).padding(.top, 12)
                Spacer(minLength: 0)
            }
        }
    }
}

struct QuickWidgetDrop: DropDelegate {
    let target: QuickPanelWidget
    let settings: SettingsStore
    @Binding var dragged: QuickPanelWidget?
    func validateDrop(info: DropInfo) -> Bool { dragged != nil }
    func dropEntered(info: DropInfo) {
        guard let source = dragged, source != target, let index = settings.quickPanelWidgets.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if !settings.quickPanelWidgets.contains(source) { settings.quickPanelWidgets.insert(source, at: index) }
            else { settings.moveQuickWidget(source, to: index) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}

/// Spend spare vertical space on useful extra cards, preferring running chats.
enum QuickPanelCardLayout {
    static func eventPages(ids: [String], containerIDs: Set<String>, rows: Int) -> [[String]] {
        var remaining = ids, pages: [[String]] = []
        while !remaining.isEmpty {
            var page: [String] = [], containers = 0
            for id in remaining where page.count < max(1, rows) {
                if containerIDs.contains(id) { if containers >= 2 { continue }; containers += 1 }
                page.append(id)
            }
            let selected = Set(page); remaining.removeAll { selected.contains($0) }; pages.append(page)
        }
        return pages
    }
    static func page(selectedID: String?, fallback: Int, ids: [String], rows: Int) -> Int {
        let rows = max(1, rows)
        if let selectedID, let index = ids.firstIndex(of: selectedID) { return index / rows }
        return min(max(0, fallback), max(0, (ids.count - 1) / rows))
    }

    static func volumeHeight(count: Int, compact: Bool) -> CGFloat {
        CGFloat(max(0, count)) * (compact ? 58 : 120) + CGFloat(max(0, count - 1)) * 8
    }
    static func counts(widgets: [QuickPanelWidget], height: CGFloat, multipleRunningChats: Bool, eventCount: Int, compactVolume: Bool, eventTabs: Bool, usagePlacement: String = "separate", volumeCount: Int = 1) -> (codex: Int, events: Int) {
        let rows = QuickPanelWidget.rows(widgets, usagePlacement: usagePlacement)
        let base = rows.reduce(CGFloat(0)) { total, row in
            let widget = row[0]
            let size: CGFloat = row.contains(.codexLimit) && row.contains(.codex) && usagePlacement == "chats" ? 144 : widget.group == 1 ? 82 : widget.group == 2 ? 42 : widget == .codexLimit ? (usagePlacement == "separate" ? 64 : usagePlacement == "metrics" ? 86 : 64) : widget == .volume ? volumeHeight(count: volumeCount, compact: compactVolume) : widget == .liveFeed ? (eventTabs ? 118 : 88) : 64
            return total + size
        } + CGFloat(max(0, rows.count - 1)) * 10
        var spare = height - base
        var codex = 1, events = 1
        if widgets.contains(.codex), multipleRunningChats {
            if usagePlacement == "chats", widgets.contains(.codexLimit) { codex = 2 }
            else if spare >= 72 { codex = 2; spare -= 72 }
        }
        if widgets.contains(.liveFeed) {
            while events < min(4, eventCount), spare >= 72 { events += 1; spare -= 72 }
        }
        return (codex, events)
    }
}
