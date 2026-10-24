import AppKit
import SwiftUI
import WebKit

@MainActor private enum TerminalWebRuntime {
    static let pool = WKProcessPool()
    static let dataStore = WKWebsiteDataStore.nonPersistent()
}
@MainActor final class InfraTerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let executable: String
    let arguments: [String]
    @Published private(set) var status = "Verbindung wird vorbereitet …"
    @Published private(set) var running = false
    private var process: TerminalProcess?
    private var web: TerminalWebView?
    private var bridge: TerminalBridge?
    private var acknowledge: (@Sendable () -> Void)?
    private var started = false
    private var closed = false
    var terminalReady = false
    var isSelected = false
    init(title: String, executable: String = "/usr/bin/ssh", arguments: [String]) { self.title = title; self.executable = executable; self.arguments = arguments }
    func view() -> TerminalWebView {
        if let web { return web }
        let controller = WKUserContentController(), bridge = TerminalBridge(session: self)
        controller.add(bridge, name: "terminal")
        let config = WKWebViewConfiguration(); config.userContentController = controller
        config.websiteDataStore = TerminalWebRuntime.dataStore; config.processPool = TerminalWebRuntime.pool
        let view = TerminalWebView(frame: .zero, configuration: config)
        view.session = self
        view.navigationDelegate = bridge; view.uiDelegate = bridge
        web = view; self.bridge = bridge
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Terminal"), FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path) else { status = "Terminal-Ressourcen fehlen."; return view }
        view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        return view
    }
    func start(columns: UInt16, rows: UInt16) {
        guard !started, !closed else { return }; started = true; terminalReady = true
        do {
            process = try TerminalProcess(executable: executable, arguments: arguments, columns: columns, rows: rows, output: { [weak self] data, ack in
                Task { @MainActor in
                    guard let self, !self.closed, let web = self.web else { ack(); return }
                    self.acknowledge = ack
                    let encoded = data.base64EncodedString()
                    web.evaluateJavaScript("window.terminalReceive('\(encoded)')") { [weak self] _, error in if error != nil { self?.acknowledge?(); self?.acknowledge = nil } }
                }
            }, exit: { [weak self] code in Task { @MainActor in self?.running = false; self?.status = "Sitzung beendet · Exit \(code)" } })
            running = true; status = "SSH geöffnet · Anmeldung und Shell im Terminal"
            focus()
        } catch { status = "Start fehlgeschlagen: " + error.localizedDescription }
    }
    func receive(_ body: [String:Any]) {
        guard !closed, let type = body["type"] as? String else { return }
        switch type {
        case "ready": start(columns: dimension(body["columns"], fallback: 100), rows: dimension(body["rows"], fallback: 30))
        case "resize": process?.resize(columns: dimension(body["columns"], fallback: 100), rows: dimension(body["rows"], fallback: 30))
        case "input": if let value = body["data"] as? String, value.utf8.count <= 1_048_576 { process?.send(Data(value.utf8)) }
        case "binary": if let value = body["data"] as? String, value.count <= 1_398_104, let data = Data(base64Encoded: value) { process?.send(data) }
        case "ack": let callback = acknowledge; acknowledge = nil; callback?()
        default: break
        }
    }
    private func dimension(_ value: Any?, fallback: UInt16) -> UInt16 { UInt16(min(500, max(2, value as? Int ?? Int(fallback)))) }
    func focus() {
        guard isSelected, !closed, let web else { return }
        web.window?.makeFirstResponder(web)
        web.evaluateJavaScript("window.terminalFocus()", completionHandler: nil)
    }
    func close() {
        guard !closed else { return }; closed = true
        acknowledge?(); acknowledge = nil; process?.stop(); process = nil
        web?.stopLoading(); web?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.removeFromSuperview(); web = nil; bridge = nil
        running = false; status = "Getrennt"
    }
}

