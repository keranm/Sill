import WebKit

/// developer-tools.md #4 — JSON formatting, in-page half: always-on,
/// no toggle. When a direct navigation resolves to a JSON response,
/// `document.contentType` (a real DOM property reflecting the MIME type
/// WebKit actually rendered) tells the injected script to replace the raw
/// text dump with a collapsible, highlighted tree — using `<details>`/
/// `<summary>` so expand/collapse is native, keyboard-accessible browser
/// behavior, not custom JS state. Bails out silently (leaves the page
/// alone) if the body isn't valid JSON despite the content-type header.
///
/// This is a separate implementation from JSONTreeView (native SwiftUI, used
/// by the API client's response viewer) since this one runs inside the
/// WKWebView's own document, not our SwiftUI hierarchy — same look, two
/// runtimes, per developer-tools.md's "two entry points, one capability" idea
/// applied to formatting rather than capture.
enum JSONFormatting {
    static func attach(to controller: WKUserContentController) {
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        controller.addUserScript(script)
    }

    private static let source = """
    (function () {
      if (document.contentType !== 'application/json') return;
      var raw = document.body ? document.body.textContent : '';
      var data;
      try { data = JSON.parse(raw); } catch (e) { return; }
      // Stashed before the DOM is rewritten below, so anything reading the
      // page's JSON afterward (WebKitDelegate's API-collection detection)
      // doesn't have to fight over document.body.textContent, which this
      // script is about to replace with the rendered tree's own text.
      window.__sillRawJSON = raw;

      function esc(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }

      function renderLeaf(v) {
        if (v === null) return '<span class="sill-json-null">null</span>';
        var t = typeof v;
        if (t === 'string') return '<span class="sill-json-string">"' + esc(v) + '"</span>';
        if (t === 'boolean') return '<span class="sill-json-bool">' + v + '</span>';
        return '<span class="sill-json-number">' + v + '</span>';
      }

      function renderNode(v) {
        if (Array.isArray(v)) {
          if (v.length === 0) return '<span class="sill-json-punct">[ ]</span>';
          var items = v.map(function (item, i) {
            return '<li><span class="sill-json-key">' + i + ':</span> ' + renderValue(item) + '</li>';
          }).join('');
          return '<details open><summary><span class="sill-json-punct">[ ' + v.length + ' ]</span></summary><ul class="sill-json-list">' + items + '</ul></details>';
        }
        if (v && typeof v === 'object') {
          var keys = Object.keys(v);
          if (keys.length === 0) return '<span class="sill-json-punct">{ }</span>';
          var items = keys.map(function (k) {
            return '<li><span class="sill-json-key">' + esc(k) + ':</span> ' + renderValue(v[k]) + '</li>';
          }).join('');
          return '<details open><summary><span class="sill-json-punct">{ ' + keys.length + ' }</span></summary><ul class="sill-json-list">' + items + '</ul></details>';
        }
        return renderLeaf(v);
      }

      function renderValue(v) {
        return (v && typeof v === 'object') ? renderNode(v) : renderLeaf(v);
      }

      var style = document.createElement('style');
      style.textContent = [
        'body { background:#FBFAF8; color:#21201C; font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace; padding:16px; margin:0; }',
        '.sill-json-list { list-style:none; margin:0; padding-left:16px; border-left:1px solid rgba(33,32,28,0.08); }',
        '.sill-json-key { color:rgba(33,32,28,0.55); }',
        '.sill-json-string { color:#267D7D; }',
        '.sill-json-number { color:#21201C; }',
        '.sill-json-bool { color:#8F5B22; }',
        '.sill-json-null { color:rgba(33,32,28,0.35); }',
        '.sill-json-punct { color:rgba(33,32,28,0.55); }',
        'summary { cursor:pointer; }',
        'summary::-webkit-details-marker { color:rgba(33,32,28,0.35); }',
      ].join('\\n');

      document.head.appendChild(style);
      document.body.innerHTML = renderNode(data);
    })();
    """
}
