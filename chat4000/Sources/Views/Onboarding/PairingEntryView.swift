import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The shared 6-digit pairing-code entry: hidden text field + code boxes, Scan QR,
/// the legal-consent checkbox (only while consent is still required), and Pair.
/// Self-contained — it owns the code text + consent state and its own scanner
/// sheet; the parent owns `showScanner` so it can also open the scanner from
/// elsewhere (e.g. a help/instructions screen). Lives in ONE place so the iOS
/// onboarding connect windows and the macOS pairing screen share the exact entry.
struct PairingEntryView: View {
    var errorMessage: String?
    var onSubmit: (String) -> Void
    @Binding var showScanner: Bool

    @State private var codeText = ""
    @State private var lastSubmittedCode = ""
    @State private var agreeChecked = false
    @FocusState private var focused: Bool

    /// v2 pairing codes are exactly 6 digits (OTP-style, protocol section 3).
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
        // Handles a bare typed code OR a pasted chat4000://pair?code= URI.
        let code = MatrixPairing.extractCode(from: rawInput)
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
                    // macOS 14.x renders the caret from the NSTextField field
                    // editor's insertionPointColor, which neither .accentColor nor
                    // .tint reach — drop rendering opacity to ~0 so the caret is
                    // invisible while the field stays fully interactive (opacity
                    // affects rendering only, not hit testing / the responder
                    // chain). PairingCodeBoxes shows the visible state.
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
                        // Keep digits only (or the code param if a URI was pasted),
                        // capped at the 6-digit code length.
                        let digits = MatrixPairing.extractCode(from: newValue)
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

            Button {
                Haptics.impact()
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
                Haptics.impact()
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
        .onAppear { focused = true }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScanned: { scannedText in
                    // A QR usually encodes chat4000://pair?code=NNNNNN — parse the
                    // `code` param (don't digit-filter the whole payload).
                    let code = MatrixPairing.extractCode(from: scannedText)
                    codeText = code
                    showScanner = false
                    if requiresConsent {
                        focused = true
                    } else {
                        submitInput(code)
                    }
                },
                onBack: { showScanner = false }
            )
            .presentationBackground(AppColors.background)
        }
    }
}