@MainActor final class TerminalBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var session: InfraTerminalSession?
    init(session: InfraTerminalSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true, let body = message.body as? [String:Any] else { return }
        session?.receive(body)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

@MainActor final class TerminalWebView: WKWebView {
    weak var session: InfraTerminalSession?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard session?.isSelected == true else { return false }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers == "c" {
            evaluateJavaScript("window.terminalSelection()") { value, _ in if let text = value as? String, !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }
            return true
        }
        if event.charactersIgnoringModifiers == "v", let text = NSPasteboard.general.string(forType: .string),
           let encoded = try? JSONEncoder().encode(text), let json = String(data: encoded, encoding: .utf8) {
            evaluateJavaScript("window.terminalPaste(\(json))", completionHandler: nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class InfraTerminalStore: ObservableObject {
    static let shared = InfraTerminalStore()
    @Published var sessions: [InfraTerminalSession] = []
    @Published var selectedID: UUID?
    @Published var destination: String { didSet { defaults.set(destination, forKey: "infraSSHHost") } }
    @Published var identityFile: String { didSet { defaults.set(identityFile, forKey: "infraSSHIdentity") } }
    private let defaults: UserDefaults
    private var counter = 0
    let permitted: Bool
    var makeSession: @MainActor (SSHConnectionSettings, Int) -> InfraTerminalSession
    init(defaults: UserDefaults = .standard, configuration: [String:String] = PrivateMCPAccess.configuration, permitted: Bool = PrivateMCPAccess.enabled,
         makeSession: @escaping @MainActor (SSHConnectionSettings,Int) -> InfraTerminalSession = { settings, n in InfraTerminalSession(title: "SSH \(n)", arguments: settings.arguments) }) {
        self.defaults = defaults; self.permitted = permitted; self.makeSession = makeSession
        destination = defaults.string(forKey: "infraSSHHost") ?? configuration["sshDestination"] ?? ""
        identityFile = defaults.string(forKey: "infraSSHIdentity") ?? configuration["sshIdentityFile"] ?? ""
    }
    var settings: SSHConnectionSettings { SSHConnectionSettings(destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), identityFile: identityFile.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var selected: InfraTerminalSession? { sessions.first { $0.id == selectedID } }
    func add() {
        guard permitted, settings.valid else { return }
        counter += 1; let session = makeSession(settings, counter); sessions.append(session); selectedID = session.id
    }
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].close(); sessions.remove(at: index)
        if selectedID == id { selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id }
    }
    func stop() { sessions.forEach { $0.close() }; sessions = []; selectedID = nil }
}

private struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: InfraTerminalSession
    let selected: Bool
    final class Coordinator { var selected = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalWebView { session.view() }
    func updateNSView(_ view: TerminalWebView, context: Context) {
        session.isSelected = selected
        if selected && !context.coordinator.selected { DispatchQueue.main.async { session.focus() } }
        context.coordinator.selected = selected
    }
}
private struct TerminalSessionTab: View {
    @ObservedObject var session: InfraTerminalSession
    let selected: Bool
    let choose: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: choose) { HStack(spacing: 7) { Circle().fill(session.running ? Color.mint : .secondary).frame(width: 6, height: 6); Text(session.title).font(.callout.weight(.medium)) } }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Sitzung schließen").accessibilityLabel(session.title + " schließen")
        }.padding(.horizontal, 13).padding(.vertical, 10).background(selected ? Color.mint.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct InfraTerminalView: View {
    @ObservedObject var store: InfraTerminalStore = .shared
    @State private var showSettings = false
    @State private var closingID: UUID?
    @State private var confirmClose = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(store.destination.isEmpty ? "SSH-Verbindung" : store.destination, systemImage: "terminal").font(.headline)
                Spacer()
                Button { showSettings.toggle() } label: { Label("Verbindung", systemImage: "slider.horizontal.3") }
                Button { store.add() } label: { Label("Neuer Tab", systemImage: "plus") }.disabled(!store.settings.valid).keyboardShortcut("t", modifiers: .command)
            }
            if showSettings || !store.settings.valid {
                HStack {
                    TextField("SSH-Alias oder benutzer@server", text: $store.destination).textFieldStyle(.roundedBorder).accessibilityLabel("SSH-Ziel")
                    TextField("Schlüsselpfad optional · ~/.ssh/…", text: $store.identityFile).textFieldStyle(.roundedBorder).accessibilityLabel("SSH-Schlüsselpfad")
                }
                Text("Lokales OpenSSH verwendet deine SSH-Konfiguration, den SSH-Agent und bekannte Hostschlüssel. Passwörter und Passphrasen werden ausschließlich interaktiv im Terminal eingegeben.").font(.caption).foregroundStyle(.secondary)
            }
            if !store.sessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) { ForEach(store.sessions) { session in TerminalSessionTab(session: session, selected: store.selectedID == session.id, choose: { store.selectedID = session.id }, close: { if session.running { closingID = session.id; confirmClose = true } else { store.close(session.id) } }) } }
                }
                ZStack { ForEach(store.sessions) { session in TerminalSurface(session: session, selected: store.selectedID == session.id).opacity(store.selectedID == session.id ? 1 : 0).allowsHitTesting(store.selectedID == session.id).accessibilityHidden(store.selectedID != session.id) } }
                    .clipShape(RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected = store.selected { TerminalSessionStatus(session: selected) }
            } else {
                VStack(spacing: 15) {
                    Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.mint)
                    Text("Direkt vom Mac auf deinen Server").font(.title2.weight(.semibold))
                    Text("Jeder Tab öffnet eine eigene SSH-Sitzung. Geöffnete Sitzungen bleiben beim Wechsel zur Übersicht bestehen.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    Text(store.settings.valid ? "Über Neuer Tab öffnest du eine weitere Sitzung." : "Trage oben dein SSH-Ziel ein.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24).onAppear { if store.sessions.isEmpty { store.add() } }.alert("SSH-Sitzung schließen?", isPresented: $confirmClose) {
            Button("Abbrechen", role: .cancel) { closingID = nil }
            Button("Sitzung schließen", role: .destructive) { if let closingID { store.close(closingID) }; closingID = nil }
        } message: { Text("Die Verbindung und laufende Programme dieser Sitzung werden beendet.") }
    }
}
private struct TerminalSessionStatus: View {
    @ObservedObject var session: InfraTerminalSession
    var body: some View { Text(session.status).font(.caption).foregroundStyle(.secondary) }
}
