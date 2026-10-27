/* MacTools offline rich chat renderer. User content is data, never executable HTML. */
(() => {
  const content = document.getElementById('content');
  let lastPayload, generation = 0, vegaResult, activeFrame;
  const decode = value => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(value), c => c.charCodeAt(0))));
  const reportSize = () => window.webkit?.messageHandlers?.size?.postMessage(Math.ceil(content.getBoundingClientRect().height));
  new ResizeObserver(reportSize).observe(content);
  document.fonts.ready.then(reportSize);
  window.addEventListener('message', event => {
    if (activeFrame && event.source === activeFrame.contentWindow && event.data?.type === 'visualization-size' && Number.isFinite(event.data.height)) {
      activeFrame.style.height = Math.min(1200, Math.max(120, event.data.height)) + 'px';
    }
  });
  const escapeHTML = value => value.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const mathHTML = (text, displayMode) => katex.renderToString(text, {
    displayMode, throwOnError: false, trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 30, output: 'htmlAndMathml'
  });
  if (window.marked) {
    function mathToken(src, block) {
      const patterns = block
        ? [/^\$\$([\s\S]+?)\$\$(?:[ \t]*\n|$)/, /^\\\[([\s\S]+?)\\\](?:[ \t]*\n|$)/]
        : [/^\\\(([\s\S]+?)\\\)/, /^\\\[([\s\S]+?)\\\]/, /^\$\$([\s\S]+?)\$\$/, /^\$(?![\s$])((?:\\[^\n]|[^$\n\\])+?)\$(?!\d)/];
      for (const pattern of patterns) {
        const m = pattern.exec(src);
        if (!m || (m[0][0] === '$' && m[0][1] !== '$' && /\s$/.test(m[1]))) continue;
        return {type: block ? 'mathBlock' : 'mathInline', raw: m[0], text: m[1], display: block || m[0].startsWith('$$') || m[0].startsWith('\\[')};
      }
    }
    marked.use({renderer: {html: token => escapeHTML(token.text)}, extensions: [
      {name: 'mathBlock', level: 'block', start: src => src.search(/(?:^|\n)(?:\$\$|\\\[)/), tokenizer(src) { return mathToken(src, true); }, renderer: token => mathHTML(token.text, true)},
      {name: 'mathInline', level: 'inline', start: src => src.search(/\\[([]|\$/), tokenizer(src) { return mathToken(src, false); }, renderer: token => mathHTML(token.text, token.display)}
    ]});
  }
  function showError(error, source) {
    const box = document.createElement('div'); box.className = 'render-error'; box.setAttribute('role', 'status');
    const label = document.createElement('p'); label.textContent = 'Darstellung nicht möglich: ' + error.message;
    const details = document.createElement('details'), summary = document.createElement('summary'), pre = document.createElement('pre');
    summary.textContent = 'Quelldaten anzeigen'; pre.textContent = source; details.append(summary, pre); box.append(label, details); content.replaceChildren(box);
  }
  function theme() {
    const dark = matchMedia('(prefers-color-scheme:dark)').matches;
    return {dark, foreground: dark ? '#eeeeee' : '#242424', grid: dark ? '#555555' : '#dddddd'};
  }
  async function render(payload) {
    if (payload === lastPayload) return;
    lastPayload = payload;
    const current = ++generation;
    let source = '';
    try {
      const values = decode(payload); source = values[0]; const kind = values[1];
      if (vegaResult) { vegaResult.finalize(); vegaResult = undefined; }
      if (window.Plotly && content.firstChild?.classList?.contains('js-plotly-plot')) Plotly.purge(content.firstChild);
      activeFrame = undefined; content.replaceChildren();
      if (kind === 'markdown') {
        // Sanitize after Markdown/TeX parsing so raw HTML, event handlers and unsafe links never enter the page.
        content.innerHTML = DOMPurify.sanitize(marked.parse(source, {gfm: true, breaks: true}), {FORBID_TAGS: ['style', 'form', 'input', 'button', 'iframe', 'object', 'embed']});
      } else if (kind === 'math') {
        content.innerHTML = mathHTML(source, true);
      } else if (kind === 'visualization') {
        const frame = document.createElement('iframe');
        frame.title = 'Interaktive Visualisierung'; frame.sandbox = 'allow-scripts'; frame.referrerPolicy = 'no-referrer';
        frame.style.cssText = 'display:block;width:100%;height:420px;border:0';
        // An opaque sandbox origin isolates fragment scripts from the host and its native bridge.
        const policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com https://esm.sh https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline' https://fonts.googleapis.com https://fonts.bunny.net https://cdn.jsdelivr.net; img-src data: blob:; font-src data: https://fonts.gstatic.com https://fonts.bunny.net https://cdn.jsdelivr.net; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
        const styles = document.getElementById('visualization-styles')?.textContent || '';
        const bridge = "window.openai={widgetState:null,setWidgetState:async function(value){this.widgetState=value}};new ResizeObserver(()=>parent.postMessage({type:'visualization-size',height:document.body.scrollHeight},'*')).observe(document.body);";
        frame.srcdoc = '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="' + policy + '"><style>' + styles + '</style></head><body><script>' + bridge + '</script>' + source + '</body></html>';
        activeFrame = frame; content.append(frame);
      } else {
        const spec = JSON.parse(source), colors = theme();
        if (!spec || typeof spec !== 'object' || Array.isArray(spec)) throw new Error('Diagrammdaten müssen ein JSON-Objekt sein.');
        const graph = document.createElement('div'); graph.className = 'chart'; graph.setAttribute('aria-label', 'Interaktives Diagramm'); content.append(graph);
        if (kind === 'plotly') {
          if (!Array.isArray(spec.data)) throw new Error('Plotly benötigt ein data-Array.');
          const layout = {...spec.layout, autosize: true, paper_bgcolor: 'transparent', plot_bgcolor: 'transparent', font: {color: colors.foreground, ...spec.layout?.font}};
          delete layout.width; delete layout.height;
          layout.xaxis = {gridcolor: colors.grid, ...layout.xaxis}; layout.yaxis = {gridcolor: colors.grid, ...layout.yaxis};
          await Plotly.newPlot(graph, spec.data, layout, {responsive: true, displaylogo: false, displayModeBar: true, showSendToCloud: false, scrollZoom: false, modeBarButtonsToRemove: ['sendDataToCloud', 'sendChartToCloud', 'toImage']});
          if (current !== generation) return;
          if (Array.isArray(spec.frames)) await Plotly.addFrames(graph, spec.frames);
        } else if (kind === 'vega') {
          // Embed options in usermeta must not override the offline loader or open external editors.
          if (spec.usermeta) delete spec.usermeta.embedOptions;
          const result = await vegaEmbed(graph, spec, {mode: spec.$schema?.includes('/vega/') ? 'vega' : 'vega-lite', actions: false, renderer: 'svg', theme: colors.dark ? 'dark' : undefined,
            loader: {load: async () => { throw new Error('Externe Daten sind gesperrt; data.values verwenden.'); }, sanitize: async () => { throw new Error('Externe Ressourcen sind gesperrt.'); }}});
          if (current !== generation) { result.finalize(); return; }
          vegaResult = result;
        } else throw new Error('Unbekanntes Diagrammformat.');
      }
      content.dataset.ready = 'true';
    } catch (error) { if (current === generation) showError(error, source); }
    reportSize();
  }
  window.renderPayload = render;
  matchMedia('(prefers-color-scheme:dark)').addEventListener('change', () => { const payload = lastPayload; lastPayload = undefined; if (payload) render(payload); });
  window.addEventListener('resize', () => { const graph = content.querySelector('.js-plotly-plot'); if (graph) Plotly.Plots.resize(graph); reportSize(); });
})();
