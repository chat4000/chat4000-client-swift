// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

#if os(macOS)
import SwiftUI

/// Non-blocking sheet for a background-verified `upgrade` (protocol C.5.3):
/// "Relaunch now" / "Later". Shown once per new version (remembered in
/// UserDefaults via `MacUpdater.markPopupShown`); the sidebar pill persists so
/// the user can always relaunch later. CL26 `popup_shown` / `popup_dismissed` /
/// `relaunch_clicked` (surface=popup).
struct UpdateAvailablePopup: View {
    let version: String
    @State private var updater = MacUpdater.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.textPrimary)
            Text("Update ready")
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)
            Text("chat4000 \(version) has been downloaded and verified. Relaunch to update.")
                .font(AppFonts.subtitle)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 10) {
                Button {
                    updater.installAndRelaunch(surface: .popup)
                } label: {
                    Text("Relaunch now")
                        .font(AppFonts.label)
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppColors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppColors.inputBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    updater.dismissPopupForSession()
                } label: {
                    Text("Later")
                        .font(AppFonts.label)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
        .padding(28)
        .frame(minWidth: 360)
        .background(AppColors.background)
        .onAppear { updater.markPopupShown(version: version) }
    }
}
#endif
