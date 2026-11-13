import SwiftUI
import Charts

func monitorPercent(_ value: Double?) -> String {
    value.map { String(format: "%.0f %%", $0) } ?? "—"
}
func monitorRate(_ value: Double?) -> String {
    value.map { diskBytes(Int64(max(0, $0))) + "/s" } ?? "—"
}

struct MonitorTrend: View {
    let points: [MonitorPoint]
    let key: KeyPath<MonitorPoint, Double?>
    let color: Color
    var percent = true
    var compact = false
    private var values: [(MonitorPoint, Int)] {
        var segment = 0
        return points.enumerated().compactMap { index, point in
            if index > 0 && point.date.timeIntervalSince(points[index - 1].date) > 10 { segment += 1 }
            guard point[keyPath: key] != nil else { segment += 1; return nil }
            return (point, segment)
        }
    }
    @ViewBuilder var body: some View {
        if compact {
            compactTrend
        } else {
            chart
        }
    }
    // A compact plot needs two paths, not hundreds of individual chart marks.
    // Keep every measurement and split paths across missing samples/time gaps.
    private var compactTrend: some View {
        let samples = values
        let maximum = percent ? 100 : max(1, samples.compactMap { $0.0[keyPath: key] }.max() ?? 1)
        return Canvas { context, size in
            guard let first = points.first?.date, let last = points.last?.date else { return }
            let duration = max(1, last.timeIntervalSince(first))
            var line = Path(), area = Path(), start: CGPoint?, end: CGPoint?, currentSegment: Int?
            func drawSegment() {
                guard let start, let end else { return }
                area.addLine(to: CGPoint(x: end.x, y: size.height))
                area.addLine(to: CGPoint(x: start.x, y: size.height)); area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.3), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color), lineWidth: 1.8)
            }
            for (sample, segment) in samples {
                guard let value = sample[keyPath: key] else { continue }
                let point = CGPoint(x: sample.date.timeIntervalSince(first) / duration * size.width,
                                    y: (1 - min(1, max(0, value / maximum))) * size.height)
                if currentSegment != segment {
                    drawSegment(); line = Path(); area = Path(); start = point
                    line.move(to: point); area.move(to: point); currentSegment = segment
                } else {
                    line.addLine(to: point); area.addLine(to: point)
                }
                end = point
            }
            drawSegment()
        }.accessibilityLabel("Messverlauf")
            .accessibilityValue(samples.last.flatMap { $0.0[keyPath: key] }.map { percent ? monitorPercent($0) : monitorRate($0) } ?? "Keine Messung")
    }
    /// Swift Charts lays out and keeps every single mark. Half an hour of samples is
    /// far more marks than the plot has pixels, so the curve is drawn from a reduced
    /// set of points instead of several thousand.
    private func reduced(_ samples: [(MonitorPoint, Int)], limit: Int) -> [(MonitorPoint, Int)] {
        guard limit > 1, samples.count > limit else { return samples }
        let step = Double(samples.count) / Double(limit)
        var result: [(MonitorPoint, Int)] = []
        var next = 0.0
        for (index, sample) in samples.enumerated() {
            // Both ends of a segment stay, so missing measurements remain a gap.
            let edge = index == 0 || index == samples.count - 1 || sample.1 != samples[index - 1].1
                || (index + 1 < samples.count && samples[index + 1].1 != sample.1)
            guard edge || Double(index) >= next else { continue }
            result.append(sample)
            next = Double(index) + step
        }
        return result
    }
    private var chart: some View {
        let samples = reduced(values, limit: 180)
        let maximum = percent ? 100 : max(1, samples.compactMap { $0.0[keyPath: key] }.max() ?? 1)
        return Chart {
            ForEach(samples, id: \.0.id) { point, segment in
                if let value = point[keyPath: key] {
                    AreaMark(x: .value("Zeit", point.date), yStart: .value("Basis", 0), yEnd: .value("Wert", value), series: .value("Abschnitt", segment))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", point.date), y: .value("Wert", value), series: .value("Abschnitt", segment))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
        }
        .chartYScale(domain: 0...maximum)
        .chartLegend(.hidden)
        .chartXAxis {
            if !compact { AxisMarks(values: .automatic(desiredCount: 2)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel(format: .dateTime.hour().minute())
            } }
        }
        .chartYAxis {
            if !compact { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(percent ? String(format: "%.0f", number) : diskBytes(Int64(number))).font(.caption2)
                    }
                }
            } }
        }
        .accessibilityLabel("Messverlauf")
    }
}

