import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

private let cliSpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
private let cliThinkingHints = ["Thinking", "Planning", "Tracing", "Checking", "Exploring", "Reasoning"]
private let cliTypingHints = ["Typing", "Drafting", "Shaping", "Answering"]

private enum VoiceRecordingSource: String {
    case inputBar = "input_bar"
    case launchAction = "launch_action"
}

struct ChatView: View {
    private static let defaultMacComposerHeight: CGFloat = 35

    @Environment(\.scenePhase) private var scenePhase
    @Bindable var viewModel: ChatViewModel
    var onAddDevice: () -> Void
    @State private var messageText = ""
    @State private var showSettings = false
    @State private var showCamera = false
    @State private var voiceRecorder = VoiceNoteRecorder()
    @State private var voiceErrorMessage: String?
    @FocusState private var inputFocused: Bool
    @State private var hasPrimedInitialFocus = false
    @State private var isHandlingLaunchAction = false
    @State private var pendingLaunchActionTask: Task<Void, Never>?
    @State private var activeRecordingSource: VoiceRecordingSource = .inputBar
    @State private var macComposerHeight: CGFloat = ChatView.defaultMacComposerHeight
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var versionPolicy = VersionPolicyManager.shared
    private let macComposerMaxHeight: CGFloat = 210

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                navBar

                if versionPolicy.showNag,
                   case .softNag(let recommended, _) = versionPolicy.action {
                    UpgradeRecommendedBanner(recommendedVersion: recommended) {
                        versionPolicy.dismissNag()
                    }
                }

