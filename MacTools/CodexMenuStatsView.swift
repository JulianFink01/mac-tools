import SwiftUI
import Charts

struct CodexMenuStatsView: View {
    @ObservedObject var settings: SettingsStore = .shared
    @ObservedObject var store: CodexStore = .shared
    let openChats: () -> Void
    let openSettings: () -> Void
    var openLimits: () -> Void = {}
    var newChat: (() -> Void)? = nil
    @State private var minutes = 10
    private var history: [CodexActivityPoint] { store.activityHistory.filter { $0.date > Date().addingTimeInterval(Double(-minutes * 60)) } }
    private var running: [CodexChat] { store.liveChats.filter { $0.status == "active" } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Codex", systemImage: "bubble.left.and.bubble.right").font(.headline).foregroundStyle(.mint)
                Spacer()
                if let newChat { Button(action: newChat) { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("Neuer Chat in eigenem Fenster").accessibilityLabel("Neuen Chat in eigenem Fenster starten") }
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Menüleisten-Favoriten einstellen").accessibilityLabel("Menüleisten-Favoriten einstellen")
                Button(action: openChats) { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("Alle Codex-Chats öffnen").accessibilityLabel("Alle Codex-Chats öffnen")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(running.count)").font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("laufende Chats").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(store.connected ? .green : .secondary).frame(width: 7, height: 7).accessibilityLabel(store.connected ? "Verbunden" : "Nicht verbunden")
            }
            HStack(spacing: 14) {
                stat("Warten auf dich", value: store.waitingCount, icon: "hand.raised", color: .orange)
                stat("Letzte 24 Stunden", value: store.recentChats.count, icon: "clock", color: .mint)
            }
            CodexUsageWidget(store: store, height: 86, open: openLimits)
            HStack {
                Label("\(store.queuedMessages.values.reduce(0) { $0 + $1.count }) in MacTools wartend", systemImage: "text.line.first.and.arrowtriangle.forward")
                Spacer()
                Button { Task { await store.loadUsage(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Codex-Limits aktualisieren")
            }.font(.caption).foregroundStyle(.secondary)
            HStack { Text("VERLAUF").font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Picker("Zeitraum", selection: $minutes) { Text("2 Min.").tag(2); Text("10 Min.").tag(10); Text("30 Min.").tag(30) }.labelsHidden().frame(width: 95) }
            Chart(history) { point in
                AreaMark(x: .value("Zeit", point.date), y: .value("Laufend", point.running)).foregroundStyle(LinearGradient(colors: [.mint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.stepEnd)
                LineMark(x: .value("Zeit", point.date), y: .value("Laufend", point.running)).foregroundStyle(.mint).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.stepEnd)
            }.chartXScale(domain: Date().addingTimeInterval(Double(-minutes * 60))...Date()).chartYScale(domain: 0...max(1, (history.map(\.running).max() ?? 1) + 1)).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 90)
                .accessibilityLabel("Verlauf der laufenden Codex-Chats seit dem App-Start")
            Text("Seit App-Start · Aktualisierung alle 10 Sekunden").font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            if running.isEmpty { Text("Gerade laufen keine Chats.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.liveChats.filter { $0.status == "active" || store.waitingChatIDs.contains($0.id) }) { chat in
                        HStack {
                        Button { openChats(); Task { await store.select(chat.id) } } label: {
                            HStack(alignment: .top, spacing: 9) {
                                VStack(alignment: .leading, spacing: 4) { Text(chat.title).font(.callout.weight(.medium)).foregroundStyle(store.waitingChatIDs.contains(chat.id) ? Color.orange : .green).lineLimit(2); Text(store.folderName(store.folder(for: chat)) + " · " + (store.waitingChatIDs.contains(chat.id) ? "Wartet auf deine Eingabe" : chat.statusLabel)).font(.caption).foregroundStyle(.secondary) }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        CodexChatActions(settings: settings, chatID: chat.id, title: chat.title, open: { CodexPopupController.shared.show(chatID: chat.id) })
                        }
                    }
                }
            }.scrollIndicators(.hidden).frame(maxHeight: 190)
            Text("\(store.liveChats.count) geladene Chats · Subagenten im jeweiligen Chat").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18) }.scrollIndicators(.hidden).frame(width: 390).onAppear { store.start() }
    }
    private func stat(_ title: String, value: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }
}
