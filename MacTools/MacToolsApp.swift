import SwiftUI

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsCategory: SettingsCategory = .general

    var body: some Scene {
        Settings {
            SettingsView(selectedCategory: $settingsCategory)
                .frame(width: 900, height: 720)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen …") { appDelegate.presentSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button("MacTools öffnen") { appDelegate.presentMainWindow() }
                    .keyboardShortcut("o")
                Button("Disk & Sicherheit öffnen") { appDelegate.presentMainWindow(section: .disk) }
                    .keyboardShortcut("d")
                Button("Systemmonitor öffnen") { appDelegate.presentMainWindow(section: .monitoring) }
                Button("Schnellaktionen") { NotificationCenter.default.post(name: .showMacToolsQuickPanel, object: nil) }
                Button("Live-Hintergrund öffnen") { appDelegate.presentMainWindow(section: .wallpaper) }
                Button("Fenster-Tool öffnen") { appDelegate.presentMainWindow(section: .windows) }
            }
        }
    }
}
