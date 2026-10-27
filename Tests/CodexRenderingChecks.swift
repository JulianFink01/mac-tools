import AppKit
import WebKit

@main struct CodexRenderingChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("PASS: all rich chat rendering checks"); app.terminate(nil) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    struct Failure: Error, CustomStringConvertible { var description: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func js(_ web: WKWebView, _ code: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(code) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
    @MainActor static func wait(_ web: WKWebView, _ expression: String) async throws {
        for _ in 0..<400 {
            if (try? await js(web, expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Failure(description: "WebKit timeout: \(expression)")
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("Vendor/ChatRenderer")
        let output = root.appendingPathComponent("build/chat-rendering")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let parsed = CodexContentBlock.parse("Intro\n~~~~plotly\n{\"data\":[]}\n~~~\n~~~~\nEnde\n````swift\nlet x = \"```\"\n````")
        try require(parsed.count == 4 && parsed[1].richKind == .plotly && parsed[1].source.hasSuffix("~~~") && parsed[3].source.contains("```"), "Long and tilde fences must remain intact")
        let partial = CodexContentBlock.parse("```plotly\n{\"data\": [")
        try require(partial.count == 1 && !partial[0].complete && partial[0].richKind == nil, "Streaming JSON must stay readable until its fence closes")
        try require(CodexContentBlock.parse("Text with ```inline``` ticks").count == 1, "Inline backticks must not split a message")
        let reference = CodexContentBlock.parse(#"Vorher visualize{"path":"/tmp/chart.html","title":"Chart"} Nachher"#)
        try require(reference.count == 3 && reference[1].language == "visualization-reference" && reference[1].source == "/tmp/chart.html", "Native Codex visualization references must resolve in the message body")
        try require(CodexRichDocument.containsMath(#"\[x\]"#) && CodexRichDocument.containsMath("$x$") && !CodexRichDocument.containsMath(#"Preis \$5 und \$10"#), "Math routing")
        print("PASS: fenced payload parsing, streaming fallback and math routing")
        let math = #"""
        Durch Transponieren entsteht:
        \[
        C^\top=\begin{pmatrix}1&0\\1&1\\0&1\end{pmatrix},\qquad
        C^\top\begin{pmatrix}z_1\\z_2\end{pmatrix}=\begin{pmatrix}z_1\\z_1+z_2\\z_2\end{pmatrix}
        \]
        Jetzt werden **2 Eingaben zu 3 Ausgaben**. Inline: \(z=[1,2]\), $x^2$, $$\frac{a}{b}$$.

        | Größe | Formel |
        | --- | --- |
        | Norm | $\sqrt{x^2+y^2}$ |

        `\(literal\)` und `$$code$$` bleiben Code. Preise: \$5 und \$10.
        <img src="https://example.invalid/secret" onerror="window.injected=true">
        <script>window.injected=true</script>
        """#
        let plot = #"{"data":[{"x":[0,1,2,3],"y":[0,1,4,9],"mode":"lines+markers","name":"Quadrat"},{"x":[0,1,2,3],"y":[0,1,2,3],"name":"Linear"}],"layout":{"title":{"text":"Interaktiver Plot"},"showlegend":true}}"#
        let vega = #"{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","width":"container","height":260,"params":[{"name":"minimum","value":0,"bind":{"input":"range","min":0,"max":10,"step":1,"name":"Minimum "}}],"data":{"values":[{"x":"A","y":2},{"x":"B","y":5},{"x":"C","y":9}]},"transform":[{"filter":"datum.y >= minimum"}],"mark":{"type":"bar","tooltip":true},"encoding":{"x":{"field":"x","type":"nominal"},"y":{"field":"y","type":"quantitative"}}}"#
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let coordinator = CodexRichWebView.Coordinator(CodexRichWebView(source: "", kind: .markdown, height: .constant(80)))
        config.userContentController.add(coordinator, name: "size")
        let web = WKWebView(frame: NSRect(x:0,y:0,width:800,height:720), configuration: config)
        web.navigationDelegate = coordinator
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "MacTools · Rendering-Prüfung"; window.contentView = web; window.makeKeyAndOrderFront(nil)
        func document(_ source: String, _ kind: CodexRichKind, _ name: String) throws -> String {
            coordinator.parent = CodexRichWebView(source: source, kind: kind, height: .constant(80))
            let html = CodexRichDocument.html(source: source, kind: kind, resources: resources)
            try html.write(to: output.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
            return html
        }
        web.loadHTMLString(try document(math, .markdown, "math"), baseURL: nil)
        try await wait(web, "document.querySelectorAll('.katex').length === 5 && document.fonts.status === 'loaded'")
        try require(try await js(web, "document.querySelectorAll('.katex-error').length === 0 && document.querySelectorAll('.mtable').length === 3") as? Bool == true, "Matrix must render with all rows and no KaTeX errors")
        try require(try await js(web, "document.querySelector('.vlist[style]').style.height !== ''") as? Bool == true, "KaTeX layout styles must survive sanitization")
        try require(try await js(web, "!window.injected && !document.querySelector('img') && document.querySelectorAll('code').length === 2 && document.querySelectorAll('table').length === 1 && document.body.innerText.includes('$5 und $10')") as? Bool == true, "Code, currency, table and HTML isolation")
        try require(try await js(web, "[...document.fonts].filter(f => f.status === 'loaded').length > 0") as? Bool == true, "Local KaTeX fonts must load")
        print("PASS: screenshot matrix, inline/display math, tables, literal code/currency, local fonts and HTML isolation in real WebKit")
        let incomplete = (try JSONSerialization.data(withJSONObject: [#"\[\frac{1}{"#, "markdown"])).base64EncodedString()
        _ = try await js(web, "renderPayload('\(incomplete)'); true")
        let completed = (try JSONSerialization.data(withJSONObject: [#"\[\frac{1}{2}\]"#, "markdown"])).base64EncodedString()
        _ = try await js(web, "renderPayload('\(completed)'); true")
        try await wait(web, "document.querySelectorAll('.katex').length === 1 && !document.querySelector('.katex-error')")
        print("PASS: incomplete streamed math recovers without reloading the page")
        web.loadHTMLString(try document(plot, .plotly, "plotly"), baseURL: nil)
        try await wait(web, "!!document.querySelector('.js-plotly-plot')?._fullLayout && document.querySelectorAll('.scatterlayer .trace').length === 2")
        _ = try await js(web, "Plotly.Fx.hover(document.querySelector('.js-plotly-plot'), [{curveNumber:0,pointNumber:2}]); true")
        try require(try await js(web, "document.querySelector('.hoverlayer').textContent.includes('4')") as? Bool == true, "Plot tooltip must show the real point value")
        _ = try await js(web, "document.querySelector('.legendtoggle').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,clientX:700,clientY:110})); document.querySelector('.legendtoggle').dispatchEvent(new MouseEvent('mouseup',{bubbles:true,clientX:700,clientY:110})); true")
        try await Task.sleep(nanoseconds: 600_000_000)
        try require(try await js(web, "document.querySelector('.js-plotly-plot').data[0].visible === 'legendonly'") as? Bool == true, "Plot legend must toggle the trace")
        _ = try await js(web, "document.querySelector('[data-attr=zoom][data-val=in]')?.click(); true")
        try require(try await js(web, "document.querySelector('.js-plotly-plot')._fullLayout.xaxis.range[1] < 3") as? Bool == true, "Plot toolbar zoom must change the axis range")
        web.setFrameSize(NSSize(width: 460, height: 720))
        _ = try await js(web, "window.dispatchEvent(new Event('resize')); true")
        try await wait(web, "document.querySelector('.js-plotly-plot')._fullLayout.width <= 460")
        print("PASS: Plotly tooltip, legend/zoom handlers and responsive width in WebKit")
        web.loadHTMLString(try document(vega, .vega, "vega-lite"), baseURL: nil)
        try await wait(web, "document.querySelectorAll('.mark-rect.role-mark path').length === 3 && !!document.querySelector('input[type=range]')")
        _ = try await js(web, "const slider=document.querySelector('input[type=range]'); slider.value='6'; slider.dispatchEvent(new Event('input',{bubbles:true})); true")
        try await wait(web, "document.querySelectorAll('.mark-rect.role-mark path').length === 1")
        print("PASS: Vega-Lite slider interaction filters the actual plotted data")
        let bad = #"{"data":"broken"}"#
        web.loadHTMLString(try document(bad, .plotly, "invalid-chart"), baseURL: nil)
        try await wait(web, "!!document.querySelector('.render-error')")
        try require(try await js(web, #"document.querySelector('pre').textContent === '{"data":"broken"}'"#) as? Bool == true, "Invalid charts must retain source data")
        print("PASS: malformed chart reports a readable error with original source")
        let fragment = #"""
        <label>Faktor <input aria-label="Faktor" type="range" min="1" max="10" value="2"></label><output>4</output>
        <script>
        const slider=document.querySelector('input'), result=document.querySelector('output');
        let isolated=false; try{parent.document.body.innerHTML='unsafe'}catch(e){isolated=true}
        slider.oninput=()=>{result.value=slider.value*slider.value;parent.postMessage({type:'test-result',value:result.value,isolated},'*')};
        window.onmessage=e=>{slider.value=e.data.value;slider.dispatchEvent(new Event('input',{bubbles:true}))};
        </script>
        """#
        let local = output.appendingPathComponent("native-fragment.html")
        try fragment.write(to: local, atomically: true, encoding: .utf8)
        try require(CodexVisualizationReference.read(local.path) == fragment && CodexVisualizationReference.read("/tmp/secret.txt") == nil && CodexVisualizationReference.read("https://example.com/chart.html") == nil, "Only bounded local HTML files may be loaded")
        web.loadHTMLString(try document(fragment, .visualization, "visualization"), baseURL: nil)
        try await wait(web, "!!document.querySelector('iframe')?.contentWindow")
        _ = try await js(web, "window.addEventListener('message',e=>{if(e.data?.type==='test-result')window.testResult=e.data}); true")
        // Wait for the sandboxed document to initialize before requesting its interaction.
        for _ in 0..<100 {
            _ = try await js(web, "document.querySelector('iframe').contentWindow.postMessage({value:7},'*'); true")
            if (try? await js(web, "window.testResult?.value === '49' && window.testResult?.isolated === true")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(try await js(web, "window.testResult?.value === '49' && window.testResult?.isolated === true") as? Bool == true, "Visualization scripts must interact within an isolated iframe")
        print("PASS: native visualization file readback, live interaction and opaque iframe isolation")
        window.close()
    }
}
