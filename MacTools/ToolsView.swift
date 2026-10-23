import SwiftUI

struct ToolsView: View {
    @ObservedObject var navigation: ToolNavigation
    @ObservedObject private var settings = SettingsStore.shared
    @State private var menuDrop = false
    @State private var favoriteDrop = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ToolPageHeader(title: "Alle Werkzeuge", description: "Ziehe Werkzeuge in deine Seitenleiste oder in die Menüleiste.", icon: "square.grid.2x2")
                HStack(spacing: 16) {
                    Label("Seitenleiste · Favoriten", systemImage: "sidebar.left").frame(maxWidth: .infinity).padding(18).background(favoriteDrop ? Color.mint.opacity(0.15) : Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 12))
                        .onDrop(of: [.text], isTargeted: $favoriteDrop) { providers in ToolDrop.receive(providers) { settings.setSidebarFavorite($0, enabled: true) } }
                    Label("macOS-Menüleiste", systemImage: "menubar.rectangle").frame(maxWidth: .infinity).padding(18).background(menuDrop ? Color.mint.opacity(0.15) : Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 12))
                        .onDrop(of: [.text], isTargeted: $menuDrop) { providers in ToolDrop.receiveMenu(providers) }
                }.font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), alignment: .top)], spacing: 16) {
                    ForEach(ToolNavigation.Section.pinnable) { tool in
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: tool.icon).font(.system(size: 23)).foregroundStyle(.mint).frame(width: 44, height: 44).background(Color.mint.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(tool.rawValue).font(.system(size: 16, weight: .semibold))
                                Text(tool.detail).font(.callout).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { navigation.section = tool }.accessibilityElement(children: .ignore).accessibilityLabel(tool.rawValue + " öffnen").accessibilityAddTraits(.isButton).accessibilityAction { navigation.section = tool }


                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16)).onDrag { NSItemProvider(object: (ToolDrop.prefix + tool.rawValue) as NSString) }
                    }
                }
                Button("Navigation & Favoriten einstellen") { navigation.openSettings(.navigation) }.buttonStyle(.plain).foregroundStyle(.secondary)

            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct ContainersView: View {
    @ObservedObject private var store = ContainerStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ToolPageHeader(title: "Container", description: "Laufende Docker- und Podman-Container mit ihren Ports. Die Liste aktualisiert sich automatisch.", icon: "shippingbox")
                HStack {
                    Text("\(store.containers.count) laufen").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aktualisieren") { Task { await store.refresh() } }
                }
                if let warning = store.refreshError { Label(warning, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
                if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if store.containers.isEmpty { Text("Keine laufenden Container gefunden. Docker oder Podman muss lokal erreichbar sein.").foregroundStyle(.secondary).padding(.vertical, 32) }
                ForEach(store.containers) { container in
                    HStack(spacing: 18) {
                        Image(systemName: "shippingbox").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(container.name).font(.headline)
                            Text(container.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Text(container.image).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { Task { await store.stop(container) } } label: { Label(store.stopping.contains(container.id) ? "Stoppt …" : "Stoppen", systemImage: "stop.fill") }
                            .disabled(store.stopping.contains(container.id)).accessibilityLabel(container.name + " stoppen")
                    }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.onAppear { store.start() }
    }
}