                // Messages and busy indicators live inside the scroll view so
                // they flow with content and don't resize the scroll area when
                // they appear/disappear.
                ScrollViewReader { proxy in
                    ScrollView {
                        messageListContent
                        .padding(.vertical, AppSpacing.chatListVerticalInset)
                        .contentShape(Rectangle())
                        .textSelection(.enabled)
                    }
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        dismissKeyboard()
                    }
                    #endif
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            scrollToBottom(using: proxy)
                        }
                    }
                    .onChange(of: viewModel.messages.count) {
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.scrollRevision) {
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.isAgentBusy) {
                        scrollToBottom(using: proxy)
                    }
                }

                if let voiceErrorMessage {
                    errorBanner(voiceErrorMessage)
                }

                if let pluginUpdateWarning = viewModel.pluginUpdateWarning {
                    errorBanner(pluginUpdateWarning)
                }

                inputBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                config: viewModel.config,
                pluginVersion: viewModel.lastSeenPluginVersion,
                pluginBundleId: viewModel.lastSeenPluginBundleId,
                onAddDevice: onAddDevice,
                onDisconnect: viewModel.disconnect,
                onClearHistory: viewModel.clearHistory
            )
            #if os(macOS)
            .presentationDetents([.height(700)])
            #else
            .presentationDetents([.fraction(0.75)])
            #endif
            .presentationDragIndicator(.visible)
            .presentationBackground(AppColors.cardBackground)
        }
        .onChange(of: showSettings) { _, isPresented in
            if isPresented {
                TelemetryManager.shared.screen("settings")
                TelemetryManager.shared.track(.settingsOpened)
            }
            guard !isPresented else { return }
            Task { @MainActor in
                Haptics.impact()
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                viewModel.sendImage(image)
            }
            .ignoresSafeArea()
        }
        #endif
        .onAppear {
            primeInitialFocus()
            handlePendingLaunchActionIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handlePendingLaunchActionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchActionStore.didSetNotification)) { _ in
            handlePendingLaunchActionIfNeeded()
        }
        .onDisappear {
            pendingLaunchActionTask?.cancel()
            pendingLaunchActionTask = nil
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack {
            Spacer()

            Button {
                Task { @MainActor in
                    Haptics.impact()
                }
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 28, height: 28)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        #if os(iOS)
        .padding(.top, -15)
        .padding(.bottom, AppSpacing.navBarBottomInset)
        #else
        .padding(.top, -12)
        .padding(.bottom, AppSpacing.navBarBottomInset)
        #endif
    }

    // MARK: - Busy Indicator

    private var busyIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let spinnerIndex = Int(context.date.timeIntervalSinceReferenceDate * 12) % cliSpinnerFrames.count
            let spinner = cliSpinnerFrames[spinnerIndex]
            let hints = busyHints(for: viewModel.busyPhase)
            let hintIndex = Int(context.date.timeIntervalSinceReferenceDate / 2) % hints.count
            let hint = hints[hintIndex]

            HStack(spacing: 8) {
                Text(spinner)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)

                if let start = viewModel.busyStartTime {
                    let elapsed = max(Int(context.date.timeIntervalSince(start)), 0)
                    Text("\(elapsed)s")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppColors.textTimestamp)
                        .monospacedDigit()
                }

                Text(hint)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppColors.background)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAgentBusy)
    }

    private func busyHints(for phase: String) -> [String] {
        switch phase.lowercased() {
        case "typing":
            return cliTypingHints
        default:
            return cliThinkingHints
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        DevLog.log(
            "↕️ scrollToBottom messages=%d revision=%d busy=%@ phase=%@",
            viewModel.messages.count,
            viewModel.scrollRevision,
            viewModel.isAgentBusy ? "true" : "false",
            viewModel.busyPhase
        )
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            #if os(iOS)
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            DevLog.log("↕️ scrollToBottom delayed follow-up")
            proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            #else
            DevLog.log("↕️ scrollToBottom async follow-up")
            proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            #endif
        }
    }

    @ViewBuilder
    private var messageListContent: some View {
        #if os(iOS)
        VStack(spacing: AppSpacing.messageGap) {
            messageListRows
        }
        #else
        LazyVStack(spacing: AppSpacing.messageGap) {
            messageListRows
        }
        #endif
    }

    @ViewBuilder
    private var messageListRows: some View {
        ForEach(viewModel.messages, id: \.id) { message in
            MessageBubble(message: message)
                .id(message.id)
        }

        if viewModel.isAgentBusy {
            busyIndicator
                .id("busyIndicator")
        }

        Color.clear
            .frame(height: 1)
            .id("chatBottomAnchor")
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.caption)
            .foregroundStyle(AppColors.error)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.errorBackground)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppColors.inputBorder)

            if voiceRecorder.isRecording {
                recordingInputBar
            } else {
                textInputBar
            }
        }
        .background(AppColors.background)
    }

    #if os(iOS)
    private let accessoryButtonSize: CGFloat = 42
    private let accessoryButtonGap: CGFloat = 12
    private var accessoryAreaWidth: CGFloat {
        if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (accessoryButtonSize * 2) + accessoryButtonGap
        }
        return accessoryButtonSize
    }
    #else
    private let accessoryButtonSize: CGFloat = ChatView.defaultMacComposerHeight
    #endif

    private var textInputBar: some View {
        HStack(spacing: 12) {
            composerInput

            trailingAccessoryArea
        }
        .padding(.horizontal, AppSpacing.messageRowInset)
        .padding(.vertical, AppSpacing.inputBarBottomInset)
        .animation(.easeInOut(duration: 0.2), value: messageText.isEmpty)
    }

    @ViewBuilder
    private var trailingAccessoryArea: some View {
        #if os(iOS)
        ZStack(alignment: .trailing) {
            if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: accessoryButtonGap) {
                    circleAccessoryButton(symbol: "camera.fill") {
                        Haptics.impact()
                        showCamera = true
                    }

                    circleAccessoryButton(symbol: "mic.fill") {
                        Haptics.impact()
                        Task { await toggleVoiceRecording() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                sendAccessoryButton
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: accessoryAreaWidth, alignment: .trailing)
        #else
        if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            circleAccessoryButton(symbol: "mic.fill") {
                Haptics.impact()
                Task { await toggleVoiceRecording() }
            }
        } else {
            sendAccessoryButton
                .transition(.scale.combined(with: .opacity))
        }
        #endif
    }

    private func circleAccessoryButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: accessoryButtonSize, height: accessoryButtonSize)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(AppColors.inputBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var sendAccessoryButton: some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: accessoryButtonSize, height: accessoryButtonSize)
                .background(Color.white)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var composerInput: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
                MacComposerTextView(
                    text: $messageText,
                    height: $macComposerHeight,
                    minHeight: MacComposerTextView.minimumHeight,
                    maxHeight: macComposerMaxHeight,
                    onSubmit: sendMessage,
                    onTextChange: { _ in }
                )

            if messageText.isEmpty {
                Text("Message ...")
                    .font(AppFonts.input)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: macComposerHeight)
        .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    Haptics.impact()
                    inputFocused = true
                }
            )
        #else
        TextField("Message ...", text: $messageText, axis: .vertical)
            .font(AppFonts.input)
            .foregroundStyle(AppColors.textPrimary)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .lineLimit(1...5)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )
            .onSubmit {
                sendMessage()
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    Haptics.impact()
                    inputFocused = true
                }
            )
        #endif
    }

    private var recordingInputBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.impact()
                voiceRecorder.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppColors.inputBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let blinkOn = Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
                    Circle()
                        .fill(AppColors.error)
                        .frame(width: 10, height: 10)
                        .opacity(blinkOn ? 1 : 0.2)
                }

                VoiceWaveformView(
                    samples: voiceRecorder.liveWaveform,
                    progress: 1,
                    activeColor: AppColors.error,
                    inactiveColor: AppColors.textTimestamp.opacity(0.35),
                    minimumHeight: 7,
                    maximumHeight: 26
                )
                .frame(height: 32)

                Text(VoiceNoteFormatter.recordingDurationText(voiceRecorder.duration))
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )

            Button {
                Haptics.impact()
                Task { await stopVoiceRecording() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.messageRowInset)
        .padding(.vertical, AppSpacing.inputBarBottomInset)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        Haptics.impact()
        viewModel.send(text: text)
        messageText = ""
    }

    private func dismissKeyboard() {
        guard inputFocused else { return }
        Haptics.impact()
        inputFocused = false
    }

    private func toggleVoiceRecording() async {
        activeRecordingSource = .inputBar
        dismissKeyboardIfNeeded()
        voiceErrorMessage = nil

        do {
            try await voiceRecorder.start()
            TelemetryManager.shared.track(
                .voiceRecordingStarted,
                properties: ["source": activeRecordingSource.rawValue]
            )
        } catch {
            voiceErrorMessage = error.localizedDescription
            TelemetryManager.shared.track(
                .voiceRecordingFailed,
                properties: [
                    "reason": error.localizedDescription,
                    "source": activeRecordingSource.rawValue,
                ]
            )
            Haptics.error()
        }
    }

    private func startVoiceRecordingFromLaunchAction() async {
        guard !voiceRecorder.isRecording else { return }
        DevLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction begin")
        activeRecordingSource = .launchAction
        messageText = ""
        dismissKeyboardIfNeeded()
        voiceErrorMessage = nil

        do {
            try await voiceRecorder.start()
            DevLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction success")
            TelemetryManager.shared.track(
                .actionButtonRecordingTriggered,
                properties: ["entry": "foreground_continue"]
            )
            TelemetryManager.shared.track(
                .voiceRecordingStarted,
                properties: ["source": activeRecordingSource.rawValue]
            )
        } catch {
            DevLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction error=%@", error.localizedDescription)
            voiceErrorMessage = error.localizedDescription
            TelemetryManager.shared.track(
                .voiceRecordingFailed,
                properties: [
                    "reason": error.localizedDescription,
                    "source": activeRecordingSource.rawValue,
                ]
            )
            Haptics.error()
        }
    }

    private func stopVoiceRecording() async {
        guard let clip = await voiceRecorder.stop() else {
            voiceErrorMessage = "Recording failed. Try again."
            Haptics.error()
            return
        }

        let recordingSource = activeRecordingSource
        viewModel.sendAudio(
            clip.data,
            mimeType: clip.mimeType,
            duration: clip.duration,
            waveform: clip.waveform,
            source: recordingSource.rawValue
        )
        TelemetryManager.shared.track(
            .voiceRecordingFinished,
            properties: [
                "source": recordingSource.rawValue,
                "duration_bucket": AnalyticsBuckets.durationBucket(for: clip.duration),
            ]
        )
        activeRecordingSource = .inputBar
        clip.removeLocalFile()
    }

    private func dismissKeyboardIfNeeded() {
        guard inputFocused else { return }
        inputFocused = false
    }

    private func primeInitialFocus() {
        guard !hasPrimedInitialFocus, !voiceRecorder.isRecording else { return }
        hasPrimedInitialFocus = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            inputFocused = true
        }
    }

    private func handlePendingLaunchActionIfNeeded() {
        guard !isHandlingLaunchAction else { return }
        DevLog.log("🎯 ChatView.handlePendingLaunchActionIfNeeded check")

        pendingLaunchActionTask?.cancel()
        pendingLaunchActionTask = Task { @MainActor in
            for attempt in 0..<6 {
                DevLog.log("🎯 ChatView.handlePendingLaunchActionIfNeeded attempt=%d", attempt)
                if let action = LaunchActionStore.consume() {
                    isHandlingLaunchAction = true
                    defer { isHandlingLaunchAction = false }

                    switch action {
                    case .startVoiceRecording:
                        await startVoiceRecordingFromLaunchAction()
                    }
                    return
                }

                if attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }
}

#if os(macOS)
private struct MacComposerTextView: NSViewRepresentable {
    private static let composerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 10
    private static let placeholderProbe = NSString(string: "Message ...")
    private static let singleLineTextHeight: CGFloat = ceil(
        placeholderProbe.size(withAttributes: [.font: composerFont]).height
    )
    static let minimumHeight: CGFloat = ceil(singleLineTextHeight + (verticalInset * 2))

    @Binding var text: String
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = Self.composerFont
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: Self.horizontalInset, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = onSubmit

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onSubmit = onSubmit

        if textView.string != text {
            textView.string = text
        }

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(_ parent: MacComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange(textView.string)
            recalculateHeight()
        }

        @MainActor
        func recalculateHeight() {
            guard let textView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)

            let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? parent.minHeight
            let verticalPadding = MacComposerTextView.verticalInset * 2
            let nextHeight = min(parent.maxHeight, max(parent.minHeight, ceil(usedHeight + verticalPadding)))

            if abs(parent.height - nextHeight) > 0.5 {
                parent.height = nextHeight
            }

            scrollView?.hasVerticalScroller = nextHeight >= parent.maxHeight
        }
    }

    final class ComposerNSTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if isReturn {
                if modifiers.contains(.shift) || modifiers.contains(.option) {
                    insertNewlineIgnoringFieldEditor(self)
                } else {
                    onSubmit?()
                }
                return
            }

            super.keyDown(with: event)
        }
    }
}
#endif