/// Which process asks the GPU to do work. The window server appears for everything
/// that is composited on screen, including this app's own live wallpaper, because
/// macOS draws window content there rather than in the owning app.
struct GPUConsumerList: View {
    let consumers: [GPUConsumer]
    var limit = 8
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GPU-VERBRAUCHER").font(.caption2.weight(.semibold))
                Spacer()
                Text("GPU-ZEIT").font(.caption2)
            }.foregroundStyle(.secondary)
            if consumers.isEmpty {
                Text("Derzeit nutzt kein Prozess messbare GPU-Zeit.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(consumers.prefix(limit)) { consumer in
                    HStack(spacing: 8) {
                        Text(consumer.name).lineLimit(1).truncationMode(.middle)
                        Text("\(consumer.pid)").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        ProgressView(value: min(1, consumer.percent / 100)).tint(.mint).frame(width: 54)
                        Text(String(format: "%.0f %%", consumer.percent)).monospacedDigit().frame(width: 46, alignment: .trailing)
                    }.font(.caption)
                }
                Text("Anteil der Messspanne, in der dieser Prozess GPU-Arbeit eingereicht hat. Mehrere Recheneinheiten können gleichzeitig laufen, Videodekodierung läuft an der GPU vorbei.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct MonitorMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let color: Color
    let points: [MonitorPoint]
    let key: KeyPath<MonitorPoint, Double?>
    var percent = true
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.system(size: compact ? 22 : 34, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            MonitorTrend(points: points, key: key, color: color, percent: percent, compact: compact)
                .frame(height: compact ? 24 : 86)
        }.padding(compact ? 10 : 20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.16), lineWidth: 1))
    }
}

