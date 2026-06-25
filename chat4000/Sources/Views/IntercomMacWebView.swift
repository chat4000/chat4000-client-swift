#if os(macOS)
import SwiftUI
import WebKit
import AppKit

/// macOS support chat: embeds the Intercom Web Messenger in a `WKWebView`.
///
/// Intercom does NOT ship a native macOS SDK (and has no plan to ship one
/// per their July 2024 community statement). Intercom Support officially
/// recommends embedding their web messenger via webview for desktop apps.
/// This is the implementation of that recommendation, following the design
/// from the May 2026 deep-research doc.
///
/// **Identity:** scaffolded in unidentified mode (no `user_id`, no JWT).
/// To merge Mac conversations with iOS Intercom users into a single inbox,
/// fill in `userId` + `intercomUserJwt` once a backend signing endpoint
/// exists. Both fields must be set together for identification to apply.
@MainActor
final class IntercomMacBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate {
    @Published var unreadCount: Int = 0
    @Published var isReady: Bool = false

    let source: String

    init(source: String) {
        self.source = source
    }

    nonisolated func userContentController(
        _ ucc: WKUserContentController,
        didReceive msg: WKScriptMessage
    ) {
        // WebKit invokes script-message delegates on the main thread.
        MainActor.assumeIsolated {
            switch msg.name {
            case "intercom_unread":
                if let n = msg.body as? Int { self.unreadCount = n }
            case "intercom_ready":
                self.isReady = true
            default:
                break
            }
        }
    }

    // The completion handler is typed `@MainActor @Sendable` to match
    // WKUIDelegate's optional requirement exactly under Swift 6 concurrency —
    // otherwise the compiler emits a "nearly matches" warning.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        // Synchronous modal — avoids the Swift 6 Sendable-capture trap of
        // calling `completionHandler` from inside `panel.begin`'s closure.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let resp = panel.runModal()
        completionHandler(resp == .OK ? panel.urls : nil)
    }

    // Open `target="_blank"` and `window.open` calls in the user's default
    // browser instead of swallowing them inside the WebView.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

struct IntercomMacWebView: NSViewRepresentable {
    @ObservedObject var bridge: IntercomMacBridge

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(bridge, name: "intercom_unread")
        cfg.userContentController.add(bridge, name: "intercom_ready")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = bridge
        wv.setValue(false, forKey: "drawsBackground")
        // Pin the WebView's effective appearance to dark so any system-
        // theme branches inside Intercom's CSS resolve to the dark variant.
        wv.appearance = NSAppearance(named: .darkAqua)

        wv.loadHTMLString(
            Self.html(source: bridge.source),
            baseURL: URL(string: "https://chat4000.com/")
        )
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Tiny HTML shell that loads Intercom's widget from `widget.intercom.io`.
    /// Loaded with baseURL https://chat4000.com so cookies / localStorage are
    /// first-party to our shell origin (ITP-safe).
    private static func html(source: String) -> String {
        let appId = IntercomConfig.appId
        let identityBlock: String
        if let userId = IntercomConfig.userId, let jwt = IntercomConfig.userJwt {
            identityBlock = """
            "user_id": \(jsonString(userId)),
            "intercom_user_jwt": \(jsonString(jwt)),
            """
        } else {
            identityBlock = ""
        }
        let sourceJSON = jsonString(source)
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <style>
          :root { color-scheme: dark; }
          html, body { margin:0; padding:0; height:100%; background: #0F0F0F; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; color: #E0E0E0; }
        </style>
        </head>
        <body>
        <script>
          window.intercomSettings = {
            api_base: "https://api-iam.intercom.io",
            app_id: \(jsonString(appId)),
            \(identityBlock)
            custom_attributes: { source: \(sourceJSON), platform: "macos" }
          };
          // Theme is controlled in Intercom dashboard → Settings →
          // Messenger → Web → Appearance → "Messenger theme mode".
          // Set it to "Match System" (or "Dark") and the embed picks up
          // the dark variant via the page's color-scheme meta + CSS.
          (function(){var w=window,ic=w.Intercom;
            if(typeof ic==="function"){ ic('reattach_activator'); ic('update', w.intercomSettings); }
            else{
              var d=document, i=function(){i.c(arguments)};
              i.q=[]; i.c=function(args){i.q.push(args)};
              w.Intercom=i;
              var l=function(){
                var s=d.createElement('script'); s.async=true;
                s.src='https://widget.intercom.io/widget/' + window.intercomSettings.app_id;
                d.head.appendChild(s);
              };
              if(d.readyState==='complete'){ l(); } else { w.addEventListener('load', l); }
            }
          })();
          window.Intercom('onUnreadCountChange', function(n){
            try { window.webkit.messageHandlers.intercom_unread.postMessage(n|0); } catch(e){}
          });
          window.Intercom('onShow', function(){
            try { window.webkit.messageHandlers.intercom_ready.postMessage(true); } catch(e){}
          });
          window.Intercom('show');
        </script>
        </body></html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard
            let data,
            let array = String(data: data, encoding: .utf8),
            array.count > 2
        else {
            return "\"\""
        }
        // Strip outer [] from the JSON array containing the one element.
        return String(array.dropFirst().dropLast())
    }
}

/// Shared config so the Mac webview and iOS native SDK use the same Intercom
/// workspace. Replace placeholders with real values once Intercom is
/// provisioned.
enum IntercomConfig {
    /// Intercom workspace App ID. Find at Intercom → Settings → Installation.
    /// Must match `IntercomService.appId` on the iOS side.
    static let appId: String = "mdj5dae1"

    /// Optional identified-user fields. Both must be set together. Leaving
    /// nil keeps the messenger in unidentified mode (anonymous, no cross-
    /// device merge). To enable unified inbox: fetch a JWT from your backend
    /// signed with HS256 using the Intercom Messenger API secret and pass
    /// the same user_id you use on iOS.
    static let userId: String? = nil
    static let userJwt: String? = nil
}

#endif
