import SwiftUI
import Charts

struct PrivateMCPPage: View {
    let kind: PrivateMCPKind
    var body: some View {
        if let service = PrivateMCPStore.shared.service(kind) { PrivateMCPConfigurationView(service: service) }
        else { Text("Diese Integration ist auf diesem Mac nicht freigeschaltet.").foregroundStyle(.secondary) }
    }
}
struct PrivateMCPConfigurationView: View {
    @ObservedObject var service: PrivateMCPService
    @State private var endpoint = ""
    @State private var configurationError: String?
    @State private var detailConsumer = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ToolPageHeader(title: service.kind.title, description: "Health und Status live über MCP", icon: service.kind.icon)
                Label("Privater Build · nur auf diesem Mac freigeschaltet", systemImage: "lock.shield").font(.callout).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Label(service.stateLabel, systemImage: service.critical ? "exclamationmark.triangle.fill" : "checkmark.circle").font(.title2.weight(.semibold)).foregroundStyle(service.critical ? Color.red : .primary); Spacer(); if service.busy { ProgressView().controlSize(.small) } }
                    if let health = service.health {
                        HStack(spacing: 24) { ForEach(health.stats, id: \.self) { Text($0).font(.system(size: 16, weight: .medium, design: .rounded)) } }
                        Text("Stand " + health.checkedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = service.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    HStack {
                        Button(service.signingIn ? "Anmeldung läuft …" : "Im Browser anmelden") { Task { await service.signIn() } }.buttonStyle(.borderedProminent).tint(.mint).disabled(!service.enabled || service.busy || service.signingIn)
                        if let url = service.authorizationURL { Link("Anmeldeseite erneut öffnen", destination: url) }
                        Button("Aktualisieren") { Task { await service.refresh() } }.disabled(!service.enabled || service.busy || service.signingIn)
                    }
                    Text("Die Anmeldung und Freigabe erfolgen beim Dienst. Zugangsdaten verwaltet der lokale MCP-Client im macOS-Schlüsselbund.").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                if let health = service.health {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(health.metrics) { metric in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(metric.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); Spacer(); if let healthy = metric.healthy { Image(systemName: healthy ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(service.stale ? Color.secondary : healthy ? .mint : .red) } }
                                Text(metric.value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                if let fraction = metric.fraction { ProgressView(value: min(1, max(0, fraction))).tint(service.stale ? .gray : metric.healthy == false ? .red : .mint) }
                                Text(metric.detail.isEmpty ? " " : metric.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 28, alignment: .top)
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    if service.kind == .infrapilot {
                        InfraNamespaceDashboard(values:health.namespaces,history:service.namespaceHistory,warning:service.namespaceWarning,stale:service.stale || service.error != nil)
                    }
                    if let strategies = health.strategies, !strategies.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Deployments · PAPER und SHADOW").font(.headline)
                            Text("Jedes Deployment zählt einmal. Warten auf Daten mit aktuellem Heartbeat und STARTING allein sind keine Fehler. Gestört bedeutet Laufzeitfehler oder fehlender / abgelaufener Heartbeat. Gewollt pausierte Deployments zählen separat.").font(.caption).foregroundStyle(.secondary)
                            ForEach(strategies.facts) { fact in VStack(alignment: .leading, spacing: 5) { Text(fact.title).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).help(fact.key ?? fact.title); Text(fact.value).font(.callout).foregroundStyle(service.stale ? Color.secondary : fact.healthy == false ? .red : fact.healthy == true ? .mint : .secondary).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                        }.padding(22).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !health.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Betriebsdetails").font(.headline)
                            ForEach(health.facts) { fact in HStack(alignment: .top) { Text(fact.title).foregroundStyle(.secondary); Spacer(); Text(fact.value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.callout) }
                        }.padding(22).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                if let warning = service.detailWarning { Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Live-Kachel und Verbindung aktivieren", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) }))
                    Text("MCP-Server").font(.headline)
                    HStack { TextField("https://…/mcp", text: $endpoint).textFieldStyle(.roundedBorder).accessibilityLabel(service.kind.title + " MCP-Server"); Button("Speichern") { do { try service.configure(endpoint); configurationError = nil } catch { configurationError = error.localizedDescription } }.disabled(service.busy || service.signingIn) }
                    if let configurationError { Text(configurationError).foregroundStyle(.orange).font(.caption) }
                    Text("Freigegebene Aufrufe: " + service.kind.tools.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(24).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.onAppear { endpoint = service.endpoint; service.setDetailsVisible(true,consumer:detailConsumer); service.start(); Task { await service.refreshDetails() } }
            .onDisappear { service.setDetailsVisible(false,consumer:detailConsumer) }
    }
}

private struct InfraNamespaceDashboard: View {
    let values: [InfraNamespaceMetrics]
    let history: [InfraNamespaceSample]
    let warning: String?
    let stale: Bool
    @State private var namespace = ""
    @State private var metric = Resource.cpu
    private enum Resource: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "RAM", storage = "PVC", network = "Netzwerk"
        var id: String { rawValue }
        var color: Color { switch self { case .cpu:return .cyan; case .memory:return .blue; case .storage:return .orange; case .network:return .mint } }
        func value(_ row: InfraNamespaceMetrics) -> Double? { switch self { case .cpu:return row.cpu; case .memory:return row.memory; case .storage:return row.storage; case .network:return row.network } }
        func limit(_ row: InfraNamespaceMetrics) -> Double? { switch self { case .cpu:return row.cpuLimit; case .memory:return row.memoryLimit; case .storage:return row.storageLimit; case .network:return nil } }
        func formatted(_ value: Double) -> String { self == .cpu ? String(format:"%.3f Kerne",value) : PrivateMCPHealth.bytes(value) }
        var axisUnit: String { self == .cpu ? "Kerne" : "GiB" }
        func scaled(_ value: Double) -> Double { self == .cpu ? value : value / 1_073_741_824 }
    }
    private var selected: InfraNamespaceMetrics? { values.first { $0.id == namespace } ?? values.first }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) { Text("Namespaces").font(.title2.weight(.semibold)); Text("Ressourcen pro Namespace · minütlich bei geöffneter Ansicht").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !values.isEmpty { Picker("Namespace",selection:$namespace) { ForEach(values) { Text($0.id).tag($0.id) } }.labelsHidden().frame(maxWidth:240).accessibilityLabel("Namespace auswählen") }
            }
            if stale { Label("Verbindung unterbrochen · letzter bestätigter Stand",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let row = selected {
                Text("\(row.pods) Pods · \(row.claims) PVCs").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:175),spacing:14)],spacing:14) {
                    ForEach(Resource.allCases) { resource in gauge(resource,row) }
                }
                Picker("Ressource",selection:$metric) { ForEach(Resource.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).accessibilityLabel("Namespace-Diagramm Ressource")
                Text(metric.rawValue + " im Vergleich").font(.headline)
                if values.contains(where:{metric.value($0) != nil}) {
                    Chart(values.filter { metric.value($0) != nil }) { item in
                        BarMark(x:.value(metric.axisUnit,metric.scaled(metric.value(item)!)),y:.value("Namespace",item.id))
                            .foregroundStyle(metric.color.opacity(item.id == row.id ? 1 : 0.45)).cornerRadius(4)
                            .annotation(position:.trailing,alignment:.leading) { Text(metric.formatted(metric.value(item)!)).font(.caption2).foregroundStyle(.secondary) }
                    }.chartXAxisLabel(metric.axisUnit).chartXScale(domain:0...max(0.001,(values.compactMap { metric.value($0) }.max() ?? 0)*1.3 / (metric == .cpu ? 1 : 1_073_741_824)))
                        .frame(height:CGFloat(max(2,values.count))*35).padding(.trailing,45)
                    trend(row)
                } else {
                    Text(metric == .network ? "InfraPilot liefert derzeit keine Netzwerk-Messwerte je Namespace. RX/TX sind deshalb nicht verfügbar." : "Für diese Ressource sind keine Messwerte verfügbar.").font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:90,alignment:.leading)
                }
            } else { Text("Namespace-Metriken sind noch nicht verfügbar.").foregroundStyle(.secondary) }
        }.padding(22).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:18))
            .onAppear { if namespace.isEmpty { namespace = values.first?.id ?? "" } }
            .onChange(of:values.map(\.id)) { ids in if !ids.contains(namespace) { namespace = ids.first ?? "" } }
    }
    private func gauge(_ resource: Resource, _ row: InfraNamespaceMetrics) -> some View {
        let value = resource.value(row), limit = resource.limit(row)
        let fraction = value.flatMap { used in limit.flatMap { $0 > 0 ? used / $0 : nil } }
        let color: Color = stale ? .gray : (fraction ?? 0) >= 0.85 ? .red : resource.color
        return VStack(spacing:12) {
            Text(resource.rawValue).font(.headline)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08),lineWidth:9)
                if let fraction { Circle().trim(from:0,to:min(1,max(0,fraction))).stroke(color,style:StrokeStyle(lineWidth:9,lineCap:.round)).rotationEffect(.degrees(-90)) }
                VStack(spacing:3) {
                    Text(fraction.map { String(format:"%.0f %%",$0*100) } ?? "—").font(.system(size:23,weight:.semibold,design:.rounded)).monospacedDigit()
                    Text(fraction == nil ? "kein Messwert / Limit" : "belegt").font(.system(size:9)).foregroundStyle(.secondary)
                }
            }.frame(width:104,height:104).accessibilityElement(children:.ignore).accessibilityLabel(resource.rawValue + " " + (fraction.map { String(format:"%.0f Prozent",$0*100) } ?? "Auslastung nicht verfügbar"))
            Text(value.map(resource.formatted) ?? (resource == .storage && row.claims == 0 ? "Keine PVCs" : "Nicht verfügbar")).font(.callout.weight(.medium)).monospacedDigit()
            Text(limit.flatMap { $0 > 0 ? "von " + resource.formatted($0) : nil } ?? (resource == .network ? "RX / TX je Namespace fehlt" : "Kein vollständiges Limit")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical,17).frame(maxWidth:.infinity).background(resource.color.opacity(0.055),in:RoundedRectangle(cornerRadius:14))
    }
    @ViewBuilder private func trend(_ row: InfraNamespaceMetrics) -> some View {
        let samples = history.filter { $0.values.contains(where: { $0.id == row.id && metric.value($0) != nil }) }
        VStack(alignment:.leading,spacing:8) {
            Text(metric.rawValue + " · " + row.id).font(.headline)
            Text("Letzte 60 Minuten · Messungen bei geöffneter Ansicht").font(.caption).foregroundStyle(.secondary)
            if samples.count > 1 {
                Chart(samples) { sample in
                    if let value = sample.values.first(where:{$0.id == row.id}).flatMap({metric.value($0)}) {
                        LineMark(x:.value("Zeit",sample.date),y:.value(metric.axisUnit,metric.scaled(value))).foregroundStyle(metric.color)
                        PointMark(x:.value("Zeit",sample.date),y:.value(metric.axisUnit,metric.scaled(value))).foregroundStyle(metric.color).symbolSize(16)
                    }
                }.chartYAxisLabel(metric.axisUnit).chartYScale(domain:.automatic(includesZero:true)).frame(height:160)
            } else { Text("Der Verlauf entsteht mit den nächsten Minuten-Messungen.").font(.caption).foregroundStyle(.secondary).frame(height:45) }
        }
    }
}
