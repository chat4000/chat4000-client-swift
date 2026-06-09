import SwiftUI

struct ConnectingView: View {
    let connectionState: ConnectionState
    var onBack: () -> Void

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(AppFonts.label)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Spacer()

                VStack(spacing: 24) {
                    statusIcon

                    VStack(spacing: 12) {
                        Text(statusTitle)
                            .font(AppFonts.navTitle)
                            .foregroundStyle(AppColors.textPrimary)
                            .multilineTextAlignment(.center)

                        if !statusSubtitle.isEmpty {
                            Text(statusSubtitle)
                                .font(AppFonts.subtitle)
                                .foregroundStyle(AppColors.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    if case .failed(let message) = connectionState {
                        Text(message)
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.error)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(AppColors.errorBackground)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState {
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(AppColors.disconnected)
        case .connecting, .reconnecting, .connected, .disconnected:
            ProgressView()
                .controlSize(.large)
                .tint(AppColors.textSecondary)
        }
    }

    private var statusTitle: String {
        switch connectionState {
        case .failed:
            return "Connection Failed"
        case .reconnecting:
            return "Reconnecting..."
        default:
            return "Connecting..."
        }
    }

    private var statusSubtitle: String {
        switch connectionState {
        case .failed:
            return "Check the pair key and relay connection, then try again."
        case .reconnecting:
            return "Trying to restore the relay connection."
        default:
            return "Establishing a secure relay session."
        }
    }
}

struct Chat4000ConnectingScreen: View {
    let connectionState: ConnectionState

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.textSecondary)

                Text("chat4000 connecting")
                    .font(AppFonts.navTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
    }

    private var subtitle: String {
        switch connectionState {
        case .reconnecting:
            return "Restoring your relay session."
        default:
            return "Opening your workspace."
        }
    }
}

struct SetupProgressScreen: View {
    let phase: MatrixSession.SetupPhase

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            SetupProgressView(phase: phase)
                .padding(.horizontal, 12)
        }
    }
}

struct ConnectedCelebrationScreen: View {
    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            ConfettiView(intensity: 0.2)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            ConnectedCelebrationCard()
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }
}

#Preview {
    ConnectingView(
        connectionState: .connecting,
        onBack: {}
    )
}
