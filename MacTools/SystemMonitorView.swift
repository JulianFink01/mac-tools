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
    private var chart: some View {
        Chart {
            ForEach(values, id: \.0.id) { point, segment in
                if let value = point[keyPath: key] {
                    AreaMark(x: .value("Zeit", point.date), yStart: .value("Basis", 0), yEnd: .value("Wert", value), series: .value("Abschnitt", segment))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", point.date), y: .value("Wert", value), series: .value("Abschnitt", segment))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
        }
        .chartYScale(domain: percent ? 0...100 : 0...max(1, values.compactMap { $0.0[keyPath: key] }.max() ?? 1))
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
    @State private var minutes = 10
    @State private var processSort = "RAM"
    @State private var selectedMetric: MonitorMetric?
    private var points: [MonitorPoint] { monitor.history.filter { $0.date > Date().addingTimeInterval(Double(-minutes * 60)) } }
    private var reading: SystemReading? { monitor.reading }
    private var processes: [MonitorProcess] {
        Array((reading?.processes ?? []).sorted {
            processSort == "RAM" ? $0.memory > $1.memory : ($0.cpu ?? -1) > ($1.cpu ?? -1)
        }.prefix(12))
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
                HStack(alignment: .top, spacing: 16) {
                    memoryCard
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Datenträger").font(.title3.bold())
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
        }.onAppear { monitor.start() }
            .sheet(item: $selectedMetric) { metric in
                VStack(spacing: 0) {
                    MonitorDetailView(metric: metric)
                    Button("Schließen") { selectedMetric = nil }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                }
            }
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