// MARK: - View Model

@MainActor
@Observable
final class ChatViewModel {
    private enum PluginMetadataStore {
        private static let versionPrefix = "chat94.plugin-version"
        private static let bundlePrefix = "chat94.plugin-bundle-id"

        static func load(groupId: String) -> (version: String?, bundleId: String?) {
            let defaults = UserDefaults.standard
            return (
                defaults.string(forKey: "\(versionPrefix).\(groupId)"),
                defaults.string(forKey: "\(bundlePrefix).\(groupId)")
            )
        }

        static func save(version: String?, bundleId: String?, groupId: String) {
            let defaults = UserDefaults.standard

            if let version, !version.isEmpty {
                defaults.set(version, forKey: "\(versionPrefix).\(groupId)")
            }

            if let bundleId, !bundleId.isEmpty {
                defaults.set(bundleId, forKey: "\(bundlePrefix).\(groupId)")
            }
        }
    }

    var messages: [ChatMessage] = []
    var connectionState: ConnectionState = .disconnected
    var isAgentBusy = false
    var busyStartTime: Date?
    var busyPhase: String = "Thinking"
    var pluginUpdateWarning: String?
    var lastSeenPluginVersion: String?
    var lastSeenPluginBundleId: String?
    var config: GroupConfig?
    var scrollRevision = 0

