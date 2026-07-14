import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct EnterPairingCodeView: View {
    // The pairing-screen Help is a 3-way "where are you starting from" menu.
    // Each branch has its own analytics route (CL20) and funnel (CL33-37).
    private enum HelpRoute {
        case none          // main pairing content
        case menu          // the 3-option chooser
        case otherDevice   // ① already have chat4000 on another device → Add Device / QR
        case freshInstall  // ② have OpenClaw/Hermes, need the chat4000 plugin
        case noAgent       // ③ have neither yet → need an agent first
    }

    @State private var codeText = ""
    @State private var lastSubmittedCode = ""
    @State private var showScanner = false
    @State private var helpRoute: HelpRoute = .none
    @State private var installCommandCopied = false
    /// Fresh-install branch: nil = ask which agent; "openclaw"/"hermes" = chosen.
    /// Mirrors the onboarding question. "Something else" is no longer here — it's
    /// the top-level ③ "I don't have either" route (`.noAgent`).
    @State private var freshInstallAgent: String?
    /// Fresh-install branch, after the agent is picked: nil = ask; true = "send the
    /// curl to your agent chat"; false = "SSH into the machine and run it".
    @State private var freshInstallHasMessaging: Bool?
    @State private var agreeChecked = false
    @FocusState private var focused: Bool

    var errorMessage: String?
    var onSubmit: (String) -> Void

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
                    case .otherDevice:
                        otherDeviceHelpContent
                    case .freshInstall:
                        freshPluginInstallHelpContent
                    case .noAgent:
                        noAgentHelpContent
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
                    // Accept a QR encoding the 6-digit code, usually a
                    // chat4000://pair?code=NNNNNN URI — parse the `code` param
                    // (don't digit-filter the whole payload).
                    let code = MatrixPairing.extractCode(from: scannedText)
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
                            // Keep digits only (or the code param if a URI was
                            // pasted), capped at the 6-digit code length.
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
                TelemetryManager.shared.track(.helpMenuOpened, properties: ["source": "setup"])  // CL19
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

                Text("Where are you starting from?")
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // ① already signed in somewhere else → device-to-device (Add Device).
            helpButton(
                title: "I already have chat4000 on another device",
                subtitle: "Add this device from one that's already signed in."
            ) {
                helpRoute = .otherDevice
                TelemetryManager.shared.track(.helpRouteSelected, properties: ["route": "have_other_device"])  // CL20
            }

            // ② has an agent but no chat4000 plugin → fresh install.
            helpButton(
                title: "I have OpenClaw or Hermes, but not chat4000",
                subtitle: "Install the chat4000 plugin in your agent."
            ) {
                freshInstallAgent = nil            // start this branch at the agent question
                freshInstallHasMessaging = nil
                helpRoute = .freshInstall
                TelemetryManager.shared.track(.helpRouteSelected, properties: ["route": "have_agent"])  // CL20
            }

            // ③ no agent at all → they need OpenClaw or Hermes first.
            helpButton(
                title: "I don't have either yet",
                subtitle: "chat4000 runs on OpenClaw or Hermes."
            ) {
                helpRoute = .noAgent
                TelemetryManager.shared.track(.helpRouteSelected, properties: ["route": "have_neither"])  // CL20
            }

            ChatWithFounderButton(source: "setup_help_menu")
        }
    }

    /// The canonical one-line installer (mirrors chat4000.com/#install step 2).
    /// One command covers both OpenClaw and Hermes — no in-app forking.
    static let installCommand = "curl -fsSL https://chat4000.com/install.sh | bash"

    /// ② Fresh plugin install: pick the agent → do you have a messaging channel →
    /// the exact command to run (via that chat, or over SSH) → Done, enter code.
    private var freshPluginInstallHelpContent: some View {
        VStack(spacing: 16) {
            helpDetailHeader(title: "Install the Plugin")

            if freshInstallAgent == nil {
                freshInstallAgentQuestion
            } else if freshInstallHasMessaging == nil {
                freshInstallMessagingQuestion
            } else if freshInstallHasMessaging == true {
                freshInstallCommand(method: "messaging")
            } else {
                freshInstallCommand(method: "ssh")
            }
        }
    }

    private var freshInstallAgentQuestion: some View {
        VStack(spacing: 12) {
            Text("Which one do you have?")
                .font(AppFonts.label)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
            agentHelpButton(title: "OpenClaw", glyph: "🦞") { selectFreshAgent("openclaw") }
            agentHelpButton(title: "Hermes", glyph: "☤", glyphScale: 1.3) { selectFreshAgent("hermes") }
            helpBackToMenuButton
        }
    }

    private func selectFreshAgent(_ agent: String) {
        freshInstallAgent = agent
        TelemetryManager.shared.track(.helpAgentSelected, properties: ["agent": agent])  // CL34
    }

    private var freshInstallMessagingQuestion: some View {
        VStack(spacing: 12) {
            Text("Do you already message your agent somewhere?")
                .font(AppFonts.label)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text("Like Telegram — any chat you already use to talk to it.")
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
            helpButton(title: "Yes, I can message it") { answerMessaging(true) }
            helpButton(title: "No, I'll use the terminal (SSH)") { answerMessaging(false) }
            helpSecondaryBack("Back") { freshInstallAgent = nil }
        }
    }

    private func answerMessaging(_ hasMessaging: Bool) {
        freshInstallHasMessaging = hasMessaging
        TelemetryManager.shared.track(.helpMessagingAnswered, properties: [
            "agent": freshInstallAgent ?? "unknown",
            "has_messaging": hasMessaging
        ])  // CL35
    }

    /// The install-command screen. `method` is "messaging" (send the curl to the
    /// agent in chat) or "ssh" (run it on the machine). The one-liner is identical
    /// either way — only the surrounding copy differs.
    private func freshInstallCommand(method: String) -> some View {
        let agentName = freshInstallAgent == "hermes" ? "Hermes" : "OpenClaw"
        return VStack(spacing: 10) {
            if method == "messaging" {
                helpStepCard(
                    number: 1,
                    title: "Send this to your \(agentName) agent",
                    command: Self.installCommand,
                    hint: "Paste it into Telegram — or wherever you chat with \(agentName). It installs chat4000 and replies with a single-use 6-digit code."
                )
            } else {
                helpStepCard(
                    number: 1,
                    title: "SSH into the machine and run this",
                    command: Self.installCommand,
                    hint: "Run it on the computer where \(agentName) lives. It installs chat4000 and prints a single-use 6-digit code."
                )
            }
            copyInstallCommandButton(method: method)
            helpStepCard(
                number: 2,
                title: "Enter the code here",
                hint: "Copy the 6-digit code it gives you, tap Done, and type it on the pairing screen."
            )
            ChatWithFounderCallout(caption: "Stuck? Chat with founder.", source: "setup_fresh_install")
            Button {
                helpRoute = .none
                focused = true
                TelemetryManager.shared.track(.helpFreshDone, properties: [
                    "agent": freshInstallAgent ?? "unknown",
                    "method": method
                ])  // CL37
            } label: {
                Text("Done — enter code")
                    .font(AppFonts.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
            }
            .buttonStyle(.plain)
            helpSecondaryBack("Back") { freshInstallHasMessaging = nil }
        }
    }

    /// ③ No agent at all — chat4000 needs OpenClaw or Hermes first.
    private var noAgentHelpContent: some View {
        VStack(spacing: 16) {
            helpDetailHeader(title: "You'll Need an Agent First")
            VStack(spacing: 10) {
                Text("chat4000 runs on top of an AI agent")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Text("Get OpenClaw or Hermes set up on your computer first, then come back and pick the OpenClaw or Hermes option.")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            ChatWithFounderCallout(caption: "Not sure where to start? Chat with founder.", source: "setup_no_agent")
            helpBackToMenuButton
        }
    }

    private func agentHelpButton(
        title: String,
        glyph: String? = nil,
        glyphScale: CGFloat = 1.0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let glyph {
                    Text(glyph)
                        .font(.system(size: 20 * glyphScale))
                        .frame(width: 26, alignment: .center)
                }
                Text(title)
                    .font(AppFonts.button)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.horizontal, 18)
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

    private func copyInstallCommandButton(method: String) -> some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = Self.installCommand
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.installCommand, forType: .string)
            #endif
            Haptics.success()
            installCommandCopied = true
            TelemetryManager.shared.track(.helpInstallCommandCopied, properties: [
                "agent": freshInstallAgent ?? "unknown",
                "method": method
            ])  // CL36
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                installCommandCopied = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: installCommandCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                Text(installCommandCopied ? "Copied" : "Copy command")
                    .font(AppFonts.button)
            }
            .foregroundStyle(installCommandCopied ? AppColors.connected : AppColors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// ① You already have chat4000 running on another phone/Mac: mint the code
    /// there via Settings → Add Device (device-to-device, no terminal), then come
    /// back here and scan or type it.
    private var otherDeviceHelpContent: some View {
        VStack(spacing: 16) {
            helpDetailHeader(title: "Add From Another Device")

            VStack(spacing: 10) {
                helpStepCard(
                    number: 1,
                    title: "Open chat4000 on your other device",
                    hint: "The phone or Mac that's already signed in."
                )
                helpStepCard(
                    number: 2,
                    title: "Go to Settings → Add Device",
                    hint: "It shows a QR code and a single-use 6-digit code."
                )
                helpStepCard(
                    number: 3,
                    title: "Scan or enter it here",
                    hint: "Tap Scan QR below, or type the 6 digits on the pairing screen."
                )
            }

            // "Back to main to scan the QR" — closes Help, returns to the pairing
            // screen, and opens the scanner in one tap.
            Button {
                helpRoute = .none
                showScanner = true
                TelemetryManager.shared.track(.helpScanQrTapped)  // CL33
            } label: {
                Label("Scan QR", systemImage: "qrcode.viewfinder")
                    .font(AppFonts.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
            }
            .buttonStyle(.plain)

            ChatWithFounderCallout(caption: "That didn't help? Chat with founder.", source: "setup_other_device")

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
                    .font(AppFonts.sans(11, weight: .bold))
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
                    .font(AppFonts.sans(11, weight: .regular))
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

    private func helpButton(title: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFonts.button)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 60)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// A quiet secondary "Back" used to step BACK one sub-question inside the
    /// fresh-install branch (agent ← messaging ← command), distinct from the
    /// white filled `helpBackToMenuButton` that jumps to the 3-option menu.
    private func helpSecondaryBack(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFonts.button)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.button)
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
                        .font(AppFonts.sans(24, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .frame(width: 38, height: 54)
            }
        }
    }
}
