import AppKit
import ScreenSaver

@MainActor
enum ScreenSaverSupport {
    static func synchronize(video: WallpaperVideo?, aspect: AspectMode) {
        guard let defaults = ScreenSaverDefaults(forModuleWithName: "com.julianfink.MacTools.ScreenSaver") else { return }
        if let video { defaults.set(video.fileURL.path, forKey: "videoPath") }
        else { defaults.removeObject(forKey: "videoPath") }
        defaults.set(aspect.rawValue, forKey: "aspectMode")
        defaults.synchronize()
    }

    static func install() {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MacToolsScreenSaver.saver"),
              FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Bildschirmschoner fehlt im App-Bundle"
            alert.informativeText = "MacTools mit dem vollständigen Xcode-Projekt oder Scripts/build-local.sh neu bauen."
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
