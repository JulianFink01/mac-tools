import AppKit
import SwiftUI
import Darwin

struct SecurityScanPanel: View {
    @ObservedObject var store: DiskScanStore
    @ObservedObject var security: SecurityScanStore
    let requestTrash: ([DiskFile]) -> Void
    @ObservedObject private var actions = FileActions.shared
    @State private var selected: [String: DiskFile] = [:]
    @State private var query = ""
    @State private var page = 0
    @State private var showLimits = false
    private var running: Bool { security.isScanning || security.isUpdating }
    private var findings: [SecurityFinding] { security.report?.items.filter { !$0.isLimit } ?? [] }
    private var filtered: [SecurityFinding] {
        findings.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || $0.signature.localizedCaseInsensitiveContains(query) }
    }
    private var tint: Color {
        guard let report = security.report else { return .cyan }
        return report.threatCount > 0 ? .red : report.hasWarnings || report.exitCode > 1 ? .orange : .green
    }
    private var heroIcon: String { (security.report?.threatCount ?? 0) > 0 ? "exclamationmark.shield.fill" : "shield.lefthalf.filled" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: heroIcon)
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(running ? .cyan : tint)
                        .frame(width: 58, height: 58).background((running ? Color.cyan : tint).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(running ? "Deine Dateien werden geprüft" : security.report?.title ?? "Virenschutz für deinen Mac")
                            .font(.title2.bold())
                        Text(running ? security.status : security.report?.explanation ?? "Prüfe deine Dateien mit lokalen ClamAV-Signaturen.")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if let date = security.completedAt, !running {
                            Text("Letzte Prüfung · " + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if running { Button("Abbrechen") { security.cancel() } }
                    else {
                        Button("Virenprüfung starten", action: startScan).buttonStyle(.borderedProminent)
                            .disabled(security.executable == nil || store.isScanning)
                    }
                }
                if running {
                    if let progress = security.progressFraction {
                        HStack { ProgressView(value: progress).tint(.cyan); Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().font(.caption) }
                    } else { ProgressView().controlSize(.small) }
                }
                Divider()
                HStack {
                    Label(security.executable == nil ? "Engine fehlt" : "Lokal auf deinem Mac", systemImage: "desktopcomputer")
                    Spacer()
                    Button("Schutzdaten aktualisieren") { Task { await security.updateSignatures() } }.disabled(running)
                }.font(.caption).foregroundStyle(.secondary)
                Text(security.signatureStatus).font(.caption).foregroundStyle(.secondary)
                if let root = security.scannedRoot { Text("Letzter geprüfter Bereich: " + root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16))

            if let report = security.report {
                HStack(spacing: 12) {
                    metric("Geprüfte Dateien", value: (report.scannedFiles + (report.reusedFiles ?? 0)).formatted(), icon: "doc.text.magnifyingglass", color: .cyan)
                    metric("Verdächtige Dateien", value: report.threatCount.formatted(), icon: "exclamationmark.shield", color: report.threatCount > 0 ? .red : .green)
                    metric("Testdateien", value: findings.filter(\.isTest).count.formatted(), icon: "checkmark.seal", color: .blue)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Funde & Testdateien").font(.headline)
                        Text("\(findings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        TextField("Name, Pfad oder Erkennung suchen", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    }
                    if findings.isEmpty {
                        Label((report.removedPaths ?? []).isEmpty ? "Keine Funde in den geprüften Dateien." : "Die gemeldeten Dateien wurden entfernt.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        HStack {
                            Button("Diese Seite auswählen") {
                                for item in pageItems {
                                    if let file = snapshot(item) { selected[item.path] = file }
                                }
                            }.disabled(running)
                            if !selected.isEmpty {
                                Button("Auswahl aufheben") { selected = [:] }
                                Spacer()
                                Button { requestTrash(Array(selected.values)); selected = [:] } label: {
                                    Label("In Papierkorb (\(selected.count)) …", systemImage: "trash")
                                }.disabled(running).tint(.red)
                            }
                        }
                        ForEach(pageItems) { item in findingRow(item) }
                        HStack {
                            Text("\(filtered.count.formatted()) Treffer").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).help("Vorherige Seite")
                            Text("\(page + 1) / \(max(1, (filtered.count + 19) / 20))").font(.caption.monospacedDigit())
                            Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled((page + 1) * 20 >= filtered.count).help("Nächste Seite")
                        }
                    }
                    if let removed = report.removedPaths, !removed.isEmpty {
                        Label("\(removed.count.formatted()) gemeldete Dateien aus der Liste entfernt · kein neuer Scan", systemImage: "trash.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if security.restoredReport {
                        Text("Gespeichertes Ergebnis. Vor dem Verschieben werden die aktuellen Dateimetadaten kontrolliert; die Virenprüfung wird dafür nicht erneut gestartet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16))

                DisclosureGroup("Nicht vollständig geprüft · Hinweise", isExpanded: $showLimits) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Prüflimits sind keine bestätigten Virusfunde.").font(.callout).foregroundStyle(.secondary)
                        if let limited = report.limitedFiles, limited > 0 { Text("\(limited.formatted()) Dateien über 2 GiB nicht inhaltlich geprüft.") }
                        if let excluded = report.excludedFiles, excluded > 0 { Text("\(excluded.formatted()) Cloud-, veränderte oder nicht erreichbare Dateien ausgelassen.") }
                        if let empty = report.emptyFiles, empty > 0 { Text("\(empty.formatted()) leere Dateien ohne prüfbaren Inhalt.") }
                        ForEach(Array(report.items.filter(\.isLimit).prefix(20))) { findingRow($0) }
                        if report.items.filter(\.isLimit).count > 20 { Text("Weitere Prüflimits stehen im technischen Bericht.").foregroundStyle(.secondary) }
                    }.padding(.top, 12).font(.caption)
                }.padding(18).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16))
                DisclosureGroup("Technischer Bericht") {
                    Text("Engine-Status: \(report.exitCode)\n" + report.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.font(.caption)
            }
            if !security.technicalLog.isEmpty {
                DisclosureGroup("Details zum Prüfproblem") {
                    Text(security.technicalLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.font(.caption)
            }
            Text("Lokale Prüfung · keine Uploads · kein Echtzeitschutz. Dateien werden ausschließlich nach deiner Auswahl und Bestätigung in den Papierkorb verschoben.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: query) { _ in page = 0 }
        .onChange(of: security.completedAt) { _ in selected = [:]; page = 0 }
        .onChange(of: security.report?.removedPaths) { _ in selected = [:]; page = min(page, max(0, (filtered.count - 1) / 20)) }
    }
    private var pageItems: [SecurityFinding] { Array(filtered.dropFirst(page * 20).prefix(20)) }
    private func metric(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
            .background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 13))
    }
    private func findingRow(_ item: SecurityFinding) -> some View {
        HStack(spacing: 12) {
            if !item.isLimit {
                Toggle("Auswählen", isOn: Binding(get: { selected[item.path] != nil }, set: { enabled in
                    if enabled, let file = snapshot(item) { selected[item.path] = file } else { selected.removeValue(forKey: item.path) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(running).accessibilityLabel(item.url.lastPathComponent + " auswählen")
            }
            Image(systemName: item.isTest ? "checkmark.seal" : item.isLimit ? "info.circle" : "exclamationmark.shield.fill")
                .foregroundStyle(item.isTest ? Color.blue : item.isLimit ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text(item.isTest ? "EICAR-Testdatei · kein echter Virus" : item.isLimit ? "Prüflimit · kein bestätigter Virusfund" : (item.signature.localizedCaseInsensitiveContains("phishing") ? "Phishing-Verdacht · " : "") + item.signature)
                    .font(.caption).foregroundStyle(item.isTest ? Color.blue : item.isLimit ? Color.orange : Color.red)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }.help("Im Finder anzeigen")
            Button {
                if let file = snapshot(item) { requestTrash([file]) }
            } label: { Image(systemName: "trash") }.help("In den Papierkorb verschieben").accessibilityLabel(item.url.lastPathComponent + " in den Papierkorb verschieben").disabled(running)
        }.padding(12).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func snapshot(_ finding: SecurityFinding) -> DiskFile? {
        guard let root = security.scannedRoot, finding.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            actions.status = "Die Datei liegt außerhalb des geprüften Bereichs."; return nil
        }
        do { return try DiskFile.snapshot(at: finding.url) }
        catch {
            var info = stat()
            if lstat(finding.path, &info) != 0, errno == ENOENT {
                actions.status = "Die Datei existiert nicht mehr. Der Eintrag wird aus dem Ergebnis entfernt."
                security.applyRemoved(paths: [finding.path])
            } else { actions.status = "Die Datei ist derzeit nicht lesbar oder kein reguläres File. Bitte im Finder prüfen." }
            return nil
        }
    }
    private func startScan() {
        let inventory = store.result?.root == store.root && !store.resultIsProvisional ? store.result : nil
        Task { if await security.updateSignaturesIfNeeded() { security.start(root: store.root, inventory: inventory) } }
    }
}
