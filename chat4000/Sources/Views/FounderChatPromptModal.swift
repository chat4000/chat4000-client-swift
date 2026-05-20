import SwiftUI

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

    static let defaultTitle = "Need a hand?"
    static let defaultBody = "We noticed you might be having trouble. Would you like to chat with a founder right now?"

    init(
        source: String,
        modalTitle: String = FounderChatPromptModal.defaultTitle,
        modalBody: String = FounderChatPromptModal.defaultBody
    ) {
        self.source = source
        self.modalTitle = modalTitle
        self.modalBody = modalBody
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
                    Text("Chat with founder")
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
        TelemetryManager.shared.track(
            .founderChatPromptAction,
            properties: ["source": source, "action": "chat_now"]
        )
        FounderChatPromptStore.shared.markDismissedNow()
        IntercomService.openMessenger(source: "founder_chat_prompt_\(source)")
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
@MainActor
final class FounderChatPromptStore {
    static let shared = FounderChatPromptStore()

    private let snoozeUntilKey = "chat4000.FounderChatPrompt.snoozeUntil"
    private let snoozeWindow: TimeInterval = 60 * 60 * 24 // 24 hours

    private init() {}

    var isSnoozed: Bool {
        guard let until = UserDefaults.standard.object(forKey: snoozeUntilKey) as? Date else {
            return false
        }
        return until > Date()
    }

    func snoozeForOneDay() {
        UserDefaults.standard.set(Date().addingTimeInterval(snoozeWindow), forKey: snoozeUntilKey)
    }

    func markDismissedNow() {
        // No persistent suppression — a future targeted push can fire again.
        // We just clear any active snooze.
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
    }
}
