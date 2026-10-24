import AppKit
import SwiftUI

@MainActor final class MonitorPopupChecks: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var widgets: MonitorMenuWidgets!
    private var timer: Timer?
    private var cycling: Task<Void, Never>?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var worstTick: Double = 0
    private var timings: [Double] = []
    private var requested = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults(suiteName: "MacTools.MonitorPopupChecks")!
        defaults.removePersistentDomain(forName: "MacTools.MonitorPopupChecks")
        defaults.set([], forKey: "monitorMenuWidgets")
        widgets = MonitorMenuWidgets(settings: SettingsStore(defaults: defaults), openMonitor: {}, openSettings: {})
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "QA"
        SystemMonitor.shared.start()
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 460, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CPU/RAM · isolierter Wechseltest"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 18) {
            Text("Echte Monitor-Popups und vorhandene Messhistorie")
            Button("CPU öffnen") { self.show(.cpu) }
            Button("RAM öffnen") { self.show(.ram) }
            Button("12 Wechsel CPU / RAM testen") { self.cycle() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.makeKeyAndOrderFront(nil)
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        root.submenu = appMenu
        appMenu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(root); NSApp.mainMenu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func show(_ metric: MonitorMetric) {
        guard let button = item.button else { return }
        let start = ProcessInfo.processInfo.systemUptime
        widgets.show(metric, from: button)
        timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        requested = metric.title
        record()
    }
    private func cycle() {
        cycling?.cancel(); timings = []; worstTick = 0
        cycling = Task {
            for index in 0..<12 {
                if Task.isCancelled { return }
                show(index % 2 == 0 ? .cpu : .ram)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            record()
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        worstTick = max(worstTick, (now - lastTick) * 1000); lastTick = now
        record()
    }
    private func record() {
        let popup = NSApp.windows.first { NSStringFromClass(type(of: $0)).contains("Popover") && $0.isVisible }
        let data: [String: Any] = ["requested": requested, "switchMs": timings,
            "worstMainLoopMs": worstTick, "historyPoints": SystemMonitor.shared.history.count,
            "shown": popup != nil, "key": popup?.isKeyWindow ?? false,
            "frame": popup.map { NSStringFromRect($0.frame) } ?? ""]
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) {
            try? encoded.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("monitor-popup-checks.json"))
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        cycling?.cancel(); timer?.invalidate(); widgets.shutdown(); SystemMonitor.shared.stop()
        NSStatusBar.system.removeStatusItem(item)
    }
}
@main struct MonitorPopupChecksApp {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = MonitorPopupChecks(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
