import SwiftUI

enum MonitorMetric: String, CaseIterable, Identifiable {
    case cpu, ram, gpu, disk
    var id: String { rawValue }
    var title: String {
        switch self { case .cpu: return "CPU"; case .ram: return "RAM"; case .gpu: return "GPU"; case .disk: return "Disk" }
    }
    var icon: String {
        switch self { case .cpu: return "cpu"; case .ram: return "memorychip"; case .gpu: return "square.3.layers.3d"; case .disk: return "internaldrive" }
    }
    var color: Color {
        switch self { case .cpu: return .cyan; case .ram: return .purple; case .gpu: return .mint; case .disk: return .orange }
    }
    var key: KeyPath<MonitorPoint, Double?> {
        switch self { case .cpu: return \.cpu; case .ram: return \.memory; case .gpu: return \.gpu; case .disk: return \.diskUsed }
    }
    var settingsDetail: String {
        switch self {
        case .cpu: return "Gesamtauslastung aller CPU-Kerne"
        case .ram: return "Belegter Arbeitsspeicher"
        case .gpu: return "Auslastung der Grafikeinheit"
        case .disk: return "Belegung des Systemdatenträgers"
        }
    }
    func value(in reading: SystemReading?) -> Double? { reading?.point[keyPath: key] }
}

struct MemoryPressureIndicator: View {
    let pressure: Int32?
    private var label: String {
        switch pressure { case 1: return "Normal"; case 2: return "Erhöht"; case 4: return "Kritisch"; default: return "Nicht verfügbar" }
    }
    private var color: Color {
        switch pressure { case 1: return .green; case 2: return .orange; case 4: return .red; default: return .gray }
    }
    private var position: Double {
        switch pressure { case 1: return 0.16; case 2: return 0.5; case 4: return 0.84; default: return 0.5 }
    }
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0.5, to: 1).stroke(AngularGradient(colors: [.green, .yellow, .orange, .red], center: .center, startAngle: .degrees(180), endAngle: .degrees(360)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                if pressure != nil {
                    Rectangle().fill(color).frame(width: 3, height: 30).offset(y: -15)
                        .rotationEffect(.degrees(-90 + position * 180))
                }
            }.frame(width: 84, height: 84).frame(height: 48, alignment: .top).clipped()
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text("Speicherdruck").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Speicherdruck: " + label)
    }
}

struct MemoryDonut: View {
    let reading: SystemReading
    private var total: Double { Double(max(1, reading.totalMemory)) }
    private var app: Double { min(1, Double(reading.appMemory) / total) }
    private var wired: Double { min(1 - app, Double(reading.wiredMemory) / total) }
    private var compressed: Double { min(1 - app - wired, Double(reading.compressedMemory) / total) }
    var body: some View {
        ZStack {
            Circle().stroke(.gray.opacity(0.2), lineWidth: 9)
            Circle().trim(from: 0, to: app).stroke(.blue, lineWidth: 9)
            Circle().trim(from: app, to: app + wired).stroke(.orange, lineWidth: 9)
            Circle().trim(from: app + wired, to: app + wired + compressed).stroke(.pink, lineWidth: 9)
            Text(monitorPercent(reading.point.memory)).font(.title2.bold()).monospacedDigit().rotationEffect(.degrees(90))
        }.rotationEffect(.degrees(-90)).frame(width: 88, height: 88)
            .accessibilityElement(children: .ignore).accessibilityLabel("RAM belegt: " + monitorPercent(reading.point.memory))
    }
}

