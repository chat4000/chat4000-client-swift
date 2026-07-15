#if os(iOS)
import SwiftUI
import UIKit

struct OnboardingFlowView: View {
    @Bindable var manager: OnboardingManager
    let onComplete: () -> Void
    /// Pairing submit for the connect windows (W4/W6/W7) — the app's join handler.
    var onSubmit: (String) -> Void = { _ in }
    var errorMessage: String?

    @State private var selectedTextOption: OnboardingManager.PollOption?
    @State private var textAnswer = ""
    /// Drives the text field's keyboard. Picking a free-text option ("Something
    /// else") auto-raises the keyboard — no second tap on the field needed.
    @FocusState private var textFieldFocused: Bool
    /// Shared by the embedded PairingEntryView across the connect windows (only one
    /// shows at a time), so the scanner presents from whichever window is up.
    @State private var showPairingScanner = false

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

            VStack {
                Spacer(minLength: 24)
                content
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
                Spacer(minLength: 24)
            }
        }
        .onAppear { manager.start() }
        // Dismiss signal — used by the QA preview cover; the real flow is dismissed
        // by the app routing away once pairing succeeds.
        .onChange(of: manager.isComplete) { _, done in
            if done { onComplete() }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 22) {
            progressDots
            Group {
                switch manager.step {
                case .notifExplainer:
                    notificationExplainer
                case .notifBlocked:
                    notificationBlocked
                case .pollSource:
                    pollStep(
                        icon: "sparkles",
                        question: manager.sourceQuestion,
                        submit: manager.answerSource(option:text:)
                    )
                case .connectHub:
                    connectHub
                case .connectDevice:
                    connectDevice
                case .installChooser:
                    installChooser
                case .installChat:
                    installCommandWindow(method: .chat)
                case .installSSH:
                    installCommandWindow(method: .ssh)
                case .pollExpected:
                    pollStep(
                        icon: "questionmark.bubble.fill",
                        question: manager.expectedQuestion,
                        submit: manager.answerExpected(option:text:)
                    )
                case .teamOffer:
                    teamOffer
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(maxWidth: 390)
    }

    // MARK: - Phase 0 — Notifications

    private var notificationExplainer: some View {
        VStack(spacing: 18) {
            stepIcon("bell.badge.fill")
            stepText(
                title: "Turn on notifications",
                body: "Replies arrive as notifications, so chat4000 needs them before you pair this device."
            )
            primaryButton("Enable notifications", systemImage: "bell.fill") {
                manager.enableNotifications()
            }
        }
    }

    private var notificationBlocked: some View {
        VStack(spacing: 18) {
            stepIcon("bell.slash.fill")
            stepText(
                title: "Hey, I just noticed you didn't turn it on. Can't use the app without it",
                body: nil
            )

            VStack(alignment: .leading, spacing: 10) {
                settingsStep(number: 1, text: "Open Settings")
                settingsStep(number: 2, text: "Notifications")
                settingsStep(number: 3, text: "Allow Notifications")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            primaryButton("Open Settings", systemImage: "gearshape.fill") {
                manager.openSettings()
            }
        }
    }

    // MARK: - Phase 2 — Connection (W3-W9)

    /// W3 — the hub. On a Disconnect re-entry (`limitedHub`) only the two "I already
    /// have a way in" options show.
    private var connectHub: some View {
        VStack(spacing: 16) {
            stepIcon("point.3.filled.connected.trianglepath.dotted")
            stepText(title: "Let's connect you", body: "Where are you starting from?")
            optionButton("I have chat4000 on another device") {
                manager.chooseConnect(.otherDevice)
            }
            agentOptionButton("I have OpenClaw or Hermes, but not chat4000") {
                manager.chooseConnect(.hasAgent)
            }
            if !manager.limitedHub {
                optionButton("I have none of these yet") {
                    manager.chooseConnect(.neither)
                }
                optionButton("I don't know what any of this is") {
                    manager.chooseConnect(.dontKnow)
                }
            }
        }
    }

    /// W4 — pair from a device already signed in.
    private var connectDevice: some View {
        VStack(spacing: 16) {
            backHeader("Add from another device")
            VStack(spacing: 12) {
                instructionRow(1, "Open chat4000 on your other device", "The phone or Mac already signed in.")
                instructionRow(2, "Go to Settings → Add Device", "It shows a QR code and a 6-digit code.")
                instructionRow(3, "Scan or enter it here", "Use the field below.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            pairingEntry
        }
    }

    /// W5 — how do you want to install the plugin?
    private var installChooser: some View {
        VStack(spacing: 16) {
            backHeader("Install the plugin")
            stepText(
                title: nil,
                body: "You need the chat4000 plugin on your server. Install it by pasting a command into the chat with your agent, or by SSHing into the machine — or just run it right there if this is the machine."
            )
            agentOptionButton("I already chat with my agent (Telegram, WhatsApp…)") {
                manager.chooseInstall(.chat)
            }
            optionButton("I'll install over SSH / on the machine") {
                manager.chooseInstall(.ssh)
            }
        }
    }

    /// W6 / W7 — the install command + pairing entry. `chat` shows the website's
    /// `# run script pls` tail (so the agent runs it in chat); `ssh` shows the plain
    /// one-liner you run yourself.
    private func installCommandWindow(method: OnboardingManager.InstallMethod) -> some View {
        VStack(spacing: 14) {
            backHeader(method == .chat ? "Paste into your agent chat" : "Run it on the machine")
            CommandCard(
                command: method == .chat
                    ? EnterPairingCodeView.installCommandForAgent
                    : EnterPairingCodeView.installCommand
            )
            stepText(
                title: nil,
                body: method == .chat
                    ? "Send it to your agent — it may take a couple of minutes to come up, then it replies with a single-use 6-digit code."
                    : "SSH in (or run it right there if this is the machine). It prints a single-use 6-digit code."
            )
            pairingEntry
            ChatWithFounderCallout(
                caption: "Stuck? Chat with the team.",
                source: method == .chat ? "onboarding_install_chat" : "onboarding_install_ssh"
            )
        }
    }

    /// W9 — no agent yet: the team would love to talk.
    private var teamOffer: some View {
        VStack(spacing: 18) {
            backHeader(nil)
            stepIcon("bird.fill")
            stepText(
                title: "The team would love to chat",
                body: "Tell us what you're building — we'll see if we can help you get set up."
            )
            primaryButton("Talk to the team", systemImage: "message.fill") {
                let channel = FounderOutreach.contactFounder(
                    message: nil,
                    disableWhatsApp: false,
                    disableTelegram: false,
                    source: "onboarding_team"
                )
                TelemetryManager.shared.track(
                    .founderChatPromptAction,
                    properties: ["source": "onboarding_team", "action": "chat_now", "channel": channel.rawValue]
                )
            }
        }
    }

    /// The shared pairing entry embedded in the connect windows.
    private var pairingEntry: some View {
        PairingEntryView(
            errorMessage: errorMessage,
            onSubmit: onSubmit,
            showScanner: $showPairingScanner
        )
    }

    // MARK: - Polls (source + expected)

    private func pollStep(
        icon: String,
        question: OnboardingManager.PollQuestion?,
        submit: @escaping (OnboardingManager.PollOption, String?) -> Void
    ) -> some View {
        VStack(spacing: 18) {
            stepIcon(icon)
            if let question {
                pollOptions(question: question, submit: submit)
            } else {
                // Options are ALWAYS registrar-served (RG10) — the app ships no
                // bundled list. The manager keeps retrying the fetch and auto-skips
                // this step if the config never loads.
                stepText(title: "One second…", body: "Loading questions")
                ProgressView()
                    .tint(AppColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func pollOptions(
        question: OnboardingManager.PollQuestion,
        submit: @escaping (OnboardingManager.PollOption, String?) -> Void
    ) -> some View {
        stepText(title: question.title, body: question.subtitle)
        ForEach(question.options) { option in
            if selectedTextOption?.id == option.id {
                textEntry(option: option, submit: submit)
            } else {
                optionButton(option.label) {
                    if option.isText {
                        selectedTextOption = option
                        textAnswer = ""
                    } else {
                        submit(option, nil)
                        selectedTextOption = nil
                    }
                }
            }
        }
    }

    private func textEntry(
        option: OnboardingManager.PollOption,
        submit: @escaping (OnboardingManager.PollOption, String?) -> Void
    ) -> some View {
        let submitText = {
            let trimmed = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            submit(option, textAnswer)
            selectedTextOption = nil
            textAnswer = ""
        }
        return VStack(spacing: 12) {
            TextField(option.label, text: $textAnswer)
                .font(AppFonts.input)
                .foregroundStyle(AppColors.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(AppColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.inputBorder, lineWidth: 1)
                )
                .focused($textFieldFocused)
                // Selecting a free-text option swaps this view in — raise the
                // keyboard immediately so the user can type without a second tap.
                .onAppear { textFieldFocused = true }
                // The Continue button can sit under the keyboard on short screens —
                // make the keyboard's return key submit too.
                .submitLabel(.done)
                .onSubmit(submitText)
            primaryButton("Continue", systemImage: "arrow.right", action: submitText)
                .disabled(textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Shared widgets

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<manager.progressTotal, id: \.self) { i in
                Circle()
                    .fill(i == manager.progressPhase ? Color.white : Color.white.opacity(0.18))
                    .frame(width: i == manager.progressPhase ? 8 : 6, height: i == manager.progressPhase ? 8 : 6)
            }
        }
        .frame(height: 12)
        .animation(.easeInOut(duration: 0.2), value: manager.progressPhase)
    }

    private func stepIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(AppColors.textPrimary)
            .frame(width: 60, height: 60)
    }

    private func stepText(title: String?, body: String?) -> some View {
        VStack(spacing: 10) {
            if let title {
                Text(title)
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body {
                Text(body)
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsStep(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            numberBadge(number)
            Text(text)
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textPrimary)
        }
    }

    private func instructionRow(_ number: Int, _ title: String, _ hint: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            numberBadge(number)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFonts.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(AppFonts.label)
            .foregroundStyle(.black)
            .frame(width: 24, height: 24)
            .background(Color.white)
            .clipShape(Circle())
    }

    private func backHeader(_ title: String?) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    Haptics.impact()
                    manager.goBack()
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
            if let title {
                Text(title)
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The card chrome shared by every option button (one source of the styling).
    private func cardButton<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            Haptics.impact()
            action()
        } label: {
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func optionButton(
        _ title: String,
        glyph: String? = nil,
        glyphScale: CGFloat = 1.0,
        action: @escaping () -> Void
    ) -> some View {
        cardButton(action: action) {
            HStack(spacing: 10) {
                if let glyph {
                    Text(glyph)
                        .font(.system(size: 20 * glyphScale))
                        .frame(width: 26, alignment: .center)
                }
                Text(title)
                    .font(AppFonts.button)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    /// An option that names the agents in text, with 🦞 OpenClaw / ☤ Hermes icons
    /// AFTER the text (Hermes sized to the cap height — see `AgentGlyphs`).
    private func agentOptionButton(_ title: String, action: @escaping () -> Void) -> some View {
        cardButton(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppFonts.button)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                AgentGlyphs()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(AppFonts.button)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

/// 🦞 OpenClaw then ☤ Hermes, shown after a label. The caduceus sits small in its
/// em box, so it is scaled up and nudged down so its TOP reaches the cap height of
/// adjacent text (matching chat4000.com's header). Reused wherever both agents are
/// referenced together.
struct AgentGlyphs: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("🦞").font(.system(size: 19))
            Text("☤").font(.system(size: 25)).baselineOffset(-3)
        }
        .accessibilityLabel("OpenClaw and Hermes")
    }
}

/// A read-only command block with a Copy button. Reused by the install windows.
struct CommandCard: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            Text(command)
                .font(AppFonts.sans(11, weight: .regular))
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

            Button {
                Haptics.success()
                UIPasteboard.general.string = command
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                    Text(copied ? "Copied" : "Copy command")
                        .font(AppFonts.button)
                }
                .foregroundStyle(copied ? AppColors.connected : AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