    private let relay = RelayClient()
    private var modelContext: ModelContext?
    private let minimumPluginVersion = "0.1.0"
    private var statePollingTask: Task<Void, Never>?

    // Tracks current streaming message being assembled
    private var currentStreamId: String?
    private var currentStreamText = ""
    private var currentStreamMessageId: UUID?

    var onTermsVersionUpdate: ((Int) -> Void)?

    private func requestScrollToBottom() {
        scrollRevision &+= 1
        DevLog.log("↕️ requestScrollToBottom revision=%d messages=%d", scrollRevision, messages.count)
    }

    init() {
        relay.onInnerMessage = { [weak self] inner in
            self?.handleInnerMessage(inner)
        }
        relay.onTermsVersionUpdate = { [weak self] currentTermsVersion in
            self?.onTermsVersionUpdate?(currentTermsVersion)
        }
    }

    func attach(modelContext: ModelContext) {
        let isFirstAttachment = self.modelContext == nil
        self.modelContext = modelContext

        if isFirstAttachment || !messages.isEmpty {
            loadMessagesMergingTransientState()
        }

        Task { @MainActor in
            importPendingIncomingMessagesIfNeeded()
        }
    }

    func setup(modelContext: ModelContext, config: GroupConfig) {
        attach(modelContext: modelContext)
        self.config = config
        loadStoredPluginMetadata(for: config)
        loadMessagesMergingTransientState()
        if connectionState != .connected {
            startConnection(config: config)
        }
    }

