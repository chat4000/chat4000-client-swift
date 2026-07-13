#if os(iOS)
import SwiftUI

struct OnboardingFlowView: View {
    @Bindable var manager: OnboardingManager
    let onComplete: () -> Void
    @State private var selectedTextOption: OnboardingManager.PollOption?
    @State private var textAnswer = ""
    @State private var showFounderModal = false

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
        .sheet(isPresented: $showFounderModal, onDismiss: finish) {
            FounderChatPromptModal(source: "onboarding_neither")
                .presentationBackground(AppColors.background)
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
                case .pollAgent:
                    agentPollStep
                case .pollExpected:
                    pollStep(
                        icon: "questionmark.bubble.fill",
                        question: manager.expectedQuestion,
                        submit: manager.answerExpected(option:text:)
                    )
                case .interviewOffer:
                    interviewOffer
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(maxWidth: 390)
    }

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

    private var agentPollStep: some View {
        VStack(spacing: 18) {
            stepIcon("desktopcomputer")
            stepText(title: "Do you have OpenClaw, Hermes, or neither?", body: nil)
            optionButton("OpenClaw") { manager.answerAgent(answerId: "openclaw") }
            optionButton("Hermes") { manager.answerAgent(answerId: "hermes") }
            optionButton("Neither") { manager.answerAgent(answerId: "neither") }
        }
    }

    private var interviewOffer: some View {
        VStack(spacing: 18) {
            stepIcon("person.bubble.fill")
            stepText(
                title: "Right now chat4000 is only for OpenClaw and Hermes users — but the founder would love to interview you.",
                body: nil
            )
            primaryButton("Contact the founder", systemImage: "message.fill") {
                showFounderModal = true
            }
            Button(action: finish) {
                Text("No thanks")
                    .font(AppFonts.button)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func pollStep(
        icon: String,
        question: OnboardingManager.PollQuestion,
        submit: @escaping (OnboardingManager.PollOption, String?) -> Void
    ) -> some View {
        VStack(spacing: 18) {
            stepIcon(icon)
            stepText(title: question.title, body: nil)
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
    }

    private func textEntry(
        option: OnboardingManager.PollOption,
        submit: @escaping (OnboardingManager.PollOption, String?) -> Void
    ) -> some View {
        VStack(spacing: 12) {
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
            primaryButton("Continue", systemImage: "arrow.right") {
                submit(option, textAnswer)
                selectedTextOption = nil
                textAnswer = ""
            }
            .disabled(textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingManager.Step.allCases, id: \.self) { dotStep in
                Circle()
                    .fill(dotStep == manager.step ? Color.white : Color.white.opacity(0.18))
                    .frame(width: dotStep == manager.step ? 8 : 6, height: dotStep == manager.step ? 8 : 6)
            }
        }
        .frame(height: 12)
    }

    private func stepIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(AppColors.textPrimary)
            .frame(width: 60, height: 60)
    }

    private func stepText(title: String, body: String?) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("\(number)")
                .font(AppFonts.label)
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Color.white)
                .clipShape(Circle())
            Text(text)
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textPrimary)
        }
    }

    private func optionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(AppFonts.button)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    private func finish() {
        manager.complete()
        onComplete()
    }
}
#endif
