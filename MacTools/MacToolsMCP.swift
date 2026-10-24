import SwiftUI
import AppKit

struct MCPPageView: View {
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) { ToolPageHeader(title: "MacTools MCP", description: "Lokale Werkzeuge für Codex und andere MCP-Clients", icon: "point.3.connected.trianglepath.dotted"); MCPToolsSettingsView() }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity) } }
}

struct MCPToolsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MacTools MCP", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            Text("Lokale Schnittstelle für Systemwerte, Fenster, Container, Codex-Chats und Kontingente. Der MCP-Server benötigt eine laufende MacTools-App.").font(.callout).foregroundStyle(.secondary)
            Text("Sprachbefehle funktionieren in Clients, die diese MCP-Werkzeuge im Sprachmodus unterstützen.").font(.caption).foregroundStyle(.secondary)
            Button("MCP-Konfiguration kopieren") {
                let config: [String: Any] = ["mcpServers": ["mactools": ["command": "/usr/bin/python3", "args": [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MCP/server/server.py").path]]]]
                if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
        }
    }
}

@MainActor final class MacToolsBridgeServer {
    private let server = LocalToolBridgeServer()
    func start(open: @escaping (ToolNavigation.Section) -> Void, menuStatus: @escaping () -> [String: Any], restoreMenu: @escaping () -> Void) throws {
        try server.start(name: "app") { action, params in
            let codex = CodexStore.shared
            switch action {
            case "menu_status": return menuStatus()
            case "menu_restore": restoreMenu(); return ["requested": true, "status": menuStatus()]
            case "overview":
                let point = SystemMonitor.shared.reading?.point
                return ["app": "MacTools", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "sampledAt": point?.date.timeIntervalSince1970 as Any? ?? NSNull(), "cpuPercent": point?.cpu as Any? ?? NSNull(), "memoryPercent": point?.memory as Any? ?? NSNull(), "gpuPercent": point?.gpu as Any? ?? NSNull(), "runningChats": codex.runningCount, "waitingChats": codex.waitingCount, "localCodexWork": CodexQueueRepository.shared.hasLocalWork, "wallpaperPaused": SettingsStore.shared.isPaused, "integrations": PrivateMCPStore.shared.services.map { service in ["id":service.id, "enabled":service.enabled, "critical":service.critical, "state":service.stateLabel, "stats":service.health?.stats ?? [], "checkedAt":service.health?.checkedAt.timeIntervalSince1970 as Any? ?? NSNull()] as [String:Any] }]
            case "open":
                guard let name = params["section"] as? String, let section = ToolNavigation.Section.allCases.first(where: { $0.rawValue == name }) else { throw LocalToolBridge.BridgeError(message: "Unbekanntes Werkzeug.") }; open(section); return ["opened": name]
            case "wallpaper_pause":
                guard let paused = params["paused"] as? Bool else { throw LocalToolBridge.BridgeError(message: "paused muss ein Wahrheitswert sein.") }; SettingsStore.shared.setPaused(paused); return ["paused": SettingsStore.shared.isPaused]
            case "codex_usage":
                codex.start(); if !codex.connected { await codex.connect() }; await codex.loadUsage()
                return ["buckets": codex.usageBuckets.map { bucket in ["id": bucket.id, "title": bucket.title, "windows": bucket.windows.map { ["window": $0.label, "remainingPercent": $0.remaining, "resetsAt": $0.resetsAt?.timeIntervalSince1970 as Any? ?? NSNull()] }] }, "updatedAt": codex.usageUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(), "error": codex.usageError as Any? ?? NSNull()]
            case "codex_list":
                codex.start(); if !codex.connected { await codex.connect() }
                return ["chats": codex.liveChats.map { ["id": $0.id, "title": $0.title, "status": $0.status, "flags": $0.flags, "activityAt": $0.updatedAt.timeIntervalSince1970] }]
            case "codex_open":
                let id = params["id"] as? String
                if let id, UUID(uuidString: id) == nil { throw LocalToolBridge.BridgeError(message: "Ungültige Chat-ID.") }
                let window = CodexPopupController.shared.show(chatID: id)
                return ["opened": id as Any? ?? NSNull(), "windowId": window.uuidString]
            case "codex_windows": return ["windows": CodexPopupController.shared.diagnostics, "mainChatId": codex.selectedID as Any? ?? NSNull()]
            case "codex_window_pin", "codex_window_close":
                guard let value = params["id"] as? String, let id = UUID(uuidString: value) else { throw LocalToolBridge.BridgeError(message: "Ungültige Fenster-ID.") }
                if action == "codex_window_pin" {
                    guard let enabled = params["pinned"] as? Bool, CodexPopupController.shared.pin(id, enabled: enabled) else { throw LocalToolBridge.BridgeError(message: "Chatfenster nicht gefunden oder Pin-Wert fehlt.") }; return ["id": value, "pinned": enabled]
                }
                guard CodexPopupController.shared.close(id) else { throw LocalToolBridge.BridgeError(message: "Chatfenster nicht gefunden.") }; return ["closed": value]
            case "containers_list":
                await ContainerStore.shared.refresh(); return ["containers": ContainerStore.shared.containers.map { ["id": $0.id, "name": $0.name, "image": $0.image, "ports": $0.ports] }, "error": ContainerStore.shared.refreshError as Any? ?? NSNull(), "updatedAt": ContainerStore.shared.refreshedAt?.timeIntervalSince1970 as Any? ?? NSNull()]
            case "container_stop":
                await ContainerStore.shared.refresh(); guard let item = ContainerStore.shared.containers.first(where: { $0.id == params["id"] as? String }) else { throw LocalToolBridge.BridgeError(message: "Laufender Container nicht gefunden.") }; await ContainerStore.shared.stop(item); if let error = ContainerStore.shared.error { throw LocalToolBridge.BridgeError(message: error) }; return ["stopped": item.id]
            case "windows_list": return ["windows": WindowPinController.shared.pinnedWindows.map { ["id": $0.id.uuidString, "application": $0.application, "title": $0.title] }]
            case "window_unpin": guard let text = params["id"] as? String, let id = UUID(uuidString: text) else { throw LocalToolBridge.BridgeError(message: "Ungültige Fenster-ID.") }; WindowPinController.shared.unpin(id: id); return ["unpinned": text]
            case "disk_status": return ["scanning": DiskScanStore.shared.isScanning, "inventoryLoaded":DiskScanStore.shared.result != nil,"indexedFiles":DiskScanStore.shared.summary?.fileCount as Any? ?? NSNull(), "volumes": (SystemMonitor.shared.reading?.volumes ?? []).map { ["name": $0.name, "totalBytes": $0.total, "freeBytes": $0.free] }]
            default: throw LocalToolBridge.BridgeError(message: "Nicht unterstützte MacTools-Aktion.")
            }
        }
    }
}
