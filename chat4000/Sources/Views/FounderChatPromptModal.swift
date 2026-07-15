import SwiftUI

// `FounderChatPromptRequest` moved to Sources/Shared/FounderPromptShared.swift so
// the NSE can build/store it on push delivery (see FounderPromptPending).

/// Modal shown after an APNS push tags this device as "looks stuck."
///
/// Title + three actions: Chat now (opens Intercom), Remind me later
/// (snooze for 24h), No thanks (dismiss for this push id).
///
/// `title` and `body` are configurable per push — the APNS payload can
/// override the defaults via `modal_title` / `modal_body` fields. The
/// 10-tap QA trigger and any local invocations use the defaults below.
struct FounderChatPromptModal: View {
    @Environment(\.dismiss) private var dismiss
    let source: String
    let modalTitle: String
    let modalBody: String
    /// Outreach config (from the push, or defaults for the QA trigger).
    let contactMessage: String?
    let disableWhatsApp: Bool
    let disableTelegram: Bool

    static let defaultTitle = "Need a hand?"
    static let defaultBody = "We noticed you might be having trouble. Would you like to chat with the team right now?"

    init(
        source: String,
        modalTitle: String = FounderChatPromptModal.defaultTitle,
        modalBody: String = FounderChatPromptModal.defaultBody,
        contactMessage: String? = nil,
        disableWhatsApp: Bool = false,
        disableTelegram: Bool = false
    ) {
        self.source = source
        self.modalTitle = modalTitle
        self.modalBody = modalBody
        self.contactMessage = contactMessage
        self.disableWhatsApp = disableWhatsApp
        self.disableTelegram = disableTelegram
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.bubble.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AppColors.textPrimary)

            VStack(spacing: 12) {
                Text(modalTitle)
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)

                Text(modalBody)
                    .font(AppFonts.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)

            VStack(spacing: 10) {
                Button(action: chatNow) {
                    Text("Chat with team")
                        .font(AppFonts.button)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: remindLater) {
                    Text("Remind me later")
                        .font(AppFonts.button)
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: noThanks) {
                    Text("No thanks")
                        .font(AppFonts.button)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 360)
        .background(AppColors.background)
        .onAppear {
            TelemetryManager.shared.track(
                .founderChatPromptShown,
                properties: ["source": source]
            )
        }
    }

    private func chatNow() {
        FounderChatPromptStore.shared.markDismissedNow()
        // Escalate WhatsApp → Telegram → Intercom. `channel` is the one actually
        // opened — surface it for analytics (the analytics agent fires the event).
        let channel = FounderOutreach.contactFounder(
            message: contactMessage,
            disableWhatsApp: disableWhatsApp,
            disableTelegram: disableTelegram,
            source: source
        )
        TelemetryManager.shared.track(
            .founderChatPromptAction,
            properties: ["source": source, "action": "chat_now", "channel": channel.rawValue]
        )
        dismiss()
    }

    private func remindLater() {
        TelemetryManager.shared.track(
            .founderChatPromptAction,
            properties: ["source": source, "action": "remind_later"]
        )
        FounderChatPromptStore.shared.snoozeForOneDay()
        dismiss()
    }

    private func noThanks() {
        TelemetryManager.shared.track(
            .founderChatPromptAction,
            properties: ["source": source, "action": "no_thanks"]
        )
        FounderChatPromptStore.shared.markDismissedNow()
        dismiss()
    }
}

/// Persists the snooze / dismissal state for the founder-chat prompt across
/// app launches. Backed by UserDefaults.
/// App-side facade over the shared `FounderPromptPending` store (App-Group backed,
/// so a prompt the NSE stored on delivery — even for a DISMISSED notification — is
/// picked up here on the next foreground). Kept as the existing `@MainActor` API so
/// its callers are unchanged.
@MainActor
final class FounderChatPromptStore {
    static let shared = FounderChatPromptStore()
    private init() {}

    var isSnoozed: Bool { FounderPromptPending.isSnoozed }

    func snoozeForOneDay() { FounderPromptPending.snoozeForOneDay() }

    func markDismissedNow() {
        // No persistent suppression — a future targeted push can fire again.
        // We just clear any active snooze.
        FounderPromptPending.clearSnooze()
    }

    func storePendingPrompt(_ request: FounderChatPromptRequest) {
        FounderPromptPending.store(request)
    }

    func consumePendingPrompt() -> FounderChatPromptRequest? {
        FounderPromptPending.consume()
    }
}
