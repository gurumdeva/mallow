// PDFExporter (Service) — renders the engine's HTML in an offscreen WKWebView and saves it as a
// compact VECTOR PDF (createPDF; the whole document as one continuous page). Each instance retains
// itself in `activePDFExporters` until its async render completes.

import AppKit
import WebKit

var activePDFExporters: [PDFExporter] = []

final class PDFExporter: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let url: URL
    init(html: String, to url: URL) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))  // ~A4 width @96dpi
        self.url = url
        super.init()
        web.navigationDelegate = self
        activePDFExporters.append(self)
        web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            guard let self else { return }
            if case .success(let data) = result {
                try? data.write(to: self.url)
            } else if case .failure(let err) = result {
                NSAlert(error: err).runModal()
            }
            activePDFExporters.removeAll { $0 === self }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activePDFExporters.removeAll { $0 === self }
    }
}
