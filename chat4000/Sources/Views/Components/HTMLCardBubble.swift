// chat4000
// Renders a chat4000.html_card. Per an explicit product decision, the card runs
// with FULL CSS *and* JavaScript so rich/interactive cards render exactly as the
// plugin authored them. The safety boundary is the NETWORK: a WKContentRuleList
// blocks every `scheme://` load (http/https/file/ws…) and the nav delegate cancels
// every navigation, so the card cannot fetch remote resources, exfiltrate, phone
// home, or follow links in-place. (Inline `data:` URLs and the in-memory document
// still render.) This intentionally departs from protocol E's "MUST NOT execute
// scripts" — JS is enabled on purpose; the network block is what keeps it contained.

import SwiftUI
import WebKit

struct HTMLCardBubble: View {
    /// Hard cap so a malformed / full-page (`100vh`) card can never take infinite
    /// vertical space and black-out the chat; taller cards scroll inside this.
    private static let maxHeight: CGFloat = 560

    let message: ChatMessage
    @State private var height: CGFloat = 60

    var body: some View {
        HTMLCardWebView(html: message.htmlCardHTML ?? "", height: $height)
            .frame(height: min(max(height, 1), Self.maxHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, AppSpacing.messageRowInset)
    }
}

private struct HTMLCardWebView: PlatformViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    /// Block every networked load (anything with a `scheme://`). Inline `data:` and
    /// the in-memory document have no `://` and still load.
    private static let blockAllNetwork =
        #"[{"trigger":{"url-filter":"://"},"action":{"type":"block"}}]"#

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    /// Reports the rendered content height REACTIVELY (on load + on every resize),
    /// so the SwiftUI frame matches the card after its real width lands — measuring
    /// once on didFinish races the width and leaves a tall empty gap.
    private static let heightReporterJS = """
    (function () {
      function report() {
        try {
          window.webkit.messageHandlers.cardHeight.postMessage(Math.ceil(document.body.scrollHeight));
        } catch (e) {}
      }
      report();
      window.addEventListener('load', report);
      if (window.ResizeObserver) { new ResizeObserver(report).observe(document.body); }
    })();
    """

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true   // JS ON (opt-in)
        config.websiteDataStore = .nonPersistent()                        // no cookies/cache
        config.userContentController.add(coordinator, name: "cardHeight")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.heightReporterJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        #if os(iOS)
        // The card must NEVER own the scroll gesture: dragging over it should scroll
        // the CHAT, not the card's HTML. The web view's internal scrollView otherwise
        // swallows the pan. The bubble frame is already sized to the reported content
        // height (capped at maxHeight), so the whole card scrolls with the page; a
        // rare over-cap card clips rather than trapping the gesture.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        let pageHTML = Self.withDeviceWidthViewport(html)
        // Compile + attach the network block, THEN load (so no load escapes it).
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "chat4000-html-card-block-network",
            encodedContentRuleList: Self.blockAllNetwork
        ) { list, _ in
            if let list { webView.configuration.userContentController.add(list) }
            webView.loadHTMLString(pageHTML, baseURL: nil)
        }
        return webView
    }

    /// WKWebView lays a page out at a 980px desktop viewport unless the HTML
    /// declares `width=device-width`. A card without that meta renders at "half
    /// width" and measures absurdly tall (e.g. 1345px for a ~250px card). If the
    /// card didn't set a viewport, inject one so it lays out at the real width.
    private static func withDeviceWidthViewport(_ html: String) -> String {
        if html.range(of: "name=\"viewport\"", options: .caseInsensitive) != nil
            || html.range(of: "name='viewport'", options: .caseInsensitive) != nil {
            return html
        }
        let meta = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        if let head = html.range(of: "<head", options: .caseInsensitive),
           let tagClose = html.range(of: ">", range: head.upperBound..<html.endIndex) {
            var out = html
            out.insert(contentsOf: meta, at: tagClose.upperBound)
            return out
        }
        return meta + html
    }

    // MARK: Platform glue
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    #endif

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let height: Binding<CGFloat>
        private var didLoadInitial = false
        nonisolated init(height: Binding<CGFloat>) { self.height = height }

        // The page posts its content height here (on load + every resize). WebKit
        // delivers script messages on the main thread.
        nonisolated func userContentController(_ ucc: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.name == "cardHeight" else { return }
                let h: CGFloat
                if let n = message.body as? NSNumber { h = CGFloat(truncating: n) } else { return }
                AppLog.log("🃏 html card reported height=%d", Int(h))
                if h > 0, abs(h - height.wrappedValue) > 0.5 { height.wrappedValue = h }
            }
        }

        // Allow only the first (in-memory) load; cancel every later navigation.
        // A user-tapped http(s) link opens in the system browser instead.
        // `decisionHandler` is typed `@MainActor @Sendable` to match WKNavigationDelegate
        // exactly under Swift 6 (otherwise the compiler emits "nearly matches").
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if !didLoadInitial {
                didLoadInitial = true
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                #if os(iOS)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }
    }
}
