import SwiftUI
import WebKit

/// Keep one native scroll view in charge for the entire trackpad gesture,
/// including zero-delta phase boundaries and the subsequent momentum stream.
struct CodexWheelRouting {
    enum Route { case native, primeOuter, outer }
    private(set) var isForwarding = false
    private var decided = false
    private var primed = false
    func needsHitTest(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        !precise || (phase.isEmpty && momentum.isEmpty) || phase.contains(.began) || phase.contains(.mayBegin) || !decided
    }
    mutating func route(x: CGFloat, y: CGFloat, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, overWeb: Bool, modified: Bool) -> Route {
        if !precise || (phase.isEmpty && momentum.isEmpty) {
            return !modified && overWeb && abs(y) > abs(x) ? .outer : .native
        }
        if phase.contains(.began) || phase.contains(.mayBegin) { isForwarding = false; decided = false; primed = false }
        if modified { isForwarding = false; decided = true; return .native }
        if !decided, x != 0 || y != 0 { decided = true; isForwarding = overWeb && abs(y) > abs(x) }
        let terminal = phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled)
        if isForwarding {
            if terminal { isForwarding = false; decided = false; primed = false }
            return .outer
        }
        // A zero-delta begin carries no direction yet. Prime AppKit while also
        // leaving that boundary available to WebKit for a horizontal gesture.
        if !decided, overWeb, phase.contains(.began) { primed = true; return .primeOuter }
        if primed, phase.contains(.ended) || phase.contains(.cancelled) { primed = false; return .primeOuter }
        return .native
    }
}

/// Keep fenced payloads opaque: Markdown must never consume TeX row separators or chart JSON.
struct CodexContentBlock: Equatable {
    var language: String? = nil
    var source: String
    var complete = true
    static func parse(_ text: String) -> [Self] {
        let lines = text.components(separatedBy: "\n")
        var result: [Self] = [], plain: [String] = [], code: [String] = []
        var fence: Character?, length = 0, language = ""
        func flush() {
            guard !plain.isEmpty else { return }
            let value = plain.joined(separator: "\n")
            let pattern = #"visualize(\{[^\n]*?\})"#
            let regex = try? NSRegularExpression(pattern: pattern)
            var cursor = value.startIndex
            for match in regex?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? [] {
                guard let range = Range(match.range, in: value), let jsonRange = Range(match.range(at: 1), in: value),
                      let data = String(value[jsonRange]).data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let path = object["path"] as? String else { continue }
                if cursor < range.lowerBound { result.append(Self(source: String(value[cursor..<range.lowerBound]))) }
                result.append(Self(language: "visualization-reference", source: path)); cursor = range.upperBound
            }
            if cursor < value.endIndex { result.append(Self(source: String(value[cursor...]))) }
            plain = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let char = trimmed.first
            let count = trimmed.prefix { $0 == char }.count
            if let open = fence {
                if char == open, count >= length, trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(Self(language: language, source: code.joined(separator: "\n"))); code = []; fence = nil
                } else { code.append(line) }
            } else if (char == "`" || char == "~"), count >= 3, line.prefix(while: { $0 == " " }).count <= 3,
                      !(char == "`" && trimmed.dropFirst(count).contains("`")) {
                flush(); fence = char; length = count
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces).lowercased()
            } else { plain.append(line) }
        }
        if fence != nil { result.append(Self(language: language, source: code.joined(separator: "\n"), complete: false)) }
        flush(); return result
    }
    var richKind: CodexRichKind? {
        guard complete else { return nil }
        switch language {
        case "math", "latex", "tex": return .math
        case "plotly", "plotly-json", "application/vnd.plotly.v1+json": return .plotly
        case "vega", "vega-lite", "vegalite": return .vega
        case "visualization", "interactive-html": return .visualization
        default: return nil
        }
    }
}

enum CodexRichKind: String { case markdown, math, plotly, vega, visualization }

