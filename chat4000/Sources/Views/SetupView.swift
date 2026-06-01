import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct EnterPairingCodeView: View {
    private enum HelpRoute {
        case none
        case menu
        case pairedDevice
        // Fresh-install help opens the canonical web page directly
        // (https://chat4000.com/#install) instead of duplicating the
        // setup steps in-app — that page is the single source of truth
        // for both Hermes and OpenClaw flows.
    }

    @State private var codeText = ""
    @State private var lastSubmittedCode = ""
    @State private var showScanner = false
    @State private var helpRoute: HelpRoute = .none
    @State private var agreeChecked = false
    @FocusState private var focused: Bool

    var errorMessage: String?
    var onSubmit: (String) -> Void

    /// v2 pairing codes are exactly 6 digits (OTP-style, protocol §3).
    private static let codeLength = 6

    /// Digits-only, capped at the code length — what the boxes show and we submit.
    private var sanitizedCode: String {
        String(codeText.filter(\.isNumber).prefix(Self.codeLength))
    }

    private var requiresConsent: Bool {
        !LegalConsent.hasAcceptedAnyVersion
    }

    private var canSubmit: Bool {
        sanitizedCode.count == Self.codeLength && (!requiresConsent || agreeChecked)
    }

    private func submitInput(_ rawInput: String) {
        let code = String(rawInput.filter(\.isNumber).prefix(Self.codeLength))
        guard code.count == Self.codeLength, code != lastSubmittedCode else { return }

        lastSubmittedCode = code
        focused = false
        if requiresConsent {
            LegalConsent.acceptPendingRelayVersion()
            TelemetryManager.shared.track(
                .legalConsentAccepted,
                properties: ["version": "pending_relay_version"]
            )
        }
        onSubmit(code)
    }

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

            Circle()
                .fill(Color.white.opacity(0.045))
                .frame(width: 280, height: 280)
                .blur(radius: 40)
                .offset(x: -130, y: -240)

            Circle()
                .fill(Color(hex: 0xC28C48).opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: 150, y: 260)

            VStack {
                Spacer(minLength: 20)

                Group {
                    switch helpRoute {
                    case .none:
                        mainPairingContent
                    case .menu:
                        helpMenuContent
                    case .pairedDevice:
                        pairedDeviceHelpContent
                    }
                }
                .padding(AppSpacing.cardPadding)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(AppColors.cardBackground.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 18)
                )
                .padding(.horizontal, 24)
                #if os(macOS)
                .frame(maxWidth: 620)
                #endif

                Spacer(minLength: 20)
            }
            .onTapGesture { focused = false }
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScanned: { scannedText in
                    // Accept a QR encoding the 6-digit code (optionally as a
                    // chat4000://pair?code=NNNNNN URI) — just extract the digits.
                    let code = String(scannedText.filter(\.isNumber).prefix(Self.codeLength))
                    codeText = code
                    showScanner = false
                    if requiresConsent {
                        focused = true
                    } else {
                        submitInput(code)
                    }
                },
                onBack: {
                    showScanner = false
                }
            )
            .presentationBackground(AppColors.background)
        }
    }
}

extension EnterPairingCodeView {
    private var mainPairingContent: some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                Text("chat4000")
                    .font(AppFonts.mono(11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(AppColors.textTimestamp)

                Text("Hi")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)

                Text("To start chatting, pair your device.")
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }

            VStack(spacing: 14) {
                Text("Pairing code")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textSecondary)