struct MonitorVolumeCard: View {
    let volume: MonitorVolume
    var compact = false
    var inline = false
    var body: some View {
        if inline {
            HStack(spacing: 10) {
                Image(systemName: volume.path == "/" ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(volume.name).font(.system(size: 11, weight: .medium)); Spacer(); Text(diskBytes(volume.free) + " frei").font(.system(size: 11)).foregroundStyle(.secondary); Text(String(format: "%.0f %%", volume.usedFraction * 100)).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                    ProgressView(value: volume.usedFraction).tint(volume.usedFraction > 0.9 ? .orange : .cyan)
                }
            }.padding(.horizontal, 12).padding(.vertical, 9).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(volume.name, systemImage: volume.path == "/" ? "internaldrive" : "externaldrive").font(.headline)
                Spacer()
                Text(String(format: "%.0f %%", volume.usedFraction * 100)).monospacedDigit()
            }
            ProgressView(value: volume.usedFraction).tint(volume.usedFraction > 0.9 ? .orange : .cyan)
            HStack {
                Text(diskBytes(volume.free) + " frei")
                Spacer()
                Text("von " + diskBytes(volume.total)).foregroundStyle(.secondary)
            }.font(.caption)
            if !compact { Text(volume.path).font(.caption2).foregroundStyle(.secondary) }
        }.padding(compact ? 12 : 18).background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct MonitorVolumesWidget: View {
    let volumes: [MonitorVolume]
    var inline = false
    var open: (MonitorVolume) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 8) {
            ForEach(volumes) { volume in
                Button { open(volume) } label: { MonitorVolumeCard(volume: volume, compact: true, inline: inline) }
                    .buttonStyle(.plain).accessibilityLabel("Laufwerk " + volume.name + " öffnen")
            }
        }
    }
}

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var userProcesses = UserProcessStore.shared
    @State private var minutes = 10
    @State private var processSort = "RAM"
    @State private var userProcessSearch = ""
    @State private var selectedMetric: MonitorMetric?
    private var points: [MonitorPoint] { monitor.history.filter { $0.date > Date().addingTimeInterval(Double(-minutes * 60)) } }
    private var reading: SystemReading? { monitor.reading }
    private var processes: [MonitorProcess] {
        Array((reading?.processes ?? []).sorted {
            processSort == "RAM" ? $0.memory > $1.memory : ($0.cpu ?? -1) > ($1.cpu ?? -1)
        }.prefix(12))
    }
    private var energyProcesses: [(name: String, watts: Double)] {
        let measured = (reading?.processes ?? []).compactMap { process -> (String, Double)? in
            guard let watts = process.energyWatts, watts >= 0 else { return nil }
            return (process.name, watts)
        }
        let grouped = Dictionary(grouping: measured, by: { $0.0 })
        return grouped.map { (name: $0.key, watts: $0.value.reduce(0) { $0 + $1.1 }) }
            .sorted { $0.watts > $1.watts }.prefix(8).map { $0 }
    }
    private var shownUserProcesses: [UserProcess] {
        let featured = userProcesses.featured
        let featuredIDs = Set(featured.map(\.id))
        let marked = userProcesses.listedProcesses.filter { userProcesses.isBookmarked($0.id) }
        return (marked + featured.filter { !userProcesses.isBookmarked($0.id) } + userProcesses.scopedProcesses.filter { !featuredIDs.contains($0.id) && !userProcesses.isBookmarked($0.id) }).filter { process in
            userProcessSearch.isEmpty || process.displayName.localizedCaseInsensitiveContains(userProcessSearch) ||
                process.command.localizedCaseInsensitiveContains(userProcessSearch) ||
                process.workingDirectory.localizedCaseInsensitiveContains(userProcessSearch) ||
                String(process.pid).contains(userProcessSearch) || process.ports.contains { String($0).contains(userProcessSearch) }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    ToolPageHeader(title: "Systemmonitor", description: "Dein Mac auf einen Blick.", icon: "waveform.path.ecg")
                    VStack(alignment: .trailing, spacing: 8) {
                        Label(reading == nil ? "Startet …" : "Live · alle 2 Sekunden", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                        Picker("Zeitraum", selection: $minutes) { Text("2 Min.").tag(2); Text("10 Min.").tag(10); Text("30 Min.").tag(30) }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    Button { selectedMetric = .cpu } label: { MonitorMetricCard(title: "CPU", icon: "cpu", value: monitorPercent(reading?.point.cpu), detail: "\(ProcessInfo.processInfo.activeProcessorCount) Kerne · gesamte Auslastung", color: .cyan, points: points, key: \.cpu) }.buttonStyle(.plain)
                    Button { selectedMetric = .ram } label: { MonitorMetricCard(title: "RAM", icon: "memorychip", value: monitorPercent(reading?.point.memory), detail: reading.map { diskBytes(Int64($0.appMemory + $0.wiredMemory + $0.compressedMemory)) + " von " + diskBytes(Int64($0.totalMemory)) } ?? "Wird gemessen", color: .purple, points: points, key: \.memory) }.buttonStyle(.plain)
                    Button { selectedMetric = .gpu } label: { MonitorMetricCard(title: "GPU", icon: "square.3.layers.3d", value: monitorPercent(reading?.point.gpu), detail: reading?.point.gpu == nil ? "Treiber liefert keine Auslastung" : (reading?.gpuName ?? "GPU"), color: .mint, points: points, key: \.gpu) }.buttonStyle(.plain)
                    Button { selectedMetric = .disk } label: { MonitorMetricCard(title: "Disk · Lesen", icon: "arrow.down.to.line", value: monitorRate(reading?.point.diskRead), detail: "Alle erfassten Datenträger", color: .blue, points: points, key: \.diskRead, percent: false) }.buttonStyle(.plain)
                    MonitorMetricCard(title: "Disk · Schreiben", icon: "arrow.up.to.line", value: monitorRate(reading?.point.diskWrite), detail: "Alle erfassten Datenträger", color: .orange, points: points, key: \.diskWrite, percent: false)
                    MonitorMetricCard(title: "Netzwerk · Download", icon: "network", value: monitorRate(reading?.point.download), detail: "Upload " + monitorRate(reading?.point.upload), color: .pink, points: points, key: \.download, percent: false)
                }
                batteryCard
                userProcessesCard
                HStack(alignment: .top, spacing: 16) {
                    memoryCard
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(reading?.volumes ?? []) { MonitorVolumeCard(volume: $0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let reading, !reading.cores.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CPU-Kerne").font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(Array(reading.cores.enumerated()), id: \.offset) { index, value in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text("\(index + 1)"); Spacer(); Text(monitorPercent(value)) }.font(.caption).monospacedDigit()
                                    ProgressView(value: value, total: 100).tint(.cyan)
                                }
                            }
                        }
                    }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("GPU").font(.title3.bold())
                    GPUConsumerList(consumers: reading?.gpuConsumers ?? [], limit: 10)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Top-Prozesse").font(.title3.bold())
                        Spacer()
                        Picker("Sortieren nach", selection: $processSort) { Text("RAM").tag("RAM"); Text("CPU").tag("CPU") }.pickerStyle(.segmented).frame(width: 160)
                    }
                    HStack { Text("Prozess"); Spacer(); Text("CPU¹").frame(width: 90, alignment: .trailing); Text("RAM").frame(width: 100, alignment: .trailing) }.font(.caption).foregroundStyle(.secondary)
                    ForEach(processes) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Text("\(process.id)").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(monitorPercent(process.cpu)).frame(width: 90, alignment: .trailing)
                            Text(diskBytes(Int64(process.memory))).frame(width: 100, alignment: .trailing)
                        }.font(.callout).monospacedDigit()
                        Divider()
                    }
                    Text("¹ 100 % je CPU-Kern. Geschützte Prozesse können fehlen. RAM zeigt residenten Prozessspeicher; gemeinsame Seiten können mehrfach gezählt werden.").font(.caption2).foregroundStyle(.secondary)
                }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }.onAppear { monitor.start(); monitor.retainDetail() }
            .onDisappear { monitor.releaseDetail() }
            .task {
                while !Task.isCancelled {
                    await userProcesses.refresh()
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                }
            }
            .sheet(item: $selectedMetric) { metric in
                VStack(spacing: 0) {
                    MonitorDetailView(metric: metric)
                    Button("Schließen") { selectedMetric = nil }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                }
            }
    }
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Batterie", systemImage: "battery.100percent").font(.title3.bold())
            if let battery = reading?.battery {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(monitorPercent(battery.chargePercent)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        ProgressView(value: battery.chargePercent, total: 100).tint(battery.chargePercent < 20 ? .orange : .green)
                        Text(battery.isCharging ? "Lädt" : battery.isOnBattery ? "Batteriebetrieb" : "Netzbetrieb")
                            .font(.callout).foregroundStyle(.secondary)
                        if let minutes = battery.minutesRemaining {
                            Text(battery.isCharging ? "Bis voll: \(minutes / 60) Std. \(minutes % 60) Min." : "Voraussichtlich: \(minutes / 60) Std. \(minutes % 60) Min.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Batteriezustand").font(.caption).foregroundStyle(.secondary)
                        Text(monitorPercent(battery.healthPercent)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(battery.cycleCount.map { "\($0) Ladezyklen" } ?? "Ladezyklen nicht verfügbar")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Maximale Kapazität / Designkapazität").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(battery.isCharging ? "Ladeleistung" : battery.isOnBattery ? "Batterieentnahme" : "Batterieleistung").font(.caption).foregroundStyle(.secondary)
                        Text(battery.powerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("Momentan an der Batterie gemessen").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                MonitorTrend(points: points, key: \.battery, color: .green)
                    .frame(height: 80).accessibilityLabel("Batteriestand im Zeitverlauf")
                Divider()
                HStack {
                    Text("Programme mit höchstem Energieverbrauch").font(.headline)
                    Spacer()
                    Text("Aktuelle Prozessleistung").font(.caption).foregroundStyle(.secondary)
                }
                if energyProcesses.isEmpty {
                    Text("Prozessenergie wird noch gemessen oder ist für diese Prozesse nicht verfügbar.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(energyProcesses, id: \.name) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.2f W", process.watts)).monospacedDigit()
                        }.font(.callout)
                    }
                }
                Text("Prozesswerte stammen aus macOS-Energiezählern und decken nicht Display, Funk und alle Systemverbraucher ab. Sie sind kein exakter Anteil an der Batterieentnahme.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Keine interne Batterie erkannt oder Batteriedaten nicht verfügbar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private var userProcessesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Meine Prozesse", systemImage: "terminal").font(.title3.bold())
                Text(userProcessSearch.isEmpty ? "\(userProcesses.listedProcesses.count)" : "\(shownUserProcesses.count) von \(userProcesses.listedProcesses.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                UserProcessViewModeToggle(mode: $userProcesses.viewMode)
                if userProcesses.viewMode == .tree { UserProcessTreeActions(store: userProcesses, processes: userProcesses.listedProcesses) }
                Button { UserProcessWindowController.shared.show() } label: {
                    Label("Fenster öffnen", systemImage: "macwindow")
                }.buttonStyle(.bordered).controlSize(.small).tint(.mint)
            }
            HStack(spacing: 12) {
                UserProcessScopeTabs(scope: $userProcesses.scope).frame(width: 250)
                TextField("Name, PID oder Port suchen", text: $userProcessSearch).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    if userProcesses.viewMode == .tree {
                        UserProcessTreeList(store: userProcesses, processes: userProcesses.listedProcesses, search: userProcessSearch, selectedID: nil) { process in
                            UserProcessWindowController.shared.show(processID: process.id)
                        }
                    } else {
                        ForEach(shownUserProcesses) { process in
                            UserProcessRow(process: process, selected: false, bookmarked: userProcesses.isBookmarked(process.id), running: userProcesses.isRunning(process.id)) { UserProcessWindowController.shared.show(processID: process.id) }
                        }
                    }
                }
            }.frame(height: 300).id(userProcessSearch + ":" + userProcesses.scope.rawValue + ":" + userProcesses.viewMode.rawValue)
            if !userProcesses.listedProcesses.isEmpty && shownUserProcesses.isEmpty {
                Text("Keine Prozesse im gewählten Bereich oder mit diesem Suchbegriff.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Arbeitsspeicher").font(.title3.bold()); Spacer(); Text("Swap " + (reading.map { diskBytes(Int64($0.swap)) } ?? "—")).font(.caption).foregroundStyle(.secondary) }
            if let r = reading, r.point.memory != nil {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(.blue).frame(width: geometry.size.width * Double(r.appMemory) / Double(r.totalMemory))
                        Rectangle().fill(.orange).frame(width: geometry.size.width * Double(r.wiredMemory) / Double(r.totalMemory))
                        Rectangle().fill(.pink).frame(width: geometry.size.width * Double(r.compressedMemory) / Double(r.totalMemory))
                        Rectangle().fill(.gray.opacity(0.2))
                    }.clipShape(Capsule())
                }.frame(height: 12)
                memoryRow("Apps", bytes: r.appMemory, color: .blue)
                memoryRow("System · Wired", bytes: r.wiredMemory, color: .orange)
                memoryRow("Komprimiert", bytes: r.compressedMemory, color: .pink)
                memoryRow("Verfügbar", bytes: r.totalMemory - min(r.totalMemory, r.appMemory + r.wiredMemory + r.compressedMemory), color: .gray)
                if let gpu = r.gpuMemory { Text("GPU belegt " + diskBytes(Int64(gpu)) + " · kann mit RAM geteilt sein").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Messung nicht verfügbar").foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private func memoryRow(_ name: String, bytes: UInt64, color: Color) -> some View {
        HStack { Circle().fill(color).frame(width: 7, height: 7); Text(name); Spacer(); Text(diskBytes(Int64(bytes))).monospacedDigit() }.font(.callout)
    }
}

