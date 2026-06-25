// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

#if os(macOS)
import SwiftUI

/// macOS sidebar-footer pill: "Relaunch to update vX". Shown when the updater
/// has a verified build staged (`state == .readyToInstall`) following a
/// background `upgrade`. Styled like `UpgradeRecommendedBanner`. Tap →
/// `installAndRelaunch(surface: .pill)` (CL26 `relaunch_clicked` surface=pill).
struct UpdatePill: View {
    @State private var updater = MacUpdater.shared

    var body: some View {
        if case .readyToInstall(let version) = updater.state {
            Button {
                updater.installAndRelaunch(surface: .pill)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Relaunch to update \(version)")
                        .font(AppFonts.label)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppColors.inputBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Relaunch to update to version \(version)")
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }
}
#endif
