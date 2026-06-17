import SwiftUI

/// Full-screen block shown when the registrar returns `force_upgrade` (C.5),
/// or when the macOS DMG self-updater is in a `.forced` state (protocol C.5.3).
///
/// On macOS the optional `showMacInstallAction` flag adds a self-update section:
/// the DMG auto-downloads + verifies behind this block screen, and once a
/// verified build is staged an "Update Now" button installs it in one click
/// (CL26 `relaunch_clicked` surface=force_screen); a verification/download
/// failure shows "Retry". The iOS path passes `showMacInstallAction: false`
/// (the default) and is visually unchanged.
struct UpgradeRequiredView: View {
    let minVersion: String?
    let recommended: String?
    let message: String?
    /// macOS-only: when true, render the in-app self-update install controls.
    var showMacInstallAction: Bool = false

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
                #if os(macOS)
                if showMacInstallAction {
                    MacForceUpdateControls()
                        .padding(.top, 8)
                }
                #endif
            }
            .padding(24)
        }
    }
}

#if os(macOS)
/// The macOS force-screen self-update controls: progress while downloading/
/// verifying, an "Update Now" button once a verified build is staged, and a
/// "Retry" button on failure (re-runs `MacUpdater.check`).
private struct MacForceUpdateControls: View {
    @State private var updater = MacUpdater.shared

    var body: some View {
        VStack(spacing: 12) {
            switch updater.state {
            case .readyToInstall(let version):
                Button {
                    updater.installAndRelaunch(surface: .forceScreen)
                } label: {
                    Text("Update Now")
                        .font(AppFonts.label)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(AppColors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppColors.inputBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Update now to version \(version)")
            case .failed:
                VStack(spacing: 8) {
                    Text("Update failed. Please retry.")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Button {
                        Task { await updater.check() }
                    } label: {
                        Text("Retry")
                            .font(AppFonts.label)
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(AppColors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(AppColors.inputBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            default:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading update…")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }
}
#endif

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