struct CodexVisualizationReference: View {
    let path: String
    @State private var source: String?
    @State private var failed = false
    var body: some View {
        Group {
            if let source { CodexRichContent(source: source, kind: .visualization) }
            else if failed { Label("Visualisierung nicht mehr verfügbar: \(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "chart.bar.xaxis").foregroundStyle(.secondary).textSelection(.enabled) }
            else { ProgressView().controlSize(.small) }
        }.task(id: path) {
            source = nil; failed = false
            let path = path
            source = await Task.detached(priority: .utility) { Self.read(path) }.value
            failed = source == nil
        }
    }
    nonisolated static func read(_ path: String) -> String? {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "html" else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct CodexRichContent: View {
    let source: String
    var kind: CodexRichKind = .markdown
    @State private var height: CGFloat = 80
    private var chart: Bool { kind == .plotly || kind == .vega || kind == .visualization }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chart {
                HStack {
                    Label("Interaktives Diagramm", systemImage: "chart.xyaxis.line").foregroundStyle(.secondary)
                    Spacer()
                    Button("Vergrößern") { CodexChartWindow.show(source: source, kind: kind) }.buttonStyle(.plain)
                }.font(.caption).padding(12)
            }
            CodexRichWebView(source: source, kind: kind, height: $height)
                .frame(height: chart ? max(420, height) : height).frame(maxWidth: .infinity)
        }.background(chart ? Color.primary.opacity(0.025) : .clear)
    }
}

@MainActor private final class CodexChartWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [CodexChartWindow] = []
    static func show(source: String, kind: CodexRichKind) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex · Interaktives Diagramm"; window.minSize = NSSize(width: 480, height: 360); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CodexRichWebView(source: source, kind: kind, height: .constant(700), expanded: true))
        window.setContentSize(NSSize(width: 1100, height: 760))
        let controller = CodexChartWindow(window: window); window.delegate = controller; windows.append(controller)
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        Self.windows.removeAll { $0 === self }
    }
}

struct CodexRichWebView: NSViewRepresentable {
    let source: String
    let kind: CodexRichKind
    @Binding var height: CGFloat
    var expanded = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator; web.setValue(false, forKey: "drawsBackground")
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.source != source || context.coordinator.kind != kind else { return }
        let changedKind = context.coordinator.kind != kind
        context.coordinator.source = source; context.coordinator.kind = kind
        if changedKind { context.coordinator.loaded = false; context.coordinator.loading = false }
        // Reuse the page while streaming; do not recreate WebKit or reload its libraries per delta.
        if context.coordinator.loaded {
            let data = try? JSONSerialization.data(withJSONObject: [source, kind.rawValue])
            let payload = data?.base64EncodedString() ?? "W10="
            web.evaluateJavaScript("window.renderPayload('\(payload)')", completionHandler: nil)
        } else if !context.coordinator.loading {
            context.coordinator.loading = true
            web.loadHTMLString(CodexRichDocument.html(source: source, kind: kind, expanded: expanded), baseURL: nil)
        }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "size"); web.stopLoading(); web.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CodexRichWebView
        var source: String?, kind: CodexRichKind?
        var loaded = false, loading = false
        init(_ parent: CodexRichWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true; loading = false
            let data = try? JSONSerialization.data(withJSONObject: [parent.source, parent.kind.rawValue])
            webView.evaluateJavaScript("window.renderPayload('\(data?.base64EncodedString() ?? "W10=")')", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber, number.doubleValue.isFinite else { return }
            let value = min(12000, max(30, CGFloat(number.doubleValue)))
            if abs(parent.height - value) > 1 { parent.height = value }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            let url = action.request.url?.absoluteString
            let localDocument = action.navigationType == .other && url == "about:blank"
            let visualizationFrame = parent.kind == .visualization && action.targetFrame?.isMainFrame == false && url == "about:srcdoc"
            decisionHandler(localDocument || visualizationFrame ? .allow : .cancel)
        }
    }
}

