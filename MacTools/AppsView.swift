import SwiftUI

struct AppsView: View {
    @ObservedObject private var store = AppManagerStore.shared
    @State private var query = ""
    @State private var confirm = false
    private var apps: [InstalledApp] { store.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.identifier.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ToolPageHeader(title: "Apps", description: "Anwendungen und zugehörige Daten aufräumen.", icon: "app.badge")
                Button("Aktualisieren") { store.refresh() }.disabled(store.busy)
            }
            HStack {
                TextField("App suchen", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                Text("\(apps.count) Apps").font(.caption).foregroundStyle(.secondary)
                if store.busy { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(apps) { app in
                            Button { store.inspect(app) } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.headline).lineLimit(1)
                                        Text(app.version).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(10).background(store.plan?.app.id == app.id ? Color.accentColor.opacity(0.14) : .clear).clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                    }
                }.frame(width: 290)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let plan = store.plan {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.url.path)).resizable().frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.app.name).font(.title2.bold())
                                    Text(plan.app.identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Text("App-Daten können Dokumente, lokale Nachrichten oder Anmeldungen enthalten. Wähle nur aus, was du entfernen möchtest.").font(.caption).foregroundStyle(.secondary)
                            ForEach(plan.items) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Toggle(item.title, isOn: Binding(get: { store.selected.contains(item.id) }, set: { if $0 { store.selected.insert(item.id) } else { store.selected.remove(item.id) } })).labelsHidden().disabled(store.busy)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.headline)
                                        Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        Text(diskBytes(item.bytes) + (item.incomplete ? " · nicht vollständig lesbar" : "")).font(.caption).foregroundStyle(item.incomplete ? Color.orange : Color.secondary)
                                    }
                                    Spacer()
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }.help("Im Finder ansehen")
                                }.padding(14).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            HStack {
                                Text("Ausgewählt: " + diskBytes(plan.items.filter { store.selected.contains($0.id) }.reduce(0) { $0 + $1.bytes })).font(.headline)
                                Spacer()
                                Button("In Papierkorb …") { confirm = true }.buttonStyle(.borderedProminent)
                                    .disabled(store.busy || store.selected.isEmpty || plan.app.identifier == Bundle.main.bundleIdentifier)
                            }
                            Text("Gemeinsame Group-Container, Cloud-Daten und Systemdateien werden nicht automatisch zugeordnet. Ordner mit App-Namen müssen zusätzlich geprüft werden.").font(.caption).foregroundStyle(.secondary)
                        } else if !store.busy {
                            VStack(spacing: 12) {
                                Image(systemName: "app.badge").font(.system(size: 46)).foregroundStyle(.cyan)
                                Text("App auswählen").font(.title2.bold())
                                Text("Du siehst vor dem Entfernen jeden zugeordneten Bereich. Die Auswahl lässt sich im Finder-Papierkorb wiederherstellen.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.top, 70)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(28).onAppear { if store.apps.isEmpty { store.refresh() } }
            .alert("Auswahl in den Papierkorb verschieben?", isPresented: $confirm) {
                Button("Abbrechen", role: .cancel) {}
                Button("Entfernen", role: .destructive) { store.removeSelected() }
            } message: {
                Text("\(store.plan?.app.name ?? "App") wird bei Bedarf beendet. \(store.selected.count) ausgewählte Bereiche werden entfernt. App-Daten können persönliche Inhalte enthalten. Wiederherstellen ist über den Papierkorb möglich.")
            }
    }
}