@MainActor final class UserProcessWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UserProcessWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MacTools · Benutzerprozesse"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UserProcessManagerView())
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func show(processID: String? = nil) {
        if let processID { UserProcessStore.shared.selectedID = processID }
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await UserProcessStore.shared.refresh() }
    }
}

struct UserProcessMenuView: View {
    @ObservedObject private var store = UserProcessStore.shared
    @State private var search = ""
    let openWindow: () -> Void
    let openSettings: () -> Void
    let openProcess: (UserProcess) -> Void
    let height: CGFloat

    private var shown: [UserProcess] {
        store.listedProcesses.filter { process in
            search.isEmpty || process.displayName.localizedCaseInsensitiveContains(search) ||
                process.executable.localizedCaseInsensitiveContains(search) ||
                process.command.localizedCaseInsensitiveContains(search) ||
                process.workingDirectory.localizedCaseInsensitiveContains(search) ||
                String(process.pid).contains(search) || process.ports.contains { String($0).contains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Prozesse", systemImage: "terminal").font(.headline).foregroundStyle(.mint)
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Prozesse aktualisieren").accessibilityLabel("Prozesse aktualisieren")
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("Menüleisten-Favoriten einstellen").accessibilityLabel("Menüleisten-Favoriten einstellen")
                Button(action: openWindow) { Image(systemName: "arrow.up.right.square") }
                    .help("Prozesse in eigenem Fenster öffnen").accessibilityLabel("Prozesse in eigenem Fenster öffnen")
            }.buttonStyle(.plain)
            HStack {
                Text("\(store.scopedProcesses.count) laufend").font(.callout.weight(.medium))
                Spacer()
                if !store.bookmarks.isEmpty { Text("\(store.bookmarks.count) markiert").font(.caption).foregroundStyle(.secondary) }
            }
            UserProcessScopeTabs(scope: $store.scope)
            HStack {
                UserProcessViewModeToggle(mode: $store.viewMode)
                Spacer()
                if store.viewMode == .tree { UserProcessTreeActions(store: store, processes: store.listedProcesses) }
            }
            TextField("Name, PID oder Port suchen", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.viewMode == .tree {
                        UserProcessTreeList(store: store, processes: store.listedProcesses, search: search, selectedID: nil, open: openProcess)
                    } else {
                        ForEach(shown) { process in
                            UserProcessRow(process: process, selected: false, bookmarked: store.isBookmarked(process.id), running: store.isRunning(process.id)) { openProcess(process) }
                        }
                    }
                }
            }.scrollIndicators(.visible)
            if shown.isEmpty { Text(store.processes.isEmpty ? "Benutzerprozesse werden geladen …" : "Keine passenden Prozesse.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.error { Text(error).font(.caption2).foregroundStyle(.orange) }
        }.padding(18).frame(width: 390, height: height)
    }
}

struct UserProcessManagerView: View {
    @ObservedObject private var store = UserProcessStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var search = ""
    @State private var pendingStop: UserProcess?
    @State private var forceStop = false
    @State private var actionError: String?
    @State private var logPath: String?
    @State private var logText = ""
    @State private var checkingLog = false
    private var shown: [UserProcess] {
        let values = store.listedProcesses.filter { process in
            search.isEmpty || process.name.localizedCaseInsensitiveContains(search) ||
                process.executable.localizedCaseInsensitiveContains(search) ||
                process.command.localizedCaseInsensitiveContains(search) ||
                process.workingDirectory.localizedCaseInsensitiveContains(search) ||
                String(process.pid).contains(search) || process.ports.contains { String($0).contains(search) }
        }
        return values.sorted { a, b in
            if store.isBookmarked(a.id) != store.isBookmarked(b.id) { return store.isBookmarked(a.id) }
            let ac = a.cpu ?? 0, bc = b.cpu ?? 0
            if ac != bc { return ac > bc }
            if a.ports.isEmpty != b.ports.isEmpty { return !a.ports.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private var selected: UserProcess? { store.listedProcesses.first { $0.id == store.selectedID } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Deine Prozesse", systemImage: "terminal")
                    Spacer()
                    Text("\(store.listedProcesses.count)").foregroundStyle(.secondary)
                    UserProcessViewModeToggle(mode: $store.viewMode)
                }.font(.headline)
                UserProcessScopeTabs(scope: $store.scope)
                if store.viewMode == .tree { UserProcessTreeActions(store: store, processes: store.listedProcesses) }
                TextField("Name, PID oder Port suchen", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if store.viewMode == .tree {
                            UserProcessTreeList(store: store, processes: store.listedProcesses, search: search, selectedID: store.selectedID) { process in store.selectedID = process.id }
                        } else {
                            ForEach(shown) { process in
                                UserProcessRow(process: process, selected: store.selectedID == process.id, bookmarked: store.isBookmarked(process.id), running: store.isRunning(process.id)) { store.selectedID = process.id }
                            }
                        }
                    }
                }
                if let error = store.error { Text(error).font(.caption2).foregroundStyle(.orange) }
            }.frame(width: 295).padding(16).background(Color.primary.opacity(0.035))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let process = selected {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(process.displayName).font(.title2.weight(.semibold))
                            Text("PID \(process.pid) · Elternprozess \(process.parentPID) · Start " + Date(timeIntervalSince1970: TimeInterval(process.startedAt)).formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(store.isRunning(process.id) ? "Läuft" : "Beendet · markiert")
                                .font(.caption.weight(.medium)).foregroundStyle(store.isRunning(process.id) ? Color.mint : Color.secondary)
                            if !process.executable.isEmpty { Text(process.executable).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                            if !process.workingDirectory.isEmpty { Text("Arbeitsordner: " + process.workingDirectory).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2) }
                            if !process.command.isEmpty { Text(process.command).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3) }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button { store.toggleBookmark(process, logPath: logPath) } label: {
                                Image(systemName: store.isBookmarked(process.id) ? "star.fill" : "star")
                                    .frame(width: 18, height: 18)
                            }.help(store.isBookmarked(process.id) ? "Markierung entfernen" : "Prozess markieren")
                                .accessibilityLabel(store.isBookmarked(process.id) ? "Markierung entfernen" : "Prozess markieren")
                                .tint(store.isBookmarked(process.id) ? .yellow : .mint)
                            Button { pendingStop = process; forceStop = false } label: {
                                Label("Beenden", systemImage: "stop.fill")
                            }.disabled(process.pid == getpid() || !store.isRunning(process.id))
                            Button { pendingStop = process; forceStop = true } label: {
                                Label("Sofort", systemImage: "xmark.circle.fill")
                            }.disabled(process.pid == getpid() || !store.isRunning(process.id)).tint(.red)
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    HStack(spacing: 20) {
                        if !store.isRunning(process.id) { Text("Letzte Messung:") }
                        Text("CPU " + monitorPercent(process.cpu))
                        Text("RAM " + (process.memory.map { diskBytes(Int64($0)) } ?? "—"))
                        if store.isRunning(process.id) {
                            Text("GPU gesamt " + monitorPercent(monitor.reading?.point.gpu))
                                .help("Systemweite GPU-Auslastung. macOS liefert hier keine verlässliche Auslastung für diesen einzelnen Prozess.")
                        }
                        Spacer()
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack { Text("TCP-Ports").font(.caption.weight(.semibold)); Text(process.ports.isEmpty ? "Keine Listener erkannt" : process.ports.map(String.init).joined(separator: ", ")).font(.caption).monospacedDigit(); Spacer() }
                    Divider()
                    HStack {
                        Text("LIVE-LOG").font(.caption.weight(.semibold))
                        Spacer()
                        if let logPath { Text(logPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(logPath) }
                    }
                    if checkingLog { ProgressView().controlSize(.small) }
                    else if logPath == nil {
                        Text("Keine lesbare Logdatei an stdout/stderr. Ausgabe eines fremden Terminal-PTYs kann macOS nachträglich nicht an diese Ansicht übergeben.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(logText.isEmpty ? "Noch keine Ausgabe." : logText)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }.background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        Text("Letzte 64 KiB · Aktualisierung jede Sekunde").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(store.selectedID == nil ? "Wähle links einen Prozess." : "Der ausgewählte Prozess ist beendet.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.onChange(of: store.scope) { _ in store.selectedID = nil }
        .onAppear { monitor.start(); monitor.retainDetail() }
        .onDisappear { monitor.releaseDetail() }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            }
        }.task(id: selected?.id) {
            logPath = nil; logText = ""; checkingLog = selected != nil
            guard let process = selected else { return }
            let path = store.isRunning(process.id) ? await store.logPath(for: process) ?? store.bookmarkedLogPath(process.id) : store.bookmarkedLogPath(process.id)
            guard !Task.isCancelled else { return }
            logPath = path; checkingLog = false
            guard let path else { return }
            while !Task.isCancelled {
                let value = await Task.detached(priority: .utility) { UserProcessSampler.tail(path) }.value
                guard !Task.isCancelled else { return }
                logText = value ?? "Logdatei ist nicht mehr lesbar."
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }.alert("Prozess beenden?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })) {
            Button(forceStop ? "Sofort beenden" : "Beenden", role: .destructive) {
                if let process = pendingStop { actionError = store.stop(process, force: forceStop) }
                pendingStop = nil
                Task { await store.refresh() }
            }
            Button("Abbrechen", role: .cancel) { pendingStop = nil }
        } message: {
            Text(pendingStop.map { "\($0.displayName) (PID \($0.pid))" } ?? "")
        }.alert("Prozess konnte nicht beendet werden", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }
}

private struct UserProcessScopeTabs: View {
    @Binding var scope: UserProcessScope
    var body: some View {
        HStack(spacing: 3) {
            ForEach(UserProcessScope.allCases, id: \.self) { option in
                Button { scope = option } label: {
                    Text(option.title).font(.caption.weight(scope == option ? .semibold : .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(scope == option ? Color.primary : Color.secondary)
                        .background(scope == option ? Color.mint.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityAddTraits(scope == option ? .isSelected : []).help(option.explanation)
            }
        }.padding(3).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct UserProcessViewModeToggle: View {
    @Binding var mode: UserProcessViewMode
    var body: some View {
        HStack(spacing: 2) {
            Button { mode = .list } label: {
                Image(systemName: "list.bullet").frame(width: 18, height: 18)
            }.help("Liste: Prozesse einzeln anzeigen").accessibilityLabel("Listenansicht")
                .accessibilityAddTraits(mode == .list ? .isSelected : [])
                .background(mode == .list ? Color.mint.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            Button { mode = .tree } label: {
                Image(systemName: "list.bullet.indent").frame(width: 18, height: 18)
            }.help("Prozessbaum: Elternprozesse mit ihren Unterprozessen anzeigen und Zweige aufklappen").accessibilityLabel("Prozessbaum")
                .accessibilityAddTraits(mode == .tree ? .isSelected : [])
                .background(mode == .tree ? Color.mint.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).font(.caption).padding(3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UserProcessTreeEntry: Identifiable {
    let process: UserProcess
    let depth: Int
    let ancestors: [String]
    let childCount: Int
    var id: String { process.id }

    static func make(_ processes: [UserProcess]) -> [UserProcessTreeEntry] {
        let byPID = Dictionary(grouping: processes, by: \.pid)
        var parentIDs: [String: String] = [:]
        for process in processes {
            let older = (byPID[process.parentPID] ?? []).filter { candidate in
                candidate.id != process.id && (candidate.startedAt < process.startedAt ||
                    (candidate.startedAt == process.startedAt && candidate.startedAtUsec < process.startedAtUsec))
            }
            if let parent = older.max(by: { ($0.startedAt, $0.startedAtUsec) < ($1.startedAt, $1.startedAtUsec) }) {
                parentIDs[process.id] = parent.id
            }
        }
        var children: [String: [UserProcess]] = [:]
        for process in processes {
            if let parentID = parentIDs[process.id] { children[parentID, default: []].append(process) }
        }
        var entries: [UserProcessTreeEntry] = []
        func append(_ process: UserProcess, depth: Int, ancestors: [String]) {
            let descendants = children[process.id] ?? []
            entries.append(UserProcessTreeEntry(process: process, depth: depth, ancestors: ancestors, childCount: descendants.count))
            for child in descendants { append(child, depth: depth + 1, ancestors: ancestors + [process.id]) }
        }
        for process in processes where parentIDs[process.id] == nil { append(process, depth: 0, ancestors: []) }
        return entries
    }
}

private struct UserProcessTreeList: View {
    @ObservedObject var store: UserProcessStore
    let processes: [UserProcess]
    let search: String
    let selectedID: String?
    let open: (UserProcess) -> Void
    private var visible: [UserProcessTreeEntry] {
        let entries = UserProcessTreeEntry.make(processes)
        if search.isEmpty {
            return entries.filter { entry in !entry.ancestors.contains(where: store.collapsedProcessIDs.contains) }
        }
        let matched = Set(entries.filter { entry in
            let process = entry.process
            return process.displayName.localizedCaseInsensitiveContains(search) ||
                process.executable.localizedCaseInsensitiveContains(search) ||
                process.command.localizedCaseInsensitiveContains(search) ||
                process.workingDirectory.localizedCaseInsensitiveContains(search) ||
                String(process.pid).contains(search) || process.ports.contains { String($0).contains(search) }
        }.map(\.id))
        let matchingEntries = entries.filter { matched.contains($0.id) }
        let forcedOpen = Set(matchingEntries.flatMap(\.ancestors))
        let included = matched.union(forcedOpen)
        return entries.filter { entry in
            let inSearchTree = included.contains(entry.id) || entry.ancestors.contains(where: matched.contains)
            let hiddenByCollapsed = entry.ancestors.contains(where: store.collapsedProcessIDs.contains)
            return inSearchTree && !hiddenByCollapsed
        }
    }
    var body: some View {
        ForEach(visible) { entry in
            HStack(spacing: 3) {
                if entry.depth > 0 { Color.clear.frame(width: CGFloat(entry.depth) * 13, height: 1) }
                if entry.childCount > 0 {
                    Button { store.toggleCollapsed(entry.id) } label: {
                        Image(systemName: store.collapsedProcessIDs.contains(entry.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 25, height: 28)
                            .background(Color.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("\(entry.childCount) Unterprozesse \(store.collapsedProcessIDs.contains(entry.id) ? "einblenden" : "ausblenden")")
                        .accessibilityLabel("Unterprozesse \(store.collapsedProcessIDs.contains(entry.id) ? "einblenden" : "ausblenden")")
                } else {
                    Image(systemName: entry.depth > 0 ? "arrow.turn.down.right" : "")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 25, height: 28)
                }
                UserProcessRow(process: entry.process, selected: selectedID == entry.id,
                               bookmarked: store.isBookmarked(entry.id), running: store.isRunning(entry.id)) { open(entry.process) }
            }
        }
    }
}

private struct UserProcessTreeActions: View {
    @ObservedObject var store: UserProcessStore
    let processes: [UserProcess]
    var body: some View {
        HStack(spacing: 6) {
            Button { store.collapseAll(Set(UserProcessTreeEntry.make(processes).filter { $0.childCount > 0 }.map(\.id))) } label: {
                Label("Alle zuklappen", systemImage: "chevron.up.2")
            }.help("Alle Elternprozesse zuklappen")
            Button { store.expandAll() } label: {
                Label("Alle aufklappen", systemImage: "chevron.down.2")
            }.help("Alle Unterprozesse aufklappen")
        }.buttonStyle(.bordered).controlSize(.mini).font(.caption2)
    }
}

private struct UserProcessRow: View {
    let process: UserProcess
    let selected: Bool
    let bookmarked: Bool
    let running: Bool
    let open: () -> Void
    private var ports: String { process.ports.map(String.init).joined(separator: ", ") }
    private var accessibilityText: String {
        let prefix = bookmarked ? "Markiert, " : ""
        let status = running ? "läuft" : "beendet"
        let portText = ports.isEmpty ? "kein TCP-Port" : "Ports " + ports
        return "\(prefix)\(process.displayName), PID \(process.pid), \(status), \(portText)"
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if bookmarked { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Markiert") }
                    Text(process.displayName).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text("PID \(process.pid)").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    if !running { Text("Beendet") }
                    if process.isCodex { Text("Codex") }
                    if process.hasTerminal { Text("Terminal") }
                    if !process.ports.isEmpty { Text("Port " + ports) }
                    if running, let cpu = process.cpu, cpu >= 1 { Text(String(format: "%.0f %% CPU", cpu)) }
                    if running, let memory = process.memory { Text("RAM " + diskBytes(Int64(memory))) }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if !process.command.isEmpty { Text(process.command).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.mint.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
    }
}