/// HTML is also used by the rendering checks, so tests exercise the exact shipped document.
enum CodexRichDocument {
    static func containsMath(_ source: String) -> Bool {
        source.contains("\\[") || source.contains("\\(") || source.contains("$$") || source.range(of: #"(?<![\\$])\$[^\s$][^\n$]*?[^\s\\$]\$(?!\d)|(?<![\\$])\$[^\s$]\$(?!\d)"#, options: .regularExpression) != nil
    }
    static var resourceDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("ChatRenderer", isDirectory: true) }
    static func html(source: String, kind: CodexRichKind, expanded: Bool = false, resources: URL? = resourceDirectory) -> String {
        func read(_ name: String) -> String { resources.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) } ?? "" }
        func script(_ name: String) -> String { "<script>" + read(name).replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) + "</script>" }
        // Inline only WOFF2: no file access permission and no network font dependency.
        var css = read("katex.min.css")
        if let resources, let regex = try? NSRegularExpression(pattern: #"url\(fonts/([^\)]+)\)"#) {
            for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
                guard let range = Range(match.range, in: css), let name = Range(match.range(at: 1), in: css) else { continue }
                let path = resources.appendingPathComponent("fonts/" + css[name])
                let replacement = path.pathExtension == "woff2" ? (try? Data(contentsOf: path)).map { "url(data:font/woff2;base64,\($0.base64EncodedString()))" } ?? "url()" : "url()"
                css.replaceSubrange(range, with: replacement)
            }
        }
        let libraries: String
        switch kind {
        case .markdown, .math: libraries = script("marked.js") + script("purify.min.js") + script("katex.min.js")
        case .plotly: libraries = script("plotly.min.js")
        case .vega: libraries = script("vega.min.js") + script("vega-lite.min.js") + script("vega-embed.min.js")
        case .visualization: libraries = ""
        }
        let cdn = kind == .visualization ? " https://cdnjs.cloudflare.com https://esm.sh https://cdn.jsdelivr.net https://unpkg.com https://fonts.googleapis.com https://fonts.gstatic.com https://fonts.bunny.net" : ""
        let payload = (try? JSONSerialization.data(withJSONObject: [source, kind.rawValue]))?.base64EncodedString() ?? "W10="
        return """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'\(cdn); style-src 'unsafe-inline'\(cdn); img-src data: blob:; font-src data:\(cdn); connect-src 'none'; frame-src \(kind == .visualization ? "about:" : "'none'"); object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(css)</style><style>
        :root{color-scheme:light dark;--fg:#242424;--muted:#666;--grid:#ddd}@media(prefers-color-scheme:dark){:root{--fg:#eee;--muted:#bbb;--grid:#555}}
        *{box-sizing:border-box}html,body{margin:0;padding:0;background:transparent;color:var(--fg);font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif}
        body{overflow:auto}#content{display:flow-root;overflow-wrap:anywhere;padding:2px 0}#content>:first-child{margin-top:0}#content>:last-child{margin-bottom:0}
        p{margin:0 0 12px}a{color:#39a777}pre{white-space:pre;overflow-x:auto;padding:12px;background:rgba(128,128,128,.08)}code{font:12px ui-monospace,monospace}blockquote{margin-left:0;padding-left:14px;border-left:3px solid var(--grid);color:var(--muted)}
        table{display:block;overflow-x:auto;border-collapse:collapse}th,td{padding:10px 16px;text-align:left;border-bottom:1px solid var(--grid)}
        .katex-display{overflow-x:auto;overflow-y:hidden;padding:5px 0;margin:12px 0}.katex{font-size:1.1em}.render-error{color:var(--muted);white-space:pre-wrap}.chart{width:100%;height:\(expanded ? "calc(100vh - 8px)" : "420px");min-height:320px}.vega-embed{max-width:100%}button,input,select{font:inherit}
        </style><style id="visualization-styles" media="not all">\(read("visualization.css"))</style></head><body><main id="content" aria-label="Chat-Inhalt"></main>\(libraries)\(script("renderer.js"))
        <script>window.renderPayload('\(payload)');</script></body></html>
        """
    }
}
