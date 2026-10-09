import Foundation
import VibeCore

/// The HTML shell, stylesheet and helper script of the Markdown preview.
enum PreviewTemplate {
    static func page(baseURL: URL, theme: Theme, fontFamily: String, fontSize: Double, body: String = "", standalone: Bool = false) -> String {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <base href="\(SyntaxHighlighter.escapeHTML(base))">
        <style>\(stylesheet)</style>
        <style id="vibe-theme">\(themeCSS(theme: theme, fontFamily: fontFamily, fontSize: fontSize))</style>
        </head>
        <body class="\(standalone ? "ready" : "")">
        <article id="content" class="markdown-body">\(body)</article>
        </body>
        </html>
        """
    }

    static func themeCSS(theme: Theme, fontFamily: String, fontSize: Double) -> String {
        """
        :root { \(theme.cssVariables); --accent-soft: \(theme.accent.withAlpha(0.55).css); --font-family: \(fontFamily); --font-size: \(Int(fontSize))px; color-scheme: \(theme.isDark ? "dark" : "light"); }
        \(theme.tokenCSS)
        """
    }

    static let stylesheet = """
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--font-family); font-size: var(--font-size); line-height: 1.68; -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
    #content { max-width: 860px; margin: 0 auto; padding: 34px 48px 160px; }
    body.ready #content { animation: vibe-enter .42s cubic-bezier(.2,.8,.2,1); }
    @keyframes vibe-enter { from { transform: translateY(8px); } to { transform: none; } }
    #content > :first-child { margin-top: 0 !important; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.7em 0 .6em; font-weight: 700; letter-spacing: -0.012em; color: var(--heading); scroll-margin-top: 16px; }
    h1 { font-size: 2.15em; letter-spacing: -0.022em; padding-bottom: .28em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.55em; padding-bottom: .25em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.27em; }
    h4 { font-size: 1.07em; }
    h5 { font-size: .95em; }
    h6 { font-size: .9em; color: var(--muted); }
    p, ul, ol, dl, blockquote, pre, table, details, .markdown-alert { margin: 0 0 1.05em; }
    a { color: var(--link); text-decoration: none; text-underline-offset: 2px; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 650; }
    code, kbd, samp { font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace; }
    code { font-size: .86em; background: var(--code-bg); padding: .16em .42em; border-radius: 6px; }
    pre { background: var(--code-bg); padding: 15px 18px; border-radius: 12px; overflow: auto; line-height: 1.55; border: 1px solid var(--border); }
    pre code { background: none; padding: 0; font-size: .84em; border-radius: 0; white-space: pre; }
    blockquote { margin-left: 0; padding: .15em 1.1em; color: var(--quote); border-left: 4px solid var(--accent-soft); }
    blockquote > :last-child { margin-bottom: 0; }
    hr { border: 0; height: 1px; background: var(--border); margin: 2.2em 0; }
    table { border-collapse: separate; border-spacing: 0; display: block; overflow: auto; width: max-content; max-width: 100%; border: 1px solid var(--border); border-radius: 10px; }
    th, td { padding: 7px 14px; border-bottom: 1px solid var(--border); border-right: 1px solid var(--border); }
    th:last-child, td:last-child { border-right: 0; }
    tbody tr:last-child td { border-bottom: 0; }
    th { font-weight: 600; background: var(--code-bg); text-align: left; }
    tbody tr:nth-child(2n) td { background: color-mix(in srgb, var(--code-bg) 55%, transparent); }
    img { max-width: 100%; border-radius: 10px; }
    ul, ol { padding-left: 1.7em; }
    li + li, li > ul, li > ol { margin-top: .28em; }
    li > p { margin-bottom: .5em; }
    ul.contains-task-list { padding-left: .4em; }
    .task-list-item { list-style: none; }
    .task-list-item-checkbox { width: 1.02em; height: 1.02em; margin: 0 .55em 0 0; vertical-align: -0.14em; accent-color: var(--accent); cursor: pointer; }
    .task-list-item:has(> .task-list-item-checkbox:checked) { color: var(--muted); }
    .markdown-alert { padding: .65em 1.1em; border-left: 4px solid var(--alert); border-radius: 8px; background: color-mix(in srgb, var(--alert) 9%, transparent); }
    .markdown-alert > :last-child { margin-bottom: 0; }
    .markdown-alert-title { font-weight: 650; color: var(--alert); margin-bottom: .3em !important; }
    .markdown-alert-note { --alert: #4493F8; }
    .markdown-alert-tip { --alert: #3FB950; }
    .markdown-alert-important { --alert: #AB7DF8; }
    .markdown-alert-warning { --alert: #D29922; }
    .markdown-alert-caution { --alert: #F85149; }
    details { border: 1px solid var(--border); border-radius: 10px; padding: .55em 1em; }
    details[open] > summary { margin-bottom: .5em; }
    summary { cursor: pointer; font-weight: 600; }
    details.front-matter { color: var(--muted); }
    details.front-matter > summary { font-size: .78em; text-transform: uppercase; letter-spacing: .08em; }
    details.front-matter pre { margin: 0; border: 0; padding: 4px 0; background: transparent; }
    .footnotes { font-size: .9em; color: var(--muted); border-top: 1px solid var(--border); margin-top: 2.5em; padding-top: 1em; }
    sup.footnote-ref a { font-size: .8em; }
    kbd { font-size: .82em; padding: .12em .45em; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 6px; background: var(--code-bg); }
    mark { background: var(--mark); color: inherit; border-radius: 3px; padding: 0 .15em; }
    ::selection { background: var(--selection); }
    .vibe-flash { animation: vibe-flash 1.2s ease; }
    @keyframes vibe-flash { 0% { background: color-mix(in srgb, var(--accent) 25%, transparent); } 100% { background: transparent; } }
    @media print { #content { max-width: none; padding: 0; } }
    """

    /// Runs in an isolated content world; page scripts are disabled.
    static let script = """
    (() => {
      const post = (message) => { try { window.webkit.messageHandlers.vibe.postMessage(message); } catch (e) {} };
      let blocks = null;
      const vibe = {
        update(html) {
          const content = document.getElementById('content');
          content.innerHTML = html;
          blocks = null;
          if (!document.body.classList.contains('ready')) {
            // Force a style flush so the fade-in transition runs, without relying on
            // requestAnimationFrame (paused while the window is hidden).
            void content.offsetHeight;
            document.body.classList.add('ready');
          }
        },
        setTheme(css) {
          document.getElementById('vibe-theme').textContent = css;
        },
        scrollToLine(line, fraction, atEnd) {
          if (atEnd) { window.scrollTo(0, document.documentElement.scrollHeight); return; }
          if (!blocks) { blocks = Array.from(document.querySelectorAll('#content [data-line]')); }
          let previous = null, next = null;
          for (const element of blocks) {
            const value = Number(element.dataset.line);
            if (value <= line) { previous = element; } else { next = element; break; }
          }
          if (!previous) { window.scrollTo(0, 0); return; }
          const top = (element) => element.getBoundingClientRect().top + window.scrollY;
          const previousLine = Number(previous.dataset.line);
          let target = top(previous);
          if (next) {
            const span = Math.max(1, Number(next.dataset.line) - previousLine);
            const t = Math.min(1, (line + fraction - previousLine) / span);
            target += (top(next) - target) * t;
          } else {
            target += previous.getBoundingClientRect().height * fraction;
          }
          window.scrollTo(0, Math.max(0, target - 14));
        },
        scrollToAnchor(id) {
          const element = document.getElementById(id) || document.getElementsByName(id)[0];
          if (element) { element.scrollIntoView({ behavior: 'smooth', block: 'start' }); element.classList.add('vibe-flash'); setTimeout(() => element.classList.remove('vibe-flash'), 1300); }
        }
      };
      window.vibe = vibe;
      document.addEventListener('change', (event) => {
        const target = event.target;
        if (target && target.classList && target.classList.contains('task-list-item-checkbox')) {
          post({ type: 'toggleTask', line: Number(target.dataset.line), checked: target.checked });
        }
      });
      post({ type: 'ready' });
    })();
    """
}
