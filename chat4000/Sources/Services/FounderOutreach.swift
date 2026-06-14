import Foundation
#if os(iOS)
import UIKit
#endif

/// "Talk to the founder" escalation: try WhatsApp → Telegram → Intercom, opening
/// the first available channel. An APNs `founder_chat_prompt` push can force-skip
/// WhatsApp and/or Telegram (`disable_whatsapp` / `disable_telegram`) so we can
/// test the next channel without uninstalling an app from the device.
///
/// Detecting WhatsApp/Telegram requires their schemes (`whatsapp`, `tg`) to be
/// declared in `LSApplicationQueriesSchemes` (Info.plist) — otherwise
/// `canOpenURL` always returns false.
@MainActor
enum FounderOutreach {
    /// Founder WhatsApp number in E.164 without `+` (the form wa deep links want):
    /// +1 (646) 821-6132.
    static let whatsAppPhone = "16468216132"
    /// Founder Telegram username (no `@`).
    static let telegramUsername = "haimbender"
    static let defaultMessage = "Hi! I'm reaching out from the chat4000 app — could use a hand."

    /// Channel actually opened — also the value to report to analytics.
    enum Channel: String { case whatsApp = "whatsapp", telegram = "telegram", intercom = "intercom" }

    /// Open the first available founder channel. Returns which one was used so the
    /// caller can fire analytics. `message` prefills WhatsApp + the Intercom
    /// composer (Telegram's public scheme can't prefill a user chat).
    @discardableResult
    static func contactFounder(
        message: String?,
        disableWhatsApp: Bool,
        disableTelegram: Bool,
        source: String
    ) -> Channel {
        let text = (message.map { $0.isEmpty ? defaultMessage : $0 }) ?? defaultMessage
        #if os(iOS)
        let app = UIApplication.shared

        if !disableWhatsApp, let url = whatsAppURL(message: text), app.canOpenURL(url) {
            AppLog.log("🤝 [founder] WhatsApp installed → opening source=%@", source)
            app.open(url)
            return .whatsApp
        }
        if !disableTelegram, let url = URL(string: "tg://resolve?domain=\(telegramUsername)"), app.canOpenURL(url) {
            AppLog.log("🤝 [founder] Telegram installed → opening source=%@", source)
            app.open(url)
            return .telegram
        }
        AppLog.log("🤝 [founder] no messenger → Intercom fallback source=%@", source)
        IntercomService.openMessenger(source: "founder_chat_prompt_\(source)", initialMessage: text)
        return .intercom
        #else
        IntercomService.openMessenger(source: "founder_chat_prompt_\(source)", initialMessage: text)
        return .intercom
        #endif
    }

    #if os(iOS)
    private static func whatsAppURL(message: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "whatsapp"
        comps.host = "send"
        comps.queryItems = [
            URLQueryItem(name: "phone", value: whatsAppPhone),
            URLQueryItem(name: "text", value: message)
        ]
        return comps.url
    }
    #endif
}
