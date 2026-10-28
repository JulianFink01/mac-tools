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
    @AppStorage("codexUsagePeriod") private var periodRaw = CodexUsagePeriod.week.rawValue
    private var period: CodexUsagePeriod { CodexUsagePeriod(rawValue: periodRaw) ?? .week }
    private var history: [CodexActivityPoint] { store.activityHistory.filter { $0.date > Date().addingTimeInterval(Double(-minutes * 60)) } }
    private var running: [CodexChat] { store.liveChats.filter { $0.status == "active" } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Codex", systemImage: "bubble.left.and.bubble.right").font(.headline).foregroundStyle(.mint)
                Spacer()
                Button { Task { await store.loadUsage(force: true); await store.loadLocalStats(force: true); await store.loadLocalUsageHistory(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Limits und Nutzungsstatistik aktualisieren").accessibilityLabel("Codex-Statistik aktualisieren")
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
            usageStats
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
                                VStack(alignment: .leading, spacing: 4) { Text(chat.title).font(.callout.weight(.medium)).foregroundStyle(store.waitingChatIDs.contains(chat.id) ? Color.blue : .green).lineLimit(2); Text(store.folderName(store.folder(for: chat)) + " · " + (store.waitingChatIDs.contains(chat.id) ? "Wartet auf deine Eingabe" : chat.statusLabel)).font(.caption).foregroundStyle(.secondary) }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        CodexChatActions(settings: settings, chatID: chat.id, title: chat.title, open: { CodexPopupController.shared.show(chatID: chat.id) })
                        }
                    }
                }
            }.scrollIndicators(.hidden).frame(maxHeight: 190)
            Text("\(store.liveChats.count) geladene Chats · Subagenten im jeweiligen Chat").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18) }.scrollIndicators(.hidden).frame(width: 390).task {
            store.start()
            while !Task.isCancelled {
                await store.loadLocalStats()
                await store.loadLocalUsageHistory()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
    private var usageStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LOKALE NUTZUNG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if store.readingLocalStats { ProgressView().controlSize(.mini) }
                else if let date = store.localStats?.updatedAt { Text(date, style: .time).font(.caption2).foregroundStyle(.secondary) }
            }
            Picker("Nutzungszeitraum", selection: $periodRaw) {
                ForEach(CodexUsagePeriod.allCases) { value in Text(value.label).tag(value.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Nutzungszeitraum")
            if period != .all {
                if let history = store.localUsageHistory {
                    let summary = history.summary(start: period.start(now: Date(), calendar: history.calendar))
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Erfasste Tokens", systemImage: "number").font(.caption).foregroundStyle(.secondary)
                            Text(CodexUsageFormat.tokens(summary.totals.total)).font(.title2.weight(.semibold)).monospacedDigit().help(summary.totals.total.formatted() + " Tokens")
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Chats mit Tokens", systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(.secondary)
                            Text(summary.chats.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                        }
                    }
                    Text("MODELLE · TOKENS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(summary.models.prefix(5))) { model in
                        HStack { Text(model.name).lineLimit(1); Spacer(); Text(CodexUsageFormat.tokens(model.tokens)).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                    }
                    if summary.chats == 0 { Text("Keine Tokenereignisse in diesem Zeitraum erfasst.").font(.caption).foregroundStyle(.secondary) }
                    Text(history.coverageText).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack { if store.readingUsageHistory { ProgressView().controlSize(.small) }; Text(store.localUsageHistoryError ?? "Tokenverlauf wird einmalig erfasst …").font(.caption).foregroundStyle(.secondary) }
                }
            } else if let stats = store.localStats {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Tokens gesamt", systemImage: "number").font(.caption).foregroundStyle(.secondary)
                        Text(Double(stats.totalTokens).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))).font(.title2.weight(.semibold)).monospacedDigit()
                            .help(stats.totalTokens.formatted() + " lokal gespeicherte Tokens, inklusive Cache-Eingaben")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Chats mit Tokens", systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(.secondary)
                        Text("\(stats.chatsWithTokens.formatted()) / \(stats.chats.formatted())").font(.title3.weight(.semibold)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !stats.models.isEmpty {
                    Text("MODELLE · ANZAHL CHATS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(stats.models.prefix(5))) { model in
                        VStack(spacing: 4) {
                            HStack { Text(model.name).lineLimit(1); Spacer(); Text(model.chats.formatted()).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                            GeometryReader { proxy in
                                Capsule().fill(Color.mint.opacity(0.7)).frame(width: max(2, proxy.size.width * Double(model.chats) / Double(max(1, stats.chats))))
                            }.frame(height: 3).background(Color.primary.opacity(0.06), in: Capsule())
                        }.accessibilityElement(children: .ignore).accessibilityLabel("\(model.name): \(model.chats) Chats")
                    }
                    if stats.models.count > 5 { Text("Weitere \(stats.models.count - 5) Modelle · \(stats.models.dropFirst(5).reduce(0) { $0 + $1.chats }) Chats").font(.caption2).foregroundStyle(.secondary) }
                }
                Text("Gesamter lokaler Verlauf inkl. Archiv und Subagenten. Modell pro Chat: zuletzt gespeichert. Tokenzähler inkl. Cache und wiederholter Eingaben; keine Abrechnungswerte.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.localStatsError == nil { Text("Nutzungsstatistik wird geladen …").font(.caption).foregroundStyle(.secondary) }
            if store.readingUsageHistory && store.localUsageHistory != nil { HStack { ProgressView().controlSize(.mini); Text("Verlauf wird aktualisiert …").font(.caption2).foregroundStyle(.secondary) } }
            if let error = store.localUsageHistoryError, store.localUsageHistory != nil { Text("Letzter Stand · " + error).font(.caption).foregroundStyle(.orange) }
            Button(action: openLimits) { Label("Details & Monatsvergleich", systemImage: "chart.bar.xaxis") }.buttonStyle(.plain).font(.caption).foregroundStyle(.mint).accessibilityLabel("Nutzungsdetails und Monatsvergleich öffnen")
            if let error = store.localStatsError { Text((store.localStats == nil ? "" : "Letzter Stand · ") + error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }
    private func stat(_ title: String, value: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }
}
