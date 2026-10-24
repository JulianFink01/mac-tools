import ServiceManagement
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "Allgemein"
    case quickPanel = "Schnellansicht"
    case navigation = "Navigation"
    case monitoring = "Systemmonitor"
    case disk = "Disk & Sicherheit"
    case wallpaper = "Live-Hintergrund"
    case windows = "Fenster vorn halten"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .quickPanel: return "rectangle.grid.1x2"
        case .navigation: return "sidebar.left"
        case .monitoring: return "waveform.path.ecg"
        case .disk: return "internaldrive"
        case .wallpaper: return "play.rectangle"
        case .windows: return "pin"
        }
    }
}

struct SettingsView: View {
    @Binding var selectedCategory: SettingsCategory
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var disk = DiskScanStore.shared
    @ObservedObject private var security = SecurityScanStore.shared
    @ObservedObject private var automatic = AutomaticScans.shared
    @ObservedObject private var popup = CodexPopupController.shared
    @ObservedObject private var pin = WindowPinController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ToolPageHeader(title: "Einstellungen", description: "Passe MacTools und jedes deiner Tools gezielt an.", icon: "gearshape")
            ToolTabBar(selection: $selectedCategory, options: SettingsCategory.allCases.map { ToolTab(value: $0, title: $0.rawValue, icon: $0.icon) }, accessibilityName: "Einstellungen")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedCategory {
                    case .quickPanel: QuickPanelSettingsView()
                    case .navigation: navigationSettings
                    case .general: generalSettings
                    case .monitoring: monitorSettings
                    case .disk: diskSettings
                    case .wallpaper: wallpaperSettings
                    case .windows: windowSettings
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { settings.refreshStartAtLoginStatus(); pin.refreshAccessibilityPermission() }
    }