    func refreshMessages() {
        guard modelContext != nil else { return }
        loadMessagesMergingTransientState()
        Task { @MainActor in
            importPendingIncomingMessagesIfNeeded()
        }
    }

    func startConnection(config: GroupConfig) {
        guard connectionState != .connected else { return }
        self.config = config
        loadStoredPluginMetadata(for: config)
        relay.connect(config: config)

        // Sync connection state from relay. Cancel any prior poller before
        // spawning a new one — backgrounding sets state to .disconnected, so
        // foregrounding always re-enters this function and would otherwise
        // stack a fresh infinite Task each cycle.
        statePollingTask?.cancel()
        statePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.connectionState = self.relay.state
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Busy state

    private func markBusy(phase: String) {
        if !isAgentBusy {
            isAgentBusy = true
            busyStartTime = .now
        }
        if busyPhase != phase {
            busyPhase = phase
        }
    }

    private func clearBusy() {
        if isAgentBusy {
            isAgentBusy = false
            busyStartTime = nil
        }
    }

    func disconnect() {
        statePollingTask?.cancel()
        statePollingTask = nil
        relay.disconnect()
        connectionState = .disconnected
        KeychainService.delete()
        config = nil
    }

    func disconnectRelayForBackground() {
        DevLog.log("🔌 Background disconnect: closing relay only")
        statePollingTask?.cancel()
        statePollingTask = nil
        relay.disconnect()
        connectionState = .disconnected
    }

    func send(text: String) {
        let message = ChatMessage(text: text, sender: .user, status: .sending)
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()

        relay.send(text: text)
        TelemetryManager.shared.track(
            .messageSentText,
            properties: [
                "source": "keyboard",
                "length_bucket": AnalyticsBuckets.lengthBucket(for: text),
            ]
        )
        message.status = .sent
        markBusy(phase: "Thinking")
    }

    func sendImage(_ image: PlatformImage) {
        guard let jpegData = image.clawConnectJPEGData else { return }

        let message = ChatMessage(imageData: jpegData, sender: .user, status: .sending)
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()

        relay.sendImage(jpegData: jpegData)
        TelemetryManager.shared.track(
            .messageSentImage,
            properties: [
                "source": "camera",
                "count": 1,
            ]
        )
        message.status = .sent
        markBusy(phase: "Thinking")
        Haptics.impact()
    }

    func sendAudio(_ audioData: Data, mimeType: String, duration: TimeInterval, waveform: [Float], source: String) {
        let message = ChatMessage(
            audioData: audioData,
            audioMimeType: mimeType,
            audioDuration: duration,
            audioWaveform: waveform,
            sender: .user,
            status: .sending
        )
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()

        relay.sendAudio(
            audioData: audioData,
            mimeType: mimeType,
            durationMs: Int((duration * 1000).rounded()),
            waveform: waveform
        )
        TelemetryManager.shared.track(
            .messageSentAudio,
            properties: [
                "source": source,
                "duration_bucket": AnalyticsBuckets.durationBucket(for: duration),
            ]
        )
        message.status = .sent
        markBusy(phase: "Thinking")
    }

    func clearHistory() {
        for message in messages {
            modelContext?.delete(message)
        }
        try? modelContext?.save()
        messages.removeAll()
        requestScrollToBottom()
    }

    // MARK: - Inner Message Handling

    private func handleInnerMessage(_ inner: InnerMessage) {
        rememberPluginMetadata(from: inner.from)
        updatePluginVersionWarning(from: inner.from)

        if let from = inner.from,
           from.role == .app,
           from.deviceId == DeviceIdentity.currentDeviceId {
            DevLog.log("📥 inner ignored self_echo type=%@ id=%@", inner.t.rawValue, inner.id)
            return
        }

        let sender = messageSender(for: inner)
        DevLog.log(
            "📥 inner dispatch type=%@ sender=%@ from_role=%@ status=%@ stream_id=%@",
            inner.t.rawValue,
            sender.rawValue,
            inner.from?.role.rawValue ?? "nil",
            inner.statusLabelForLogging,
            inner.id
        )

        switch inner.body {
        case .text(let b):
            receiveText(b.text, id: inner.id, sender: sender)
            if sender == .agent { clearBusy() }

        case .image(let b):
            receiveImage(dataBase64: b.dataBase64, sender: sender)
            if sender == .agent { clearBusy() }

        case .audio(let b):
            receiveAudio(
                dataBase64: b.dataBase64,
                mimeType: b.mimeType,
                durationMs: b.durationMs,
                waveform: b.waveform,
                sender: sender
            )
            if sender == .agent { clearBusy() }

        case .textDelta(let b):
            if currentStreamId != inner.id {
                beginStreamingMessage(streamId: inner.id, sender: sender)
            }
            currentStreamText += b.delta
            updateCurrentStreamingMessage(text: currentStreamText, sender: sender)
            if sender == .agent { markBusy(phase: "Typing") }

        case .textEnd(let b):
            if b.reset == true {
                cancelCurrentStreamingMessage(streamId: inner.id)
            } else if currentStreamId == inner.id {
                finalizeCurrentStreamingMessage(text: b.text, sender: sender)
            } else if currentStreamId == nil {
                receiveText(b.text, id: inner.id, sender: sender)
            }
            if sender == .agent { clearBusy() }

        case .status(let s):
            // Plugin's status signals from the agent side. `typing` is a per-delta
            // heartbeat during streaming — it is NOT "stop thinking". `idle` marks
            // the end of a reply. `thinking` re-enters across tool-use loops.
            if sender != .agent { break }
            switch s.status {
            case "thinking":
                markBusy(phase: "Thinking")
            case "typing":
                markBusy(phase: "Typing")
            case "idle":
                clearBusy()
            default:
                break
            }
        }
    }

    private func receiveText(_ text: String, id: String, sender: MessageSender) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Haptics.success()
        DevLog.log(
            "📥 receiveText id=%@ sender=%@ chars=%d",
            id,
            sender.rawValue,
            text.count
        )

        let message = ChatMessage(text: text, sender: sender)
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()
    }

