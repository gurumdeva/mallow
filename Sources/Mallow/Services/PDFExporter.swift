// PDFExporter (Service) — renders the engine's HTML in an offscreen WKWebView and saves it as a
// compact VECTOR PDF (createPDF; the whole document as one continuous page). Each instance retains
// itself in `activePDFExporters` until its async render completes (the success OR any failure path).
//
// JavaScript is disabled in the render web view: the engine's export HTML is fully static (headings,
// lists, tables, code, and native MathML — never script), so disabling JS means a malicious .md
// exported to PDF can't run embedded `<script>` / `onerror` / `javascript:` during the offscreen render.
// Defense in depth — the engine's render_html also neutralizes dangerous URL schemes.

import AppKit
import WebKit

var activePDFExporters: [PDFExporter] = []

final class PDFExporter: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let url: URL
    init(html: String, to url: URL) {
        // Static HTML → no script needed; disabling JS neutralizes any embedded script during render.
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: config)  // ~A4 width @96dpi
        self.url = url
        super.init()
        web.navigationDelegate = self
        activePDFExporters.append(self)
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                // Surface a failed write instead of swallowing it — otherwise the user believes the export
                // succeeded while no file (or a 0-byte file) exists.
                do { try data.write(to: self.url) }
                catch { NSAlert(error: error).runModal() }
            case .failure(let err):
                NSAlert(error: err).runModal()
            }
            self.finish()
        }
    }

    // Every failure exit must also drop the self-retain, or the exporter (and its WKWebView) leaks for the
    // process lifetime with no PDF and no error. `didFail` is a committed-navigation failure;
    // `didFailProvisionalNavigation` is a load that never commits; `webContentProcessDidTerminate` is a
    // render-process crash. All three just release here (no alert — these are rare and not user-actionable
    // for a static loadHTMLString; the user-facing failures are the createPDF / write errors above).
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish()
    }

    /// Drop the self-retain so this exporter + its WKWebView can deallocate. Idempotent.
    private func finish() {
        activePDFExporters.removeAll { $0 === self }
    }
}
