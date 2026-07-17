// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

#if os(iOS)
import SwiftUI

/// The recurring "you'd get more out of chat4000 with notifications on" nudge,
/// shown on foreground when notifications are currently off (App Store 4.5.4:
/// always dismissible, never blocking). Its primary action either shows the
/// system prompt (if the user never answered it) or deep-links to Settings (if
/// they declined) — see `PushNotificationManager.promptOrOpenSettings()`.
struct NotificationNudgeView: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            VStack(spacing: 10) {
                Text("chat4000 is better with notifications")
                    .font(AppFonts.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Turn them on so you never miss a reply.")
                    .font(AppFonts.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                Button {
                    Haptics.impact()
                    onEnable()
                } label: {
                    Label("Turn on notifications", systemImage: "bell.fill")
                        .font(AppFonts.button)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.impact()
                    onDismiss()
                } label: {
                    Text("Not now")
                        .font(AppFonts.button)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif
