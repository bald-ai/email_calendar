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
    /// Space around the email inside the page, painted in the email's own background.
    var inset: CGFloat = 0
    /// When given, the email's own background at its edges (gray around a newsletter, say) also fills
    /// the inset and is reported here, so the sheet around the email can match it. Nil while plain white.
    var edgeColor: Binding<Color?>?

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
        let coordinator = context.coordinator
        coordinator.height = $height
        coordinator.edgeColor = edgeColor
        coordinator.inset = inset
        // Compared by input, so redrawing the page around an email never rebuilds or reloads it.
        let content = Coordinator.Content(html: html, allowsRemoteImages: allowsRemoteImages, inset: inset)
        guard coordinator.content != content else { return }
        coordinator.content = content
        webView.loadHTMLString(Self.document(html: html, allowsRemoteImages: allowsRemoteImages, inset: inset), baseURL: nil)
    }

    static func document(html: String, allowsRemoteImages: Bool, inset: CGFloat = 0) -> String {
        let imageSources = allowsRemoteImages ? "data: https: http:" : "data:"
        let side = Int(inset.rounded())
        let padding = side > 0 ? "\(side - 6)px \(side)px" : "4px 0 12px"
        // The CSP is the first element, and applies to inline CSS image URLs as
        // well as img elements. A message cannot relax it with another policy.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="color-scheme" content="light">
        <style>
        :root { color-scheme: light; }
        body { color: #1b1b1b; background-color: #fff; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.55; overflow-wrap: anywhere; margin: 0; padding: \(padding); }
        img { max-width: 100%; height: auto; } table { max-width: 100%; } pre { white-space: pre-wrap; } a { color: #3972bf; }
        blockquote { border-left: 2px solid #aaa; padding-left: 12px; margin-left: 0; opacity: .8; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Content: Equatable {
            var html: String
            var allowsRemoteImages: Bool
            var inset: CGFloat
        }

        var content: Content?
        var height: Binding<CGFloat>
        var edgeColor: Binding<Color?>?
        var inset: CGFloat = 0

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

        /// App-owned expressions; email scripts remain disabled. An email wider than the view (a 700px
        /// newsletter beside an open drawer) is scaled to fit, as Mail does, rather than cut off at the side.
        func measure(_ webView: WKWebView) {
            webView.pageZoom = 1
            // The overflow ends at the content's edge, so the inset on that side is added back.
            let room = Double(inset.rounded()) + 2
            let widths = "[document.documentElement.scrollWidth, document.documentElement.clientWidth]"
            webView.evaluateJavaScript(widths) { [weak self] result, _ in
                guard let widths = result as? [NSNumber], widths.count == 2,
                      widths[0].doubleValue > widths[1].doubleValue else {
                    Task { @MainActor in self?.measureHeight(webView, zoom: 1) }
                    return
                }
                let fit = min(1, max(0.5, widths[1].doubleValue / (widths[0].doubleValue + room)))
                Task { @MainActor in
                    webView.pageZoom = fit
                    self?.measureHeight(webView, zoom: fit)
                }
            }
        }

        private func measureHeight(_ webView: WKWebView, zoom: Double) {
            // The body's own height, not the document's: the document is never shorter than the view,
            // so a short email could never shrink it.
            let height = "Math.ceil(document.body.scrollHeight)"
            guard edgeColor != nil else {
                webView.evaluateJavaScript(height) { [weak self] result, _ in
                    guard let number = result as? NSNumber else { return }
                    Task { @MainActor in self?.height.wrappedValue = max(number.doubleValue * zoom, 60) }
                }
                return
            }
            webView.evaluateJavaScript(Self.edgeScript(inset: inset, height: height)) { [weak self] result, _ in
                guard let values = result as? [Any], let number = values.first as? NSNumber else { return }
                let color = (values.last as? String).flatMap(Self.color(css:))
                Task { @MainActor in
                    guard let self else { return }
                    self.height.wrappedValue = max(number.doubleValue * zoom, 60)
                    if self.edgeColor?.wrappedValue != color { self.edgeColor?.wrappedValue = color }
                }
            }
        }

        /// Finds a background that runs the full width and nearly the full height of the email (a newsletter's
        /// gray surround) and paints the body with it, so the inset doesn't frame the email in white.
        private static func edgeScript(inset: CGFloat, height: String) -> String {
            let probe = Int(inset.rounded()) + 6
            return """
            (() => {
              const body = document.body, total = body.scrollHeight;
              let edge = '', node = document.elementFromPoint(\(probe), \(probe));
              while (node && node !== body && node !== document.documentElement) {
                const color = getComputedStyle(node).backgroundColor;
                if (color && color !== 'transparent' && !/rgba\\(.*,\\s*0\\)$/.test(color)) {
                  const box = node.getBoundingClientRect();
                  if (box.width >= body.clientWidth - \(probe * 2) && box.height >= total * 0.8) edge = color;
                  break;
                }
                node = node.parentElement;
              }
              if (edge) { body.style.backgroundColor = edge; document.documentElement.style.backgroundColor = edge; }
              return [\(height), edge];
            })()
            """
        }

        /// "rgb(238, 238, 238)" from computed style; nil for white, which is the sheet's own color.
        static func color(css: String) -> Color? {
            let parts = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard parts.count >= 3, parts.prefix(3) != [255, 255, 255] else { return nil }
            return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
        }
    }
}

/// Text reflows when the window or a drawer changes the width, so the email is measured again.
final class MeasuringWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var measuredWidth: CGFloat = 0

    /// The email is laid out at its full height, so vertical scrolling belongs to the page around it.
    /// Sideways scrolling stays with the email, for the odd one wider than its sheet.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - measuredWidth) > 1 else { return }
        measuredWidth = bounds.width
        onWidthChange?()
    }
}
#endif