                ZStack {
                    TextField("", text: $codeText)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        .font(AppFonts.input)
                        .foregroundStyle(.clear)
                        .accentColor(.clear)
                        // macOS 14.x renders the TextField caret using the
                        // underlying NSTextField field editor's
                        // insertionPointColor, which neither .accentColor
                        // nor .tint reach. Drop the entire TextField's
                        // rendering opacity to ~0 so the caret is
                        // invisible; the field stays fully interactive
                        // (focus, typing, paste, return) because .opacity
                        // affects rendering only, not hit testing or the
                        // responder chain. PairingCodeBoxes shows the
                        // visible state.
                        .opacity(0.001)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit {
                            guard canSubmit else { return }
                            submitInput(codeText)
                        }
                        .onChange(of: codeText) { _, newValue in
                            // Keep digits only, capped at the 6-digit code length.
                            let digits = String(newValue.filter(\.isNumber).prefix(Self.codeLength))
                            if digits != newValue { codeText = digits }
                            if digits.isEmpty { lastSubmittedCode = "" }
                            // Auto-submit once 6 digits are entered (OTP-style).
                            if !requiresConsent, digits.count == Self.codeLength, digits != lastSubmittedCode {
                                submitInput(digits)
                            }
                        }

                    PairingCodeBoxes(code: sanitizedCode)
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                Text("Enter the code from your plugin or another paired device.")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textTimestamp)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
            }

            Button {
                showScanner = true
            } label: {
                Label("Scan QR", systemImage: "qrcode.viewfinder")
                    .font(AppFonts.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            if requiresConsent {
                LegalConsentCheckboxRow(isChecked: $agreeChecked)
                    .padding(.horizontal, 4)
            }

            Button {
                submitInput(codeText)
            } label: {
                Text("Pair")
                    .font(AppFonts.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canSubmit ? Color.white : Color.white.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(canSubmit ? 0.15 : 0), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            Button {
                focused = false
                helpRoute = .menu
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Need help?")
                        .font(AppFonts.caption)
                }
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.04))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.errorBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
            }
        }
    }

    private var helpMenuContent: some View {
        VStack(spacing: 20) {
            HStack {
                Button {
                    helpRoute = .none
                    focused = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(AppFonts.caption)
                    }
                    .foregroundStyle(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            VStack(spacing: 8) {
                Text("Need Help?")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)

                Text("Choose what you are trying to connect from.")
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            helpButton(title: "Connect with a Paired Device") {
                helpRoute = .pairedDevice
            }

            helpButton(title: "Fresh Plugin Install") {
                // Setup docs cover both Hermes and OpenClaw flows — keep
                // it as a single canonical web page so we don't fork two
                // copies in-app every time the install command changes.
                if let url = URL(string: "https://chat4000.com/#install") {
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #elseif os(macOS)
                    NSWorkspace.shared.open(url)
                    #endif
                }
            }

            ChatWithFounderButton(source: "setup_help_menu")
        }
    }

    // `freshPluginInstallHelpContent` removed — the "Fresh Plugin Install"
    // button now opens https://chat4000.com/#install in the system
    // browser directly so the in-app help doesn't drift from the canonical
    // setup docs every time the install command changes (and so we don't
    // need to fork the page into separate Hermes / OpenClaw branches
    // in-app — chat4000.com#install handles both).

    private var pairedDeviceHelpContent: some View {
        VStack(spacing: 16) {
            helpDetailHeader(title: "Connect With a Paired Device")

            VStack(spacing: 10) {
                helpStepCard(
                    number: 1,
                    title: "Open your plugin on your computer",
                    hint: "Run your OpenClaw or Hermes plugin and ask it for a new pairing code."
                )
                helpStepCard(
                    number: 2,
                    title: "Copy the 6-digit code",
                    hint: "The plugin prints a single-use 6-digit code (and may show a QR)."
                )
                helpStepCard(
                    number: 3,
                    title: "Enter it here",
                    hint: "Type the 6 digits on this screen, or scan the QR with Scan QR."
                )
            }

            ChatWithFounderCallout(caption: "That didn't help? Chat with founder.", source: "setup_pair_failed")

            helpBackToMenuButton
        }
    }

    private func helpDetailHeader(title: String) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    helpRoute = .menu
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(AppFonts.caption)
                    }
                    .foregroundStyle(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text(title)
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
        }
    }

    private func helpStepCard(
        number: Int,
        title: String,
        command: String? = nil,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(AppFonts.mono(11, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())

                Text(title)
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let command {
                Text(command)
                    .font(AppFonts.mono(11, weight: .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }

            if let hint {
                Text(hint)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var helpBackToMenuButton: some View {
        Button {
            helpRoute = .menu
        } label: {
            Text("Back to Help")
                .font(AppFonts.button)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
        }
        .buttonStyle(.plain)
    }

    private func helpButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFonts.button)
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PairingCodeBoxes: View {
    let code: String

    private static let count = 6

    private var characters: [String] {
        let values = Array(code).map(String.init)
        return (0..<Self.count).map { index in
            index < values.count ? values[index] : ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<Self.count, id: \.self) { index in
                if index == Self.count / 2 {
                    Rectangle()
                        .fill(AppColors.textTimestamp)
                        .frame(width: 14, height: 2)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(characters[index].isEmpty ? 0.03 : 0.08))
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(characters[index].isEmpty ? Color.white.opacity(0.06) : Color.white.opacity(0.16), lineWidth: 1)

                    Text(characters[index].isEmpty ? " " : characters[index])
                        .font(AppFonts.mono(24, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .frame(width: 38, height: 54)
            }
        }
    }
}
