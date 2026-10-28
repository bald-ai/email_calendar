#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Email content uses an ephemeral browser with scripting, forms, plug-ins and
/// every network resource except explicitly approved images disabled.
struct MailHTMLView: NSViewRepresentable {
    var html: String
    var allowsRemoteImages: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> MeasuringWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = MeasuringWebView(frame: .zero, configuration: configuration)
        webView.onWidthChange = { [weak coordinator = context.coordinator, weak webView] in
            guard let webView else { return }
            coordinator?.measure(webView)
        }
        // Email cards have a white background, regardless of the app's appearance.
        webView.appearance = NSAppearance(named: .aqua)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: MeasuringWebView, context: Context) {
        context.coordinator.height = $height
        let document = Self.document(html: html, allowsRemoteImages: allowsRemoteImages)
        guard context.coordinator.document != document else { return }
        context.coordinator.document = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func document(html: String, allowsRemoteImages: Bool) -> String {
        let imageSources = allowsRemoteImages ? "data: https: http:" : "data:"
        // The CSP is the first element, and applies to inline CSS image URLs as
        // well as img elements. A message cannot relax it with another policy.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="color-scheme" content="light">
        <style>
        :root { color-scheme: light; }
        body { color: #1b1b1b; background-color: #fff; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.55; overflow-wrap: anywhere; margin: 0; padding: 4px 0 12px; }
        img { max-width: 100%; height: auto; } table { max-width: 100%; } pre { white-space: pre-wrap; } a { color: #3972bf; }
        blockquote { border-left: 2px solid #aaa; padding-left: 12px; margin-left: 0; opacity: .8; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var document = ""
        var height: Binding<CGFloat>

        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated else {
                // Only the app's initial HTML document may navigate this view.
                decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
                return
            }
            if let url = navigationAction.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { measure(webView) }

        func measure(_ webView: WKWebView) {
            // This app-owned expression measures content; email scripts remain
            // disabled. Clamp exceptionally large messages to a scrollable view.
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
                guard let number = result as? NSNumber else { return }
                Task { @MainActor in self?.height.wrappedValue = min(max(number.doubleValue, 80), 2_000) }
            }
        }
    }
}

/// Text reflows when the window or a drawer changes the width, so the email is measured again.
final class MeasuringWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var measuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        guard abs(bounds.width - measuredWidth) > 1 else { return }
        measuredWidth = bounds.width
        onWidthChange?()
    }
}
#endif
