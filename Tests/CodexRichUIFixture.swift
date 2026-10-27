import AppKit
import SwiftUI

/// Run only from a separate QA app bundle; never sends a real Codex turn.
@main struct CodexRichUIFixture {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTOOLS_QA_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let defaults = UserDefaults(suiteName: "MacTools.rich-ui-fixture")!
        let store = CodexStore(connection: CodexConnection(executableURL: root.appendingPathComponent("Tests/Fixtures/codex-app-server.py"), environment:["MACTOOLS_QA_RICH_SCROLL":"1"]), defaults: defaults, followAllChats: false)
        let text = #"""
        Durch Transponieren entsteht:
        \[
        C^\top=\begin{pmatrix}1&0\\1&1\\0&1\end{pmatrix},\quad
        C^\top\begin{pmatrix}z_1\\z_2\end{pmatrix}=\begin{pmatrix}z_1\\z_1+z_2\\z_2\end{pmatrix}
        \]
        Jetzt werden **2 Eingaben zu 3 Ausgaben**. Für \(z=[1,2]\) ergibt sich \((1,3,2)\).

        ```plotly
        {"data":[{"x":[0,1,2,3],"y":[0,1,4,9],"mode":"lines+markers","name":"Quadrat"},{"x":[0,1,2,3],"y":[0,1,2,3],"name":"Linear"}],"layout":{"title":{"text":"Interaktiver Plot"},"showlegend":true}}
        ```
        """#
        let content = UsageQAContent(store: store, text: text, root: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 670), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacTools · Chat und Statistik prüfen"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content.frame(width: 740, height: 670))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run()
        store.stop()
    }
}

private struct UsageQAContent: View {
    let store: CodexStore
    let text: String
    let root: URL
    @State private var tab = 3
    var body: some View {
        VStack(spacing:0) {
        ScrollQAPopoverButton(store:store).frame(height:32)
        TabView(selection: $tab) {
            CodexChatsView(store:store,popupMode:true)
                .task { await store.connect(); await store.select("test-old") }
                .tabItem { Text("Fenster") }.tag(3)
            CodexMenuStatsView(store: store, openChats: { tab = 2 }, openSettings: {}, openLimits: { tab = 1 })
                .tabItem { Text("Popup") }.tag(0)
            CodexUsageView(store: store).tabItem { Text("Monate") }.tag(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Chat-Darstellung").font(.headline)
                    CodexMessageBody(text: text)
                    CodexMessageBody(text: "visualize{\"path\":\"" + root.appendingPathComponent("build/chat-rendering/native-fragment.html").path + "\"}")
                }.padding(20)
            }.tabItem { Text("Chat") }.tag(2)
        }
        }
    }
}

private struct ScrollQAPopoverButton: NSViewRepresentable {
    let store: CodexStore
    func makeNSView(context: Context) -> Button { Button(store:store) }
    func updateNSView(_ view: Button, context: Context) {}
    final class Button: NSButton {
        let popover = NSPopover()
        init(store:CodexStore) {
            super.init(frame:.zero)
            title = "Menü-Popup prüfen"; bezelStyle = .rounded; target = self; action = #selector(showPopover)
            popover.behavior = .transient
            popover.contentSize = NSSize(width:560,height:560)
            popover.contentViewController = CodexPinnedChatMenu.contentController(store:store,size:popover.contentSize)
        }
        required init?(coder:NSCoder) { nil }
        @objc private func showPopover() { popover.show(relativeTo:bounds,of:self,preferredEdge:.maxY) }
    }
}
