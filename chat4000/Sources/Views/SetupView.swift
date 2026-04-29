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
        case freshPluginInstall
    }

    @State private var codeText = ""
    @State private var lastSubmittedCode = ""
    @State private var showScanner = false
    @State private var helpRoute: HelpRoute = .none
    @State private var agreeChecked = false
    @FocusState private var focused: Bool

    var errorMessage: String?
    var onSubmit: (String) -> Void

    private var normalizedCode: String {
        RelayCrypto.normalizePairingCode(codeText)
    }

    private var trimmedInput: String {
        codeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requiresConsent: Bool {
        !LegalConsent.hasAcceptedAnyVersion
    }

    private var canSubmit: Bool {
        !trimmedInput.isEmpty && (!requiresConsent || agreeChecked)
    }

    private func submitInput(_ rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = RelayCrypto.normalizePairingCode(trimmed)
        let submissionKey = normalized.count == 8 ? normalized : trimmed
        DevLog.log("🔗 UI submitInput raw=\(trimmed) normalized=\(normalized) submissionKey=\(submissionKey) lastSubmitted=\(lastSubmittedCode)")
        guard submissionKey != lastSubmittedCode else { return }

        lastSubmittedCode = submissionKey
        focused = false
        if requiresConsent {
            LegalConsent.acceptPendingRelayVersion()
            TelemetryManager.shared.track(
                .legalConsentAccepted,
                properties: ["version": "pending_relay_version"]
            )
        }
        onSubmit(trimmed)
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
                    case .freshPluginInstall:
                        freshPluginInstallHelpContent
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
                    let trimmed = scannedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = RelayCrypto.normalizePairingCode(trimmed)
                    DevLog.log("🔗 UI scanner scanned raw=\(trimmed) normalized=\(normalized)")
                    codeText = normalized.count == 8 ? normalized : trimmed
                    showScanner = false
                    if requiresConsent {
                        focused = true
                    } else {
                        submitInput(trimmed)
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
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit {
                            guard canSubmit else { return }
                            DevLog.log("🔗 UI TextField onSubmit trimmedInput=\(trimmedInput)")
                            submitInput(trimmedInput)
                        }
                        .onChange(of: codeText) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                DevLog.log("🔗 UI codeText cleared")
                                codeText = ""
                                lastSubmittedCode = ""
                                return
                            }

                            let filtered = trimmed.uppercased().filter {
                                RelayCrypto.pairingCodeAlphabet.contains($0)
                            }
                            let nextCode = String(filtered.prefix(8))
                            DevLog.log("🔗 UI codeText onChange raw=\(newValue) filtered=\(filtered) nextCode=\(nextCode)")
                            codeText = nextCode

                            if !requiresConsent, nextCode.count == 8, nextCode != lastSubmittedCode {
                                DevLog.log("🔗 UI codeText reached 8 chars, auto-submitting \(nextCode)")
                                submitInput(nextCode)
                            }
                        }

                    PairingCodeBoxes(code: normalizedCode)
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
                submitInput(trimmedInput)
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
                helpRoute = .freshPluginInstall
            }

            TalkToTeamButton()
        }
    }

    private var freshPluginInstallHelpContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                helpDetailHeader(title: "Fresh Plugin Install")

                Text("Open a terminal on the machine running OpenClaw, then run these commands.")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    helpStepCard(
                        number: 1,
                        title: "Install the plugin",
                        command: "openclaw plugin install @chat4000/openclaw-plugin"
                    )
                    helpStepCard(
                        number: 2,
                        title: "Restart the gateway",
                        command: "docker restart openclaw-gateway",
                        hint: "Or stop the running openclaw gateway run process and start it again."
                    )
                    helpStepCard(
                        number: 3,
                        title: "Configure and pair",
                        command: "openclaw chat4000 setup"
                    )
                    helpStepCard(
                        number: 4,
                        title: "Scan the QR or type the code",
                        hint: "Use Scan QR on the previous screen, or enter the 8-character code shown in the terminal."
                    )
                }

                TalkToTeamCallout(caption: "That didn't help? Chat with the team.")

                helpBackToMenuButton
            }
        }
        .scrollIndicators(.hidden)
        #if os(iOS)
        .frame(maxHeight: 620)
        #else
        .frame(maxHeight: 560)
        #endif
    }

    private var pairedDeviceHelpContent: some View {
        VStack(spacing: 16) {
            helpDetailHeader(title: "Connect With a Paired Device")

            VStack(spacing: 10) {
                helpStepCard(
                    number: 1,
                    title: "Open chat4000 on a paired device",
                    hint: "Use a phone or Mac that already has chat4000 connected to your group."
                )
                helpStepCard(
                    number: 2,
                    title: "Tap Settings → Add Device",
                    hint: "It generates a fresh pairing code and QR for this connection."
                )
                helpStepCard(
                    number: 3,
                    title: "Scan or type the code here",
                    hint: "Use Scan QR on the previous screen, or enter the 8-character code."
                )
            }

            TalkToTeamCallout(caption: "That didn't help? Chat with the team.")

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

    private var characters: [String] {
        let values = Array(code).map(String.init)
        return (0..<8).map { index in
            index < values.count ? values[index] : ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<8, id: \.self) { index in
                if index == 4 {
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

struct PairingProgressView: View {
    let coordinator: PairingCoordinator
    var onCancel: () -> Void

    private let context = CIContext()

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Button(action: onCancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Close")
                                .font(AppFonts.caption)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                VStack(spacing: 10) {
                    Text("Pairing")
                        .font(AppFonts.title)
                        .foregroundStyle(AppColors.textPrimary)

                    Text(statusTitle)
                        .font(AppFonts.subtitle)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if let code = coordinator.displayedCode {
                    VStack(spacing: 18) {
                        VStack(spacing: 8) {
                            Text("Pairing Code")
                                .font(AppFonts.label)
                                .foregroundStyle(AppColors.textSecondary)

                            PairingCodeBoxes(code: RelayCrypto.normalizePairingCode(code))
                        }

                        if let qrImage = makeQRCodeImage(from: code) {
                            qrImage
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .padding(12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
                        }

                        Text("Scan from another device or type the code manually.")
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 16)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.input)
                            .stroke(AppColors.inputBorder, lineWidth: 1)
                    )
                }

                switch coordinator.phase {
                case .failed(let message):
                    statusMessage(message, color: AppColors.error, background: AppColors.errorBackground)
                case .complete(let message):
                    statusMessage(message, color: AppColors.connected, background: AppColors.inputBackground)
                default:
                    EmptyView()
                }

                Spacer()
            }
            .padding(AppSpacing.cardPadding)
        }
    }

    @ViewBuilder
    private func statusMessage(_ message: String, color: Color, background: Color) -> some View {
        Text(message)
            .font(AppFonts.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
    }

    private func makeQRCodeImage(from string: String) -> Image? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

        #if os(iOS)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #elseif os(macOS)
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180)))
        #endif
    }

    private var statusTitle: String {
        switch coordinator.phase {
        case .idle, .opening:
            return "Opening pairing session..."
        case .waitingForPeer:
            return "Waiting for another device to join"
        case .waitingForInitiator:
            return "Waiting for the initiator"
        case .verifying:
            return "Verifying pairing code"
        case .transferring:
            return "Transferring group key"
        case .complete:
            return "Pairing complete"
        case .failed:
            return "Pairing failed"
        }
    }
}