    private var navigationSettings: some View {
        ToolSettingsCard(title: "Deine Favoriten", description: "Wähle unabhängig, welche Tools links in der App und oben in der macOS-Menüleiste erscheinen.") {
            Toggle("MacTools-Hauptsymbol in der Menüleiste", isOn: $settings.showMainMenuIcon)
            Text("Ziehe die Favoriten direkt in der Seitenleiste in deine Reihenfolge. Cmd-Ziehen aus der macOS-Menüleiste entfernt den jeweiligen Eintrag dauerhaft.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack { Text("Werkzeug"); Spacer(); Text("Seitenleiste").frame(width: 100); Text("Menüleiste").frame(width: 100) }.font(.caption).foregroundStyle(.secondary)
            ForEach(ToolNavigation.Section.pinnable) { tool in
                HStack {
                    Label(tool.rawValue, systemImage: tool.icon)
                    Spacer()
                    Toggle(tool.rawValue + " in Seitenleiste", isOn: Binding(get: { settings.sidebarTools.contains(tool) }, set: { settings.setSidebarFavorite(tool, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).frame(width: 100)
                    Toggle(tool.rawValue + " in Menüleiste", isOn: Binding(get: { settings.pinnedTools.contains(tool) }, set: { settings.setPinned(tool, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).frame(width: 100)
                }.padding(.vertical, 8)
                if tool != ToolNavigation.Section.pinnable.last { Divider() }
            }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 18) {
            ToolSettingsCard(title: "Start & Hintergrundbetrieb", description: "MacTools bleibt über die Menüleiste erreichbar, wenn du das Hauptfenster schließt.") {
                HStack {
                    Toggle("MacTools bei der Anmeldung starten", isOn: Binding(
                        get: { settings.wantsStartAtLogin }, set: { settings.setStartAtLogin($0) }
                    ))
                    Spacer()
                    Button("Anmeldeobjekte öffnen") { SMAppService.openSystemSettingsLoginItems() }
                }
                Text(settings.loginItemStatusText).font(.callout).foregroundStyle(.secondary)
                if let error = settings.loginItemError { Text(error).foregroundStyle(.orange) }
            }
            ToolSettingsCard(title: "Codex-Chatfenster", description: "Öffne bestehende Chats aus der Schnellansicht in einem eigenen Fenster. Das globale Tastenkürzel öffnet einen neuen Chat-Entwurf.") {
                HStack { Text("Neuer Chat per Tastenkürzel"); Spacer(); CodexPopupShortcutRecorder().frame(width: 280, height: 28) }
                Toggle("Chatfenster standardmäßig im Vordergrund halten", isOn: $settings.chatPopupAlwaysOnTop)
                Text("Native Fenster-Ebene · ohne Bildschirmaufnahme oder virtuellen Bildschirm").font(.caption).foregroundStyle(.secondary)
                if let error = popup.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Neues Chatfenster öffnen") { popup.show() }
            }
            ToolSettingsCard(title: "Über MacTools", description: "Speicher und Sicherheit stehen im Mittelpunkt. Weitere Werkzeuge erreichst du links unter „Tools“.") {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                DisclosureGroup("Technische Informationen") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("App-Speicherort: \(settings.appBundlePath)")
                        if settings.usesLaunchAgentFallback { Text("Autostart-Datei: \(LaunchAgentLoginItem.plistURL.path)") }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                }
            }
        }
    }

    private var monitorSettings: some View {
        VStack(spacing: 18) {
            ToolSettingsCard(title: "Widgets in der Menüleiste", description: "Ein Klick auf einen Messwert öffnet seine Detailansicht.") {
                HStack(spacing: 8) {
                    ForEach(MonitorMetric.allCases.filter { settings.enabledMonitorWidgets.contains($0) }) { metric in
                        MonitorWidgetPreview(metric: metric).frame(width: 42, height: NSStatusBar.system.thickness)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.16)).clipShape(Capsule())
                    }
                    if settings.enabledMonitorWidgets.isEmpty { Text("Alle Widgets ausgeblendet").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(.bottom, 8)
                ForEach(MonitorMetric.allCases) { metric in
                    HStack(spacing: 14) {
                        Image(systemName: metric.icon).foregroundStyle(metric.color).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title).font(.headline)
                            Text(metric.settingsDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(metric.title + " in der Menüleiste", isOn: Binding(
                            get: { settings.enabledMonitorWidgets.contains(metric) },
                            set: { settings.setWidget(metric, enabled: $0) }
                        )).labelsHidden().toggleStyle(.switch)
                    }.padding(.vertical, 4)
                    if metric != MonitorMetric.allCases.last { Divider() }
                }
            }
            ToolSettingsCard(title: "Live-Messungen", description: "CPU, RAM, GPU, Datenträger und Netzwerk werden alle zwei Sekunden aktualisiert.") {
                Text("Die Widgets lassen sich unabhängig voneinander ausschalten. Das Systemmonitor-Dashboard bleibt verfügbar.").font(.callout).foregroundStyle(.secondary)
                Text("Verläufe zeigen bis zu 30 Minuten gemessene Werte. Fehlende Treiberdaten erscheinen als —.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var diskSettings: some View {
        VStack(spacing: 18) {
            ToolSettingsCard(title: "Automatische Prüfungen", description: "Jeder automatische Scan erfasst den Speicher, findet identische Inhalte und prüft mit ClamAV auf bekannte Bedrohungen.") {
                Toggle("Automatische Scans aktivieren", isOn: $automatic.enabled)
                Picker("Wie häufig?", selection: $automatic.intervalHours) {
                    Text("Stündlich").tag(1)
                    Text("Alle 6 Stunden").tag(6)
                    Text("Täglich").tag(24)
                }.frame(maxWidth: 340, alignment: .leading).disabled(!automatic.enabled)
                Text(automatic.status).font(.callout).foregroundStyle(.secondary)
                Text("Scans laufen nur, wenn MacTools geöffnet und dein Mac wach ist.").font(.caption).foregroundStyle(.secondary)
            }
            ToolSettingsCard(title: "Scanbereich auf diesem Mac", description: "Automatische Scans verwenden diesen Bereich. Externe Laufwerke behalten unter Disk & Sicherheit eigene Scanstände.") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(disk.root.lastPathComponent).font(.headline)
                        Text(disk.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Ordner wählen …") { DiskVolumeStore.shared.chooseFolder(initialDirectory: disk.root) }
                        .disabled(disk.isScanning || security.isScanning || security.isUpdating)
                }
                Label("Inhaltsprüfung auf Duplikate ist Teil jedes Gesamtscans", systemImage: "checkmark.circle.fill")
                Text("Auch Dateien mit anderem Namen werden erkannt. Die Inhaltsprüfung kann bei großen Ordnern länger dauern; beim Scan wird nichts gelöscht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolSettingsCard(title: "Warnungen & Mitteilungen", description: "Erhalte Hinweise zu Virenfunden, Scanproblemen und knappem Speicher.") {
                Text(automatic.notificationStatus).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Mitteilungen erlauben") { automatic.requestNotifications() }
                    Button("macOS-Mitteilungseinstellungen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
                Text("Alle Hinweise bleiben zusätzlich unter Disk & Sicherheit → Warnungen gespeichert.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var wallpaperSettings: some View {
        VStack(spacing: 18) {
            ToolSettingsCard(title: "Darstellung", description: "Bestimme, wie deine Videos auf dem Desktop und im Bildschirmschoner angezeigt werden.") {
                Picker("Video auf dem Bildschirm", selection: Binding(get: { settings.aspectMode }, set: { settings.setAspectMode($0) })) {
                    ForEach(AspectMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 280)
                Text("Füllen nutzt den ganzen Bildschirm und kann Ränder abschneiden. Einpassen zeigt das vollständige Video mit möglichen freien Rändern.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolSettingsCard(title: "Video bei gesperrtem Mac", description: "Nutze dein ausgewähltes Video auch als macOS-Bildschirmschoner.") {
                Text("1. Video-Bildschirmschoner installieren.\n2. In macOS den Bildschirmschoner „MacTools“ wählen.\n3. Die Passwortabfrage beim Sperren in macOS einstellen.")
                    .font(.callout).lineSpacing(6)
                HStack {
                    Button("Bildschirmschoner installieren …") { ScreenSaverSupport.install() }
                    Button("Bildschirmschoner-Einstellungen") { ScreenSaverSupport.openSettings() }
                }
                Text("Die Sichtbarkeit hinter der Passwortabfrage hängt von macOS ab. Bei ausgeschaltetem Display oder vor der Anmeldung läuft kein Video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var windowSettings: some View {
        VStack(spacing: 18) {
            ToolSettingsCard(title: "Tastenkürzel", description: "Mit derselben Tastenkombination heftest du das aktuelle Fenster an und löst es wieder.") {
                HStack {
                    Text("Fenster vorn halten / lösen")
                    Spacer()
                    PinShortcutRecorder(controller: pin).frame(width: 260, height: 28)
                }
                Text("Klicke auf das Tastenkürzel und drücke die gewünschte Kombination. Esc bricht die Aufnahme ab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolSettingsCard(title: "Live-Ansicht über anderen Apps", description: "Eine lokale, laufende Ansicht deiner gewählten Fenster. Kein Upload, keine Aufnahme auf der Festplatte.") {
                Label(pin.hasScreenCapturePermission ? "Bildschirmaufnahme freigegeben" : "Bildschirmaufnahme noch nicht freigegeben",
                      systemImage: pin.hasScreenCapturePermission ? "checkmark.shield" : "rectangle.on.rectangle")
                    .foregroundStyle(pin.hasScreenCapturePermission ? Color.green : Color.orange)
                HStack {
                    Button("Bildschirmaufnahme in macOS freigeben") { pin.openScreenCaptureSettings() }
                    Button("Status prüfen") { pin.refreshAccessibilityPermission(userInitiated: true) }
                }
                Text("Die Fenster bleiben sichtbar, wenn du das MacTools-Menü schließt oder eine andere App verwendest. Einzelne Fenster löst du in der Toolbox. Nach einer neuen macOS-Freigabe kann ein Neustart von MacTools nötig sein.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolSettingsCard(title: "Freigabe zur Fenstersteuerung", description: "MacTools benötigt die macOS-Freigabe, um die ausgewählten Originalfenster zu erkennen und zu bedienen.") {
                Label(pin.hasAccessibilityPermission ? "Fensterzugriff von macOS bestätigt" : "macOS bestätigt den Fensterzugriff noch nicht",
                      systemImage: pin.hasAccessibilityPermission ? "checkmark.shield" : "lock.shield")
                    .foregroundStyle(pin.hasAccessibilityPermission ? Color.green : Color.orange)
                HStack {
                    Button("macOS-Einstellungen öffnen") { pin.openAccessibilitySettings() }
                    Button("Status erneut prüfen") { pin.refreshAccessibilityPermission(userInitiated: true) }
                }
                if let checkedAt = pin.manualAccessibilityCheckAt {
                    Text("Manuelle Statusprüfung: " + checkedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !pin.hasAccessibilityPermission {
                    Text("Schalter eingeschaltet, aber kein Zugriff?").font(.headline)
                    Text("Bei älteren lokalen Builds kann macOS noch einen veralteten App-Eintrag gespeichert haben. Ein eingeschalteter Schalter allein bestätigt dann keinen Zugriff.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("1. In macOS den vorhandenen MacTools-Eintrag markieren und mit − entfernen.\n2. Mit + die aktuelle MacTools-App aus Programme hinzufügen und einschalten.\n3. MacTools neu starten und den Status erneut prüfen.")
                        .font(.callout).lineSpacing(6)
                    HStack {
                        Button("Aktuelle MacTools-App zeigen") { pin.revealInstalledApp() }
                        Button("MacTools neu starten") { pin.restartApp() }
                    }
                }
                Text(pin.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
