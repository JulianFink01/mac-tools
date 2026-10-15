import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: SettingsStore
    private let library: VideoLibraryStore
    private lazy var wallpaperController = WallpaperController(settings: settings, library: library)
    private var menuBarController: MenuBarController?
    private var monitorWidgets: MonitorMenuWidgets?
    private var cancellables = Set<AnyCancellable>()
    private var mainWindow: NSWindow?
    private let navigation = ToolNavigation()
    private var pausedForSystemSleep = false

    override init() {
        settings = .shared; library = .shared
        super.init()
    }

    init(settings: SettingsStore, library: VideoLibraryStore) {
        self.settings = settings; self.library = library
        super.init()
    }

    var wallpaperPlaybackSnapshot: [(seconds: TimeInterval, rate: Float)] { wallpaperController.playbackSnapshot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateLoginAgentDuplicate() {
            NSApp.terminate(nil)
            return
        }

        terminateDuplicateInstances()
        do { try LaunchAgentLoginItem.refreshInstalledAppPath() }
        catch { settings.loginItemError = error.localizedDescription }
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(
            settings: settings,
            library: library,
            openSection: { [weak self] section in self?.presentMainWindow(section: section) },
            openSettings: { [weak self] category in self?.presentSettings(category) },
            randomWallpaper: { [weak self] in self?.selectRandomWallpaper() }
        )

        monitorWidgets = MonitorMenuWidgets(settings: settings,
            openMonitor: { [weak self] in self?.presentMainWindow(section: .monitoring) },
            openSettings: { [weak self] in self?.presentSettings(.monitoring) })
        WindowPinController.shared.start(onFailure: { [weak self] in self?.presentMainWindow(section: .windows) })
        bindState()
        registerNotifications()
        wallpaperController.start()
        synchronizeScreenSaver()
        AutomaticScans.shared.start()
        SystemMonitor.shared.start()

        if !CommandLine.arguments.contains(LaunchAgentLoginItem.launchArgument) {
            presentMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings.refreshStartAtLoginStatus()
        WindowPinController.shared.refreshAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMonitor.shared.stop()
        DiskScanStore.shared.cancel()
        SecurityScanStore.shared.cancel()
        WindowPinController.shared.stop()
        wallpaperController.closeAllWindows()
    }

    private func terminateDuplicateInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        duplicates.forEach { app in
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    private func shouldTerminateLoginAgentDuplicate() -> Bool {
        guard CommandLine.arguments.contains(LaunchAgentLoginItem.launchArgument),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID }
    }

    // @Published emits before its property is stored. Deliver on the next run-loop
    // turn so player and screensaver read the updated pause/video/aspect values.
    func bindState() {
        settings.$currentVideoID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.wallpaperController.applyCurrentVideo()
                self?.synchronizeScreenSaver()
            }
            .store(in: &cancellables)

        settings.$aspectMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.wallpaperController.updateAspectMode()
                self?.synchronizeScreenSaver()
            }
            .store(in: &cancellables)

        settings.$isPaused
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPaused in
                if isPaused {
                    self?.wallpaperController.pausePlayback()
                } else {
                    self?.wallpaperController.resumePlayback()
                }
            }
            .store(in: &cancellables)

        library.$videos
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] videos in
                guard let self else { return }
                if let currentVideoID = self.settings.currentVideoID,
                   !videos.contains(where: { $0.id == currentVideoID }) {
                    self.settings.setCurrentVideo(videos.first?.id)
                }
            }
            .store(in: &cancellables)
    }

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func synchronizeScreenSaver() {
        ScreenSaverSupport.synchronize(video: library.video(with: settings.currentVideoID), aspect: settings.aspectMode)
    }

    func presentMainWindow(section: ToolNavigation.Section = .monitoring) {
        navigation.section = section
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = MacToolsView(navigation: navigation)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 1240, height: 760)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    func presentSettings(_ category: SettingsCategory = .general) {
        navigation.openSettings(category)
        presentMainWindow(section: .settings)
    }

    private func selectRandomWallpaper() {
        guard let random = library.randomVideo(excluding: settings.currentVideoID) else { return }
        settings.setCurrentVideo(random.id)
        settings.setPaused(false)
    }

    @objc private func screenConfigurationChanged() {
        wallpaperController.handleScreenConfigurationChanged()
    }

    @objc private func workspaceWillSleep() {
        pausedForSystemSleep = !settings.isPaused
        wallpaperController.pausePlayback()
    }

    @objc private func workspaceDidWake() {
        guard pausedForSystemSleep else { return }
        pausedForSystemSleep = false
        wallpaperController.resumePlayback()
    }
}
