import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TalkToTeamButton: View {
    var body: some View {
        Button(action: TalkToTeam.open) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Chat with the team")
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
}

struct TalkToTeamCallout: View {
    let caption: String

    var body: some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            TalkToTeamButton()
        }
    }
}

enum TalkToTeam {
    @MainActor
    static func open() {
        Haptics.impact()
        let appURL = URL(string: "tg://resolve?domain=chat94official")!
        let webURL = URL(string: "https://t.me/chat94official")!

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