    private func receiveImage(dataBase64: String, sender: MessageSender) {
        guard let imageData = Data(base64Encoded: dataBase64) else { return }
        Haptics.success()
        DevLog.log(
            "📥 receiveImage sender=%@ bytes=%d",
            sender.rawValue,
            imageData.count
        )

        let message = ChatMessage(imageData: imageData, sender: sender)
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()
    }

    private func receiveAudio(dataBase64: String, mimeType: String, durationMs: Int, waveform: [Float], sender: MessageSender) {
        guard let audioData = Data(base64Encoded: dataBase64) else { return }
        Haptics.success()
        DevLog.log(
            "📥 receiveAudio sender=%@ mime=%@ duration_ms=%d bytes=%d waveform=%d",
            sender.rawValue,
            mimeType,
            durationMs,
            audioData.count,
            waveform.count
        )

        let message = ChatMessage(
            audioData: audioData,
            audioMimeType: mimeType,
            audioDuration: Double(durationMs) / 1000,
            audioWaveform: waveform,
            sender: sender
        )
        messages.append(message)
        modelContext?.insert(message)
        try? modelContext?.save()
        requestScrollToBottom()
    }

    private func beginStreamingMessage(streamId: String, sender: MessageSender) {
        DevLog.log(
            "🧵 beginStreamingMessage stream_id=%@ sender=%@ existing_stream=%@",
            streamId,
            sender.rawValue,
            currentStreamId ?? "nil"
        )
        currentStreamId = streamId
        currentStreamText = ""

        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = ""
        } else {
            let message = ChatMessage(text: "", sender: sender, status: .sending)
            messages.append(message)
            modelContext?.insert(message)
            currentStreamMessageId = message.id
        }
        requestScrollToBottom()
    }

    private func updateCurrentStreamingMessage(text: String, sender: MessageSender) {
        DevLog.log(
            "🧵 updateStreamingMessage stream_id=%@ sender=%@ chars=%d",
            currentStreamId ?? "nil",
            sender.rawValue,
            text.count
        )
        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = text
        } else {
            let message = ChatMessage(text: text, sender: sender, status: .sending)
            messages.append(message)
            modelContext?.insert(message)
            currentStreamMessageId = message.id
        }
        requestScrollToBottom()
    }

    private func finalizeCurrentStreamingMessage(text: String, sender: MessageSender) {
        Haptics.success()
        DevLog.log(
            "🧵 finalizeStreamingMessage stream_id=%@ sender=%@ chars=%d",
            currentStreamId ?? "nil",
            sender.rawValue,
            text.count
        )

        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = text
            existing.status = .sent
        } else {
            let message = ChatMessage(text: text, sender: sender)
            messages.append(message)
            modelContext?.insert(message)
        }

        currentStreamId = nil
        currentStreamText = ""
        currentStreamMessageId = nil
        try? modelContext?.save()
        requestScrollToBottom()
    }

    private func cancelCurrentStreamingMessage(streamId: String) {
        DevLog.log("🧵 cancelStreamingMessage stream_id=%@ current=%@", streamId, currentStreamId ?? "nil")

        if currentStreamId == streamId, let existing = currentStreamingMessage() {
            withAnimation(.easeOut(duration: 0.2)) {
                if let index = messages.firstIndex(where: { $0.id == existing.id }) {
                    messages.remove(at: index)
                }
            }
            modelContext?.delete(existing)
            try? modelContext?.save()
        }

        if currentStreamId == streamId {
            currentStreamId = nil
            currentStreamText = ""
            currentStreamMessageId = nil
        }

        requestScrollToBottom()
    }

    private func currentStreamingMessage() -> ChatMessage? {
        guard let currentStreamMessageId else { return nil }
        return messages.first(where: { $0.id == currentStreamMessageId })
    }

    private func messageSender(for inner: InnerMessage) -> MessageSender {
        guard let from = inner.from else { return .agent }
        switch from.role {
        case .app:
            return .user
        case .plugin, .unknown:
            return .agent
        }
    }

    private func updatePluginVersionWarning(from sender: SenderInfo?) {
        guard let sender, sender.role == .plugin else { return }
        guard let version = sender.appVersion, !version.isEmpty else {
            pluginUpdateWarning = nil
            return
        }

        if Self.compareVersions(version, minimumPluginVersion) == .orderedAscending {
            let package = sender.bundleId ?? "plugin"
            pluginUpdateWarning = "Update \(package) to \(minimumPluginVersion) or newer."
        } else {
            pluginUpdateWarning = nil
        }
    }

    private func loadStoredPluginMetadata(for config: GroupConfig) {
        guard let groupId = config.groupId else {
            lastSeenPluginVersion = nil
            lastSeenPluginBundleId = nil
            return
        }

        let stored = PluginMetadataStore.load(groupId: groupId)
        lastSeenPluginVersion = stored.version
        lastSeenPluginBundleId = stored.bundleId
    }

    private func rememberPluginMetadata(from sender: SenderInfo?) {
        guard let sender, sender.role == .plugin else { return }
        guard let groupId = config?.groupId else { return }

        if let version = sender.appVersion, !version.isEmpty {
            lastSeenPluginVersion = version
        }

        if let bundleId = sender.bundleId, !bundleId.isEmpty {
            lastSeenPluginBundleId = bundleId
        }

        PluginMetadataStore.save(
            version: lastSeenPluginVersion,
            bundleId: lastSeenPluginBundleId,
            groupId: groupId
        )
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericVersionParts(lhs)
        let rhsParts = numericVersionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { part in
                let digits = part.prefix(while: { $0.isNumber })
                return Int(digits) ?? 0
            }
    }

    private func loadMessagesMergingTransientState() {
        let descriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let storedMessages = (try? modelContext?.fetch(descriptor)) ?? []
        let storedIds = Set(storedMessages.map(\.id))

        var mergedMessages = storedMessages
        for message in messages where !storedIds.contains(message.id) {
            modelContext?.insert(message)
            mergedMessages.append(message)
        }

        mergedMessages.sort { $0.timestamp < $1.timestamp }
        try? modelContext?.save()
        messages = mergedMessages
        requestScrollToBottom()
    }

    private func importPendingIncomingMessagesIfNeeded() {
        guard modelContext != nil else { return }

        Task { @MainActor in
            let pending = await PendingIncomingMessageStore.shared.drain()
            guard !pending.isEmpty else { return }

            DevLog.log("📬 importing pending incoming messages count=%ld", pending.count)

            for pendingMessage in pending {
                switch pendingMessage.payload {
                case .text(let text):
                    let message = ChatMessage(
                        text: text,
                        sender: .agent,
                        timestamp: pendingMessage.receivedAt,
                        status: .sent
                    )
                    messages.append(message)
                    modelContext?.insert(message)
                    DevLog.log(
                        "📬 imported pending text id=%@ chars=%ld",
                        pendingMessage.messageId,
                        text.count
                    )

                case .image(let dataBase64):
                    guard let imageData = Data(base64Encoded: dataBase64) else {
                        DevLog.log("ERROR: Failed to decode pending image id=%@", pendingMessage.messageId)
                        continue
                    }
                    let message = ChatMessage(
                        imageData: imageData,
                        sender: .agent,
                        timestamp: pendingMessage.receivedAt,
                        status: .sent
                    )
                    messages.append(message)
                    modelContext?.insert(message)
                    DevLog.log(
                        "📬 imported pending image id=%@ bytes=%ld",
                        pendingMessage.messageId,
                        imageData.count
                    )

                case .audio(let dataBase64, let mimeType, let durationMs, let waveform):
                    guard let audioData = Data(base64Encoded: dataBase64) else {
                        DevLog.log("ERROR: Failed to decode pending audio id=%@", pendingMessage.messageId)
                        continue
                    }
                    let message = ChatMessage(
                        audioData: audioData,
                        audioMimeType: mimeType,
                        audioDuration: Double(durationMs) / 1000,
                        audioWaveform: waveform,
                        sender: .agent,
                        timestamp: pendingMessage.receivedAt,
                        status: .sent
                    )
                    messages.append(message)
                    modelContext?.insert(message)
                    DevLog.log(
                        "📬 imported pending audio id=%@ bytes=%ld duration_ms=%ld",
                        pendingMessage.messageId,
                        audioData.count,
                        durationMs
                    )
                }
            }

            messages.sort { $0.timestamp < $1.timestamp }
            try? modelContext?.save()
            clearBusy()
            requestScrollToBottom()
        }
    }
}