struct MonitorDetailView: View {
    let metric: MonitorMetric
    var openMonitor: (() -> Void)? = nil
    var openSettings: (() -> Void)? = nil
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var minutes = 10
    private var reading: SystemReading? { monitor.reading }
    private var points: [MonitorPoint] { monitor.history.filter { $0.date > Date().addingTimeInterval(Double(-minutes * 60)) } }
    private var topProcesses: [MonitorProcess] {
        Array((reading?.processes ?? []).sorted { metric == .cpu ? ($0.cpu ?? -1) > ($1.cpu ?? -1) : $0.memory > $1.memory }.prefix(8))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(metric.title, systemImage: metric.icon).font(.headline).foregroundStyle(metric.color)
                Spacer()
                if let openSettings { Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Menüleisten-Widgets konfigurieren") }
                if let openMonitor { Button(action: openMonitor) { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("Systemmonitor öffnen") }
            }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if metric == .ram, let reading, reading.point.memory != nil {
                        HStack { Spacer(); MemoryPressureIndicator(pressure: reading.memoryPressure); Spacer(); MemoryDonut(reading: reading); Spacer() }.padding(.vertical, 4)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(monitorPercent(metric.value(in: reading))).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                            Spacer()
                            Text(metric == .disk ? "Systemvolume belegt" : "Auslastung").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("VERLAUF").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Zeitraum", selection: $minutes) { Text("2 Min.").tag(2); Text("10 Min.").tag(10); Text("30 Min.").tag(30) }.labelsHidden().frame(width: 96)
                        }
                        MonitorTrend(points: points, key: metric.key, color: metric.color, compact: true).frame(height: 100)
                        HStack {
                            Text(points.first?.date.formatted(date: .omitted, time: .shortened) ?? "—")
                            Spacer(); Text("Jetzt · alle 2 s")
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    switch metric {
                    case .ram: ramDetails
                    case .cpu: cpuDetails
                    case .gpu: gpuDetails
                    case .disk: diskDetails
                    }
                    if metric == .ram || metric == .cpu { processDetails }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }
        }.frame(width: 360, height: metric == .ram || metric == .cpu ? 700 : 580)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var ramDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ARBEITSSPEICHER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let r = reading, r.point.memory != nil {
                detailRow("Belegt", value: diskBytes(Int64(r.appMemory + r.wiredMemory + r.compressedMemory)))
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(.blue).frame(width: geometry.size.width * Double(r.appMemory) / Double(r.totalMemory))
                        Rectangle().fill(.orange).frame(width: geometry.size.width * Double(r.wiredMemory) / Double(r.totalMemory))
                        Rectangle().fill(.pink).frame(width: geometry.size.width * Double(r.compressedMemory) / Double(r.totalMemory))
                        Rectangle().fill(.gray.opacity(0.2))
                    }.clipShape(Capsule())
                }.frame(height: 10)
                detailRow("Apps", value: diskBytes(Int64(r.appMemory)), color: .blue)
                detailRow("System · Wired", value: diskBytes(Int64(r.wiredMemory)), color: .orange)
                detailRow("Komprimiert", value: diskBytes(Int64(r.compressedMemory)), color: .pink)
                detailRow("Verfügbar", value: diskBytes(Int64(r.totalMemory - min(r.totalMemory, r.appMemory + r.wiredMemory + r.compressedMemory))), color: .gray)
                detailRow("Gesamt", value: diskBytes(Int64(r.totalMemory)))
                detailRow("Swap", value: diskBytes(Int64(r.swap)))
            } else { Text("Messung nicht verfügbar").foregroundStyle(.secondary) }
        }
    }
    private var cpuDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CPU-KERNE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array((reading?.cores ?? []).enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 4) {
                        HStack { Text("Kern \(index + 1)"); Spacer(); Text(monitorPercent(value)) }.font(.caption).monospacedDigit()
                        ProgressView(value: value, total: 100).tint(.cyan)
                    }
                }
            }
        }
    }
    private var gpuDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reading?.gpuName ?? "Grafikeinheit").font(.headline)
            detailRow("Auslastung", value: monitorPercent(reading?.point.gpu))
            detailRow("GPU-Speicher", value: reading?.gpuMemory.map { diskBytes(Int64($0)) } ?? "—")
            Text(reading?.point.gpu == nil ? "Dieser Grafiktreiber liefert keine systemweite Auslastung." : "Messwerte des Grafiktreibers. GPU-Speicher kann mit dem Arbeitsspeicher geteilt sein.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var diskDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailRow("Lesen", value: monitorRate(reading?.point.diskRead), color: .blue)
            detailRow("Schreiben", value: monitorRate(reading?.point.diskWrite), color: .orange)
            Text("I/O über alle erfassten Datenträger").font(.caption2).foregroundStyle(.secondary)
            ForEach(reading?.volumes ?? []) { MonitorVolumeCard(volume: $0, compact: true) }
        }
    }
    private var processDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("TOP-PROZESSE").font(.caption2.weight(.semibold))
                Spacer(); Text(metric == .cpu ? "CPU¹" : "RAM").font(.caption2)
            }.foregroundStyle(.secondary)
            ForEach(topProcesses) { process in
                HStack {
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(metric == .cpu ? monitorPercent(process.cpu) : diskBytes(Int64(process.memory))).monospacedDigit()
                }.font(.caption)
            }
            Text(metric == .cpu ? "¹ 100 % je Kern. Geschützte Prozesse können fehlen." : "Residenter Prozessspeicher. Geteilte Seiten können mehrfach gezählt werden.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func detailRow(_ title: String, value: String, color: Color? = nil) -> some View {
        HStack {
            if let color { Circle().fill(color).frame(width: 7, height: 7) }
            Text(title); Spacer(); Text(value).monospacedDigit().fontWeight(.medium)
        }.font(.callout)
    }
}
