import AppKit
import SwiftUI

/// Run only from a separate QA app bundle; never sends a real Codex turn.
@main struct CodexRichUIFixture {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTOOLS_QA_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let defaults = UserDefaults(suiteName: "MacTools.rich-ui-fixture")!
        let store = CodexStore(connection: CodexConnection(executableURL: root.appendingPathComponent("Tests/Fixtures/codex-app-server.py")), defaults: defaults, followAllChats: false)
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
        let content = HStack(alignment: .top, spacing: 0) {
            CodexMenuStatsView(store: store, openChats: {}, openSettings: {})
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Chat-Darstellung").font(.headline)
                    CodexMessageBody(text: text)
                    CodexMessageBody(text: "visualize{\"path\":\"" + root.appendingPathComponent("build/chat-rendering/native-fragment.html").path + "\"}")
                }.padding(20)
            }.frame(width: 680)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1070, height: 880), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacTools · Chat und Statistik prüfen"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content.frame(width: 1070, height: 880))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run()
        store.stop()
    }
}