private extension InnerMessage {
    var statusLabelForLogging: String {
        if case .status(let body) = self.body {
            return body.status
        }
        return "n/a"
    }
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

private extension PlatformImage {
    var clawConnectJPEGData: Data? {
        // Cap the produced JPEG so the resulting WebSocket frame
        // (≈ 1.78× after base64 + encrypt + base64) stays comfortably
        // under URLSessionWebSocketTask's maximumMessageSize.
        let maxBytes = 2 * 1024 * 1024
        let candidates: [(CGFloat, CGFloat)] = [
            (1600, 0.82),
            (1400, 0.78),
            (1200, 0.74),
            (1024, 0.70),
            (896, 0.66),
            (768, 0.62),
            (640, 0.58),
            (512, 0.54),
        ]

        for (maxDimension, quality) in candidates {
            if let data = encodedJPEGData(maxDimension: maxDimension, compressionQuality: quality),
               data.count <= maxBytes {
                return data
            }
        }
        return encodedJPEGData(maxDimension: 384, compressionQuality: 0.5)
    }

    func encodedJPEGData(maxDimension: CGFloat, compressionQuality: CGFloat) -> Data? {
        #if os(iOS)
        let size = self.size
        let scale = min(1, maxDimension / max(size.width, size.height))

        if scale < 1 {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale))
            let resized = renderer.image { _ in
                self.draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            }
            return resized.jpegData(compressionQuality: compressionQuality)
        }

        return self.jpegData(compressionQuality: compressionQuality)
        #elseif os(macOS)
        let size = self.size
        let scale = min(1, maxDimension / max(size.width, size.height))

        let sourceImage: NSImage
        if scale < 1 {
            let resized = NSImage(size: CGSize(width: size.width * scale, height: size.height * scale))
            resized.lockFocus()
            self.draw(
                in: NSRect(origin: .zero, size: resized.size),
                from: NSRect(origin: .zero, size: size),
                operation: .copy,
                fraction: 1
            )
            resized.unlockFocus()
            sourceImage = resized
        } else {
            sourceImage = self
        }

        guard let tiffData = sourceImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }
}
