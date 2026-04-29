import Foundation
import SwiftUI

enum LegalConsent {
    static let termsURL = URL(string: "https://chat4000.com/terms")!
    static let privacyURL = URL(string: "https://chat4000.com/privacy")!

    private static let acceptedKey = "chat4000.legal.consentAccepted"
    private static let versionKey = "chat4000.legal.consentVersion"
    private static let timestampKey = "chat4000.legal.consentTimestamp"

    static var hasAcceptedAnyVersion: Bool {
        UserDefaults.standard.bool(forKey: acceptedKey)
    }

    static var acceptedTermsVersion: Int {
        UserDefaults.standard.integer(forKey: versionKey)
    }

    static func requiresTermsAcceptance(currentTermsVersion: Int) -> Bool {
        acceptedTermsVersion < currentTermsVersion
    }

    static func acceptNow(currentTermsVersion: Int) {
        UserDefaults.standard.set(true, forKey: acceptedKey)
        UserDefaults.standard.set(currentTermsVersion, forKey: versionKey)
        UserDefaults.standard.set(Date(), forKey: timestampKey)
    }

    static func acceptPendingRelayVersion() {
        UserDefaults.standard.set(true, forKey: acceptedKey)
        UserDefaults.standard.set(Date(), forKey: timestampKey)
    }

    static func finalizePendingAcceptanceIfNeeded(currentTermsVersion: Int) {
        guard hasAcceptedAnyVersion, acceptedTermsVersion == 0 else { return }
        UserDefaults.standard.set(currentTermsVersion, forKey: versionKey)
    }
}

struct LegalConsentCheckboxRow: View {
    @Binding var isChecked: Bool

    private var consentText: AttributedString {
        var text = AttributedString("I agree to the Terms of Service and Privacy Policy")
        text.font = AppFonts.caption
        text.foregroundColor = AppColors.textSecondary

        if let termsRange = text.range(of: "Terms of Service") {
            text[termsRange].link = LegalConsent.termsURL
            text[termsRange].foregroundColor = .white
            text[termsRange].font = AppFonts.caption.bold()
        }

        if let privacyRange = text.range(of: "Privacy Policy") {
            text[privacyRange].link = LegalConsent.privacyURL
            text[privacyRange].foregroundColor = .white
            text[privacyRange].font = AppFonts.caption.bold()
        }

        return text
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                isChecked.toggle()
                Haptics.impact()
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isChecked ? Color.white : AppColors.textTimestamp)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)

            Text(consentText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

struct LegalReconsentModal: View {
    @State private var agreeChecked = false

    let currentTermsVersion: Int
    let onAccept: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x090909),
                    Color(hex: 0x111111),
                    Color(hex: 0x17120E)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text("Legal Update")
                        .font(AppFonts.title)
                        .foregroundStyle(AppColors.textPrimary)

                    Text("Please review and accept the updated Terms of Service and Privacy Policy before continuing.")
                        .font(AppFonts.subtitle)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                }

                LegalConsentCheckboxRow(isChecked: $agreeChecked)

                Button {
                    LegalConsent.acceptNow(currentTermsVersion: currentTermsVersion)
                    TelemetryManager.shared.track(
                        .legalConsentAccepted,
                        properties: ["version": currentTermsVersion]
                    )
                    onAccept()
                } label: {
                    Text("Continue")
                        .font(AppFonts.button)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(agreeChecked ? Color.white : Color.white.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(!agreeChecked)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(AppColors.cardBackground.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
            #if os(macOS)
            .frame(maxWidth: 560)
            #endif
        }
    }
}
