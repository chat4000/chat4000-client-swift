import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Tappable button for the "Chat with founder" CTA. Runs the same escalation as
/// the founder push modal: WhatsApp → Telegram → Intercom (`FounderOutreach`).
/// On macOS it goes straight to the Intercom web messenger.
struct ChatWithFounderButton: View {
    /// Funnel source for analytics. e.g. "settings", "setup_pair_failed".
    let source: String

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: "person.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Chat with founder")
                    .font(AppFonts.button)
            }
            .foregroundStyle(AppColors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tap() {
        Haptics.impact()
        // Same escalation as the founder push modal. No push context here, so no
        // channel overrides — WhatsApp → Telegram → Intercom, default message.
        // (Analytics for the chosen channel is owned by the analytics agent; the
        // Intercom fallback still fires founder_chat_opened via openMessenger.)
        FounderOutreach.contactFounder(
            message: nil,
            disableWhatsApp: false,
            disableTelegram: false,
            source: source
        )
    }
}

/// Tappable button that opens the chat4000 Telegram community group.
/// Distinct from the founder chat — this is the public community, not
/// 1-on-1 support.
struct JoinTelegramCommunityButton: View {
    let source: String

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Join the Telegram community")
                    .font(AppFonts.button)
            }
            .foregroundStyle(AppColors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tap() {
        Haptics.impact()
        TelemetryManager.shared.track(
            .telegramCommunityOpened,
            properties: ["source": source]
        )
        TelegramCommunity.open()
    }
}

/// Caption + founder button. Used on pairing failure screens and other
/// "stuck user" surfaces where we want one clear escape hatch.
struct ChatWithFounderCallout: View {
    let caption: String
    let source: String

    var body: some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            ChatWithFounderButton(source: source)
        }
    }
}

/// Helper that opens the chat4000 Telegram community URL on either
/// platform. Tries the Telegram app first, falls back to web.
enum TelegramCommunity {
    @MainActor
    static func open() {
        let appURL = requireURL("tg://resolve?domain=chat4000official")
        let webURL = requireURL("https://t.me/chat4000official")

        #if os(iOS)
        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else {
            UIApplication.shared.open(webURL)
        }
        #elseif os(macOS)
        if NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
            NSWorkspace.shared.open(appURL)
        } else {
            NSWorkspace.shared.open(webURL)
        }
        #endif
    }
}
