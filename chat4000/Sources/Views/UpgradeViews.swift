import SwiftUI

/// Full-screen block shown when the registrar returns `force_upgrade` (C.5).
struct UpgradeRequiredView: View {
    let minVersion: String?
    let recommended: String?
    let message: String?

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                Text("Update Required")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)
                Text(message ?? "This version of chat4000 is no longer supported. Please update to continue.")
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let recommended {
                    Text("Latest version \(recommended)")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppColors.textTimestamp)
                }
            }
            .padding(24)
        }
    }
}

/// Dismissable banner shown when the registrar returns `recommend_upgrade` (C.5).
struct UpgradeRecommendedBanner: View {
    let recommendedVersion: String?
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                if let recommendedVersion {
                    Text("Recommended version \(recommendedVersion)")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .overlay(Rectangle().fill(AppColors.inputBorder).frame(height: 1), alignment: .bottom)
    }
}
