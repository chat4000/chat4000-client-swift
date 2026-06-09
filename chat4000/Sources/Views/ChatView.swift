import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

private let cliSpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
private let cliThinkingHints = ["Thinking", "Planning", "Tracing", "Checking", "Exploring", "Reasoning"]
private let cliWorkingHints = ["Working", "Using tools", "Checking results", "Running steps"]
private let cliTypingHints = ["Typing", "Drafting", "Shaping", "Answering"]

private enum VoiceRecordingSource: String {
    case inputBar = "input_bar"
    case launchAction = "launch_action"
}

struct ChatView: View {
    private static let defaultMacComposerHeight: CGFloat = 35

    @Environment(\.scenePhase) private var scenePhase
    @Bindable var viewModel: ChatViewModel
    /// When set, a leading sidebar-toggle button appears in the nav bar.
    var onToggleSidebar: (() -> Void)?
    @State private var messageText = ""
    /// Owned by `ChatShell` so the sidebar's Settings button can open this sheet.
    @Binding var showSettings: Bool
    @State private var showCamera = false
    @State private var voiceRecorder = VoiceNoteRecorder()
    @State private var voiceErrorMessage: String?
    @FocusState private var inputFocused: Bool
    @State private var hasPrimedInitialFocus = false
    @State private var isHandlingLaunchAction = false
    @State private var pendingLaunchActionTask: Task<Void, Never>?
    @State private var activeRecordingSource: VoiceRecordingSource = .inputBar
    @State private var macComposerHeight: CGFloat = ChatView.defaultMacComposerHeight
    @State private var versionPolicy = VersionPolicyManager.shared
    private let macComposerMaxHeight: CGFloat = 210

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                navBar

                if versionPolicy.showNag, case .recommendUpgrade(let recommended, _) = versionPolicy.action {
                    UpgradeRecommendedBanner(recommendedVersion: recommended) {
                        versionPolicy.dismissNag()
                    }
                }

                messageArea

                if let voiceErrorMessage {
                    errorBanner(voiceErrorMessage)
                }

                // No session → no composer at all (the empty state's New chat
                // is the only action). Don't show an input you can't send from.
                if viewModel.hasActiveSession {
                    inputBar
                }
            }

        }
        // iOS: a sheet (already dismisses on an outside tap / swipe-down). macOS
        // presents Settings as a tap-to-dismiss overlay in ChatShell instead, so
        // there is no sheet here on the Mac.
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                matrixSession: viewModel.matrixSession,
                pluginVersion: nil,
                pluginBundleId: nil,
                onDisconnect: viewModel.disconnect,
                onClearHistory: viewModel.clearHistory,
                onClose: { showSettings = false }
            )
            .presentationDetents([.fraction(0.75)])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppColors.cardBackground)
        }
        #endif
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

    // MARK: - Message area (always-mounted per-room views)

    /// Every session room gets its OWN view, all kept alive in this ZStack; only
    /// the front room is visible + interactive. Switching rooms just changes which
    /// one is on top — nothing is torn down, re-cooked, or replayed, and each
    /// view keeps its scroll position and already-rendered rows. A background
    /// room's view is already correct because its `RoomViewModel` cooked + saved
    /// its rows live (the active-room delivery gate is gone in `MatrixSession`).
    @ViewBuilder
    private var messageArea: some View {
        ZStack {
            ForEach(viewModel.matrixSession.rooms) { room in
                let isFront = viewModel.activeRoomId == room.id
                RoomMessagesView(
                    room: viewModel.room(for: room.id),
                    isFront: isFront,
                    onDismissKeyboard: { dismissKeyboard() }
                )
                .opacity(isFront ? 1 : 0)
                .allowsHitTesting(isFront)
            }

            // No room selected yet → the global setup/empty overlay (not a room).
            if viewModel.activeRoomId == nil {
                ScrollView {
                    noSessionPlaceholder
                }
            }
        }
    }

    private var noSessionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.textSecondary)

            Text("No sessions yet")
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)

            Text("Create a session to start chatting — your plugin sets it up and names it.")
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // I2: only offer the button once the workspace is keyed, so a tap can't
            // fire a command that's encrypted to 0 recipients (the 3-tap bug).
            if viewModel.matrixSession.isWorkspaceReady {
                Button {
                    Haptics.impact()
                    viewModel.matrixSession.requestNewSession()
                } label: {
                    Label("New chat", systemImage: "plus")
                        .font(AppFonts.button)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Nav Bar

    @ViewBuilder
    private var navBar: some View {
        #if os(macOS)
        // On Mac the chat has no top bar: the sidebar toggle floats at the window
        // top-left (by the traffic lights, in ChatShell) and Settings lives at the
        // sidebar's bottom-left.
        EmptyView()
        #else
        // iOS keeps the sidebar toggle top-left; Settings moved into the sidebar
        // header (top-right, where the account avatar sits).
        HStack {
            if let onToggleSidebar {
                Button {
                    Task { @MainActor in Haptics.impact() }
                    onToggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, -15)
        .padding(.bottom, AppSpacing.navBarBottomInset)
        #endif
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
        // The divider above adds visual weight, so an equal top/bottom inset reads
        // as top-heavy. On macOS bias the inset toward the bottom — same TOTAL as
        // before (2 + 6 = the old 4 + 4), so the composer's divider still lines up
        // with the sidebar's Settings-row divider — so it reads visually centered.
        #if os(macOS)
        .padding(.top, 2)
        .padding(.bottom, (AppSpacing.inputBarBottomInset * 2) - 2)
        #else
        .padding(.vertical, AppSpacing.inputBarBottomInset)
        #endif
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
        // No session bound → don't ghost the message; keep the text and nudge
        // the user to create/pick a session (the empty state has a New chat).
        guard viewModel.hasActiveSession else {
            Haptics.error()
            return
        }

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
            // start() already reported truly unexpected device failures at its
            // boundary; permission denial is expected. Surface the user message.
            voiceErrorMessage = error.message
            TelemetryManager.shared.track(
                .voiceRecordingFailed,
                properties: [
                    "reason": error.message,
                    "source": activeRecordingSource.rawValue
                ]
            )
            Haptics.error()
        }
    }

    private func openComposerFromLaunchAction() {
        AppLog.log("🎯 ChatView.openComposerFromLaunchAction begin")
        messageText = ""
        inputFocused = true
        TelemetryManager.shared.track(
            .actionButtonComposerTriggered,
            properties: ["entry": "launch_action"]
        )
        AppLog.log("🎯 ChatView.openComposerFromLaunchAction success")
    }

    private func startVoiceRecordingFromLaunchAction() async {
        guard !voiceRecorder.isRecording else { return }
        AppLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction begin")
        activeRecordingSource = .launchAction
        messageText = ""
        dismissKeyboardIfNeeded()
        voiceErrorMessage = nil

        do {
            try await voiceRecorder.start()
            AppLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction success")
            TelemetryManager.shared.track(
                .actionButtonRecordingTriggered,
                properties: ["entry": "foreground_continue"]
            )
            TelemetryManager.shared.track(
                .voiceRecordingStarted,
                properties: ["source": activeRecordingSource.rawValue]
            )
        } catch {
            // start() reported unexpected device failures at its boundary already.
            AppLog.log("🎯 ChatView.startVoiceRecordingFromLaunchAction error=%@", error.message)
            voiceErrorMessage = error.message
            TelemetryManager.shared.track(
                .voiceRecordingFailed,
                properties: [
                    "reason": error.message,
                    "source": activeRecordingSource.rawValue
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
                "duration_bucket": AnalyticsBuckets.durationBucket(for: clip.duration)
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
        AppLog.log("🎯 ChatView.handlePendingLaunchActionIfNeeded check")

        pendingLaunchActionTask?.cancel()
        pendingLaunchActionTask = Task { @MainActor in
            for attempt in 0..<6 {
                AppLog.log("🎯 ChatView.handlePendingLaunchActionIfNeeded attempt=%d", attempt)
                if let action = LaunchActionStore.consume() {
                    isHandlingLaunchAction = true
                    defer { isHandlingLaunchAction = false }

                    switch action {
                    case .startVoiceRecording:
                        await startVoiceRecordingFromLaunchAction()
                    case .openComposer:
                        openComposerFromLaunchAction()
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

// MARK: - Per-room messages view (one always-mounted instance per room)

/// Renders ONE room's timeline + busy indicator, bound to that room's
/// `RoomViewModel`. Each instance keeps its own scroll position because it stays
/// in the view tree across switches (it's just hidden when not front). Only the
/// front room sends read receipts.
struct RoomMessagesView: View {
    @Bindable var room: RoomViewModel
    var isFront: Bool
    var onDismissKeyboard: (() -> Void)?

    @State private var pendingScrollTask: Task<Void, Never>?
    /// True when the viewport is at/near the latest message. Drives BOTH the
    /// scroll-to-bottom button (hidden when pinned) and auto-scroll-on-new-message
    /// (we only yank the list down when the user is already at the bottom — if
    /// they've scrolled up to read history, new messages must NOT pull them away;
    /// the button + this flag are how we respect that). Starts true (fresh room
    /// opens at the bottom).
    @State private var isPinnedToBottom = true
    /// Live viewport height of the scroll view, measured via a background
    /// GeometryReader. Needed to turn the content's bottom-edge position into a
    /// distance-from-bottom.
    @State private var viewportHeight: CGFloat = 0

    /// Named coordinate space the content's bottom edge is measured against.
    private static let scrollSpace = "roomScroll"
    /// How close (pt) the content bottom must be to the viewport bottom to count
    /// as "pinned". Generous so tiny layout jitter / the busy row don't unpin.
    private static let bottomThreshold: CGFloat = 120

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageListContent
                    .padding(.vertical, AppSpacing.chatListVerticalInset)
                    .contentShape(Rectangle())
                    .textSelection(.enabled)
                    // Detection (iOS 17+, concurrency-safe): a layout-neutral
                    // GeometryReader reports the content's bottom edge in the
                    // scroll's coordinate space; `.onChange` (a main-actor closure,
                    // unlike onPreferenceChange's @Sendable one under strict
                    // concurrency) recomputes `isPinnedToBottom` as it scrolls.
                    // iOS 18 could use `onScrollGeometryChange`, but this one path
                    // covers our iOS 17 floor with no #available branch.
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(
                                of: geo.frame(in: .named(Self.scrollSpace)).maxY, initial: true
                            ) { _, maxY in
                                updatePinned(contentMaxY: maxY)
                            }
                        }
                    )
            }
            .coordinateSpace(name: Self.scrollSpace)
            // Viewport height (the scroll view's own size), kept current so the
            // distance-from-bottom math is correct after rotation / keyboard.
            .background(
                GeometryReader { vp in
                    Color.clear.onChange(of: vp.size.height, initial: true) { _, height in
                        viewportHeight = height
                    }
                }
            )
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { onDismissKeyboard?() }
            #endif
            .overlay(alignment: .bottomTrailing) {
                scrollToBottomButton(proxy)
            }
            .onAppear {
                // Opening / first showing a room always lands at the bottom.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    scrollToBottom(using: proxy)
                }
                if isFront { room.markRead() }
            }
            .onChange(of: room.messages.count) {
                // Pin-only auto-scroll: a new/changed message pulls the list down
                // ONLY if the user is already at the bottom; otherwise leave them
                // in place (the button appears to jump down on demand).
                if isPinnedToBottom { scrollToBottom(using: proxy) }
                if isFront { room.markRead() }
            }
            .onChange(of: room.scrollRevision) {
                if isPinnedToBottom { scrollToBottom(using: proxy) }
            }
            .onChange(of: room.isAgentBusy) {
                if isPinnedToBottom { scrollToBottom(using: proxy) }
            }
            .onChange(of: isFront) { _, front in
                guard front else { return }
                scrollToBottom(using: proxy)
                room.markRead()
            }
        }
    }

    /// Recompute whether the viewport is at/near the bottom from the content's
    /// bottom-edge position. When pinned the content bottom sits ~at the viewport
    /// bottom (maxY ≈ viewportHeight); scrolled up, the bottom is below the
    /// viewport (maxY ≫ viewportHeight). Content shorter than the viewport →
    /// always pinned.
    private func updatePinned(contentMaxY: CGFloat) {
        guard viewportHeight > 0 else { return }
        let pinned = (contentMaxY - viewportHeight) < Self.bottomThreshold
        if pinned != isPinnedToBottom { isPinnedToBottom = pinned }
    }

    /// Floating chevron that fades in only when the user has scrolled up; tapping
    /// it smoothly jumps to the latest message.
    @ViewBuilder
    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            Haptics.impact()
            AppLog.log("🔽 scroll-button tap pinned=%@ viewportH=%.0f msgs=%d",
                       String(isPinnedToBottom), viewportHeight, room.messages.count)
            // Route through the robust multi-pass scroll (NOT a single inline
            // scrollTo): a lone pass lands short ~20% when content is still
            // settling (busy row / image decode / markdown reflow) at tap time.
            scrollToBottom(using: proxy, animated: true)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .opacity(isPinnedToBottom ? 0 : 1)
        .scaleEffect(isPinnedToBottom ? 0.8 : 1)
        .allowsHitTesting(!isPinnedToBottom)
        .animation(.easeInOut(duration: 0.2), value: isPinnedToBottom)
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
        if room.messages.isEmpty && !room.isAgentBusy {
            noMessagesPlaceholder
                .id("emptyChatPlaceholder")
        }

        ForEach(room.messages, id: \.id) { message in
            MessageBubble(message: message)
                .id(message.id)
        }

        if room.isAgentBusy {
            busyIndicator
                .id("busyIndicator")
        }

        Color.clear
            .frame(height: 1)
            .id("chatBottomAnchor")
    }

    private var noMessagesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.textSecondary)

            Text("No messages yet")
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)

            Text("Type a message below and press send to talk to your agent.")
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    private var busyIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let spinnerIndex = Int(context.date.timeIntervalSinceReferenceDate * 12) % cliSpinnerFrames.count
            let spinner = cliSpinnerFrames[spinnerIndex]
            let hints = busyHints(for: room.busyPhase)
            let hintIndex = Int(context.date.timeIntervalSinceReferenceDate / 2) % hints.count
            let hint = hints[hintIndex]

            HStack(spacing: 8) {
                Text(spinner)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)

                if let start = room.busyStartTime {
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
        .animation(.easeInOut(duration: 0.2), value: room.isAgentBusy)
    }

    private func busyHints(for phase: String) -> [String] {
        switch phase.lowercased() {
        case "working":
            return cliWorkingHints
        case "typing":
            return cliTypingHints
        default:
            return cliThinkingHints
        }
    }

    /// Scroll to the bottom anchor, robust against a layout pass that's still
    /// settling. A SINGLE scrollTo lands short ~20% of the time when content grows
    /// right after the call (async image decode, the busy row appearing, markdown
    /// reflow) — it scrolls to the bottom-as-it-was, then more content pushes the
    /// real bottom further down. So we make one initial pass (animated for the
    /// button's smooth jump) then two short non-animated nudges that snap to the
    /// now-final bottom. Idempotent once pinned (each nudge is a no-op at bottom).
    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool = false) {
        AppLog.log("↕️ scrollToBottom msgs=%d pinned=%@ animated=%@ busy=%@",
                   room.messages.count, String(isPinnedToBottom), String(animated), String(room.isAgentBusy))
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("chatBottomAnchor", anchor: .bottom) }
            } else {
                proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            }
            // Follow-up nudges to reach the FINAL bottom after late content settles.
            for delay in [Duration.milliseconds(50), .milliseconds(150)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
                AppLog.log("↕️ scrollToBottom nudge after %@", String(describing: delay))
            }
        }
    }
}

#if os(macOS)
private struct MacComposerTextView: NSViewRepresentable {
    private static let composerFont = NSFont.systemFont(ofSize: 12, weight: .regular)
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
        // H1 fix: NSTextView() initializes at NSZeroRect. Without an
        // explicit non-zero starting frame AND .width autoresizing, the
        // text view inside NSScrollView can lay out with zero width — the
        // text container clips every glyph to a width-0 rect, so typed
        // characters insert into the storage but never render. SwiftUI's
        // first layout pass on macOS 14.x can interleave with documentView
        // assignment in a way that leaves us in this state.
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: minHeight)
        textView.autoresizingMask = [.width]
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
            guard let textView, let textContainer = textView.textContainer else { return }
            textView.layoutManager?.ensureLayout(for: textContainer)

            let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? parent.minHeight
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

        /// Auto-focus the composer the moment it's installed in a
        /// window. SwiftUI's `@FocusState`/`.focused()` isn't bound to
        /// the AppKit text view on macOS, so `primeInitialFocus()` in
        /// ChatView only flips a SwiftUI state nobody observes here.
        /// Promoting ourselves to first responder via AppKit is what
        /// actually lets the user start typing on app launch without
        /// having to click into the field first.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

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

// MARK: - Global app view model

/// App-global state owner: the connection, the first-run setup phase, the shared
/// `MatrixSession`, and the registry of per-room `RoomViewModel`s. It routes each
/// sync event to the matching room's view model by `roomId` — with NO active-room
/// gate, so every room (front or background) cooks + persists its rows live. There
/// is no shared "messages" tray here and no replay-on-switch: switching rooms only
/// changes which mounted room view is front.
@MainActor
@Observable
final class ChatViewModel {
    var connectionState: ConnectionState = .disconnected
    /// Which room is front (mirrors `MatrixSession.activeRoomId`, the single
    /// source of truth). Drives which mounted room view is visible.
    var activeRoomId: String?

    @ObservationIgnored let matrixSession = MatrixSession()
    @ObservationIgnored private var modelContext: ModelContext?
    /// One view model per room, created lazily and KEPT ALIVE across switches.
    @ObservationIgnored private var roomVMs: [String: RoomViewModel] = [:]

    var onTermsVersionUpdate: ((Int) -> Void)?

    init() {
        matrixSession.onConnectionStateChange = { [weak self] state in
            self?.connectionState = state
        }
        // Deliver EVERY room's events to its own view model — no active gate.
        matrixSession.onRoomEvent = { [weak self] roomId, event, live in
            self?.room(for: roomId).ingest(event, live: live)
        }
        // session.new auto-open / first-room select sets the front pointer here.
        matrixSession.onActiveRoomChange = { [weak self] id in
            guard let self else { return }
            self.setFrontRoom(id)
        }
        // Outbound correlation + read receipts: broadcast to all rooms; the one
        // that owns the local id / event id acts, the rest no-op.
        matrixSession.onSentEventId = { [weak self] localId, eventId in
            self?.roomVMs.values.forEach { $0.handleSentEventId(localId: localId, eventId: eventId) }
        }
        matrixSession.onReadReceipt = { [weak self] eventId in
            self?.roomVMs.values.forEach { $0.handleRead(eventId: eventId) }
        }
        matrixSession.onRoomDeleted = { [weak self] roomId in
            guard let self else { return }
            self.roomVMs[roomId]?.clearHistory()
            self.roomVMs.removeValue(forKey: roomId)
        }
    }

    /// Lazily create (and persist-attach) the view model for a room, keeping it
    /// alive for the rest of the session.
    func room(for roomId: String) -> RoomViewModel {
        if let existing = roomVMs[roomId] { return existing }
        let vm = RoomViewModel(roomId: roomId, session: matrixSession)
        if let modelContext { vm.attach(modelContext: modelContext) }
        roomVMs[roomId] = vm
        return vm
    }

    var frontRoom: RoomViewModel? { activeRoomId.map { room(for: $0) } }

    private func setFrontRoom(_ roomId: String?) {
        activeRoomId = roomId
        if let roomId { _ = room(for: roomId) }
    }

    func syncActiveRoomFromSession() {
        setFrontRoom(matrixSession.activeRoomId)
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        matrixSession.attach(modelContext: modelContext)
        for vm in roomVMs.values { vm.attach(modelContext: modelContext) }
        syncActiveRoomFromSession()
    }

    /// v2 chat-screen setup: attach persistence and restore the Matrix session.
    func setupMatrix(modelContext: ModelContext) {
        attach(modelContext: modelContext)
        guard connectionState != .connected else {
            syncActiveRoomFromSession()
            return
        }
        Task { await matrixSession.connect() }
    }

    /// Bring a room to front. The session's `selectRoom` is the single source of
    /// truth; it no longer replays anything — the room's mounted view is already
    /// up to date.
    func switchRoom(id: String) {
        matrixSession.selectRoom(id)
    }

    /// Session reset (new pairing / signed out) — no room is front.
    func clearActiveRoom() {
        setFrontRoom(nil)
    }

    func refreshMessages() {
        guard modelContext != nil else { return }
        roomVMs.values.forEach { $0.reloadHistory() }
    }

    func markRead() { frontRoom?.markRead() }

    func pair(code: String) async {
        await matrixSession.pair(code: code)
    }

    var isPaired: Bool { matrixSession.isPaired }
    /// True when a session room is front. Sending requires this.
    var hasActiveSession: Bool { activeRoomId != nil }
    var setupPhase: MatrixSession.SetupPhase { matrixSession.setupPhase }
    var isSettingUp: Bool { matrixSession.setupPhase != .ready }
    var showSetupProgress: Bool { isSettingUp }
    /// True once setup has been stuck waiting on the plugin past the timeout.
    var setupStalled: Bool { matrixSession.setupStalled }
    /// Keep waiting after a stall (clears the flag, restarts the timeout clock).
    func retrySetupWait() { matrixSession.retrySetupWait() }

    func backgroundWake() async -> Bool {
        await matrixSession.backgroundWake()
    }

    func disconnect() {
        connectionState = .disconnected
        Task { await matrixSession.signOut() }
    }

    // MARK: - Outbound (forwarded to the front room)

    func send(text: String) {
        guard let front = frontRoom else {
            AppLog.log("✋ send blocked — no active session")
            return
        }
        front.send(text: text)
    }

    func sendImage(_ image: PlatformImage) {
        guard let jpegData = image.clawConnectJPEGData else { return }
        guard let front = frontRoom else {
            AppLog.log("✋ image send blocked — no active session")
            return
        }
        front.sendImage(data: jpegData, mimeType: "image/jpeg")
    }

    func sendAudio(_ audioData: Data, mimeType: String, duration: TimeInterval, waveform: [Float], source: String) {
        guard let front = frontRoom else {
            AppLog.log("✋ audio send blocked — no active session")
            return
        }
        front.sendAudio(data: audioData, mimeType: mimeType, duration: duration, waveform: waveform, source: source)
    }

    func clearHistory() {
        frontRoom?.clearHistory()
    }
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

extension PlatformImage {
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
            (512, 0.54)
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

/// Lightweight confetti burst — ~90 colored pieces fall + fade from the top over a
/// few seconds. Self-contained (no package): a `TimelineView(.animation)` drives a
/// `Canvas`, and each piece's position is a pure function of elapsed time, so there
/// is no per-frame state to manage.
struct ConfettiView: View {
    private struct Piece {
        let x: CGFloat        // 0…1 horizontal start
        let delay: Double
        let duration: Double
        let drift: CGFloat
        let size: CGFloat
        let color: Color
        let emoji: String?    // nil = colored rectangle; else drawn as text
    }

    @State private var start = Date()
    private let pieces: [Piece]

    /// `intensity` 0…1 scales the piece count (2/10 = a light burst); ~1 in 4
    /// pieces is a celebratory emoji mixed in with the colored confetti.
    init(intensity: Double = 1.0) {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .cyan]
        let emojis = ["🎉", "🎊", "✨", "🥳", "🎈"]
        let count = max(8, Int(90 * intensity))
        pieces = (0..<count).map { index in
            let isEmoji = index % 4 == 0
            return Piece(
                x: .random(in: 0...1),
                delay: .random(in: 0...0.5),
                duration: .random(in: 1.8...2.8),
                drift: .random(in: -40...40),
                size: isEmoji ? .random(in: 18...26) : .random(in: 6...12),
                color: colors.randomElement() ?? .white,
                emoji: isEmoji ? emojis.randomElement() : nil
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let local = elapsed - piece.delay
                    guard local >= 0 else { continue }
                    let progress = min(local / piece.duration, 1)
                    let y = -20 + (size.height + 40) * progress
                    let x = piece.x * size.width + piece.drift * CGFloat(progress)
                    let fade = progress < 0.85 ? 1.0 : max(0, 1 - (progress - 0.85) / 0.15)
                    ctx.opacity = fade
                    if let emoji = piece.emoji {
                        ctx.draw(Text(emoji).font(.system(size: piece.size)), at: CGPoint(x: x, y: y))
                    } else {
                        let rect = CGRect(x: x, y: y, width: piece.size, height: piece.size * 0.6)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(piece.color))
                    }
                }
            }
        }
    }
}

/// The pretty "you're connected" card shown briefly over the confetti when the
/// workspace becomes ready: a big emoji, a bold "Connected!" headline, and a small
/// "congratz" line under it, on a frosted rounded card.
struct ConnectedCelebrationCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("🎉")
                .font(.system(size: 52))
            Text("Connected!")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)
            Text("congratz")
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 26)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 10)
    }
}

/// First-run setup progress, shown in the chat area until the workspace is ready
/// (control room found). Steps mirror MatrixSession.SetupPhase: connect → sync →
/// wait for the plugin → join the workspace.
struct SetupProgressView: View {
    let phase: MatrixSession.SetupPhase
    /// True once the wait on the plugin has timed out — swaps the active-step
    /// spinner for a warning and shows the recovery actions below.
    var stalled: Bool = false
    /// Keep waiting (re-arm the timeout). No-op closure by default for previews.
    var onRetry: () -> Void = {}
    /// Bail out and re-enter a pairing code.
    var onStartOver: () -> Void = {}

    // Order MUST match SetupPhase's rawValue order so the checkmarks fill
    // top-to-bottom (done = a lower-rawValue phase). You wait for the plugin's
    // invite first, THEN join the workspace.
    private static let steps: [(phase: MatrixSession.SetupPhase, label: String)] = [
        (.connecting, "Connecting"),
        (.syncing, "Syncing"),
        (.waitingForPlugin, "Waiting for your plugin"),
        (.joiningWorkspace, "Joining your workspace")
    ]

    var body: some View {
        VStack(spacing: 18) {
            Text("Setting up")
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)

            ProgressView(value: phase.progress)
                .tint(.white)
                .frame(maxWidth: 220)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.steps, id: \.phase.rawValue) { step in
                    stepRow(step.phase, step.label)
                }
            }

            if stalled {
                stalledFooter
            } else if phase == .waitingForPlugin {
                Text("Your plugin is setting things up. Make sure it's running on your computer.")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textTimestamp)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: phase.rawValue)
        .animation(.easeInOut(duration: 0.2), value: stalled)
    }

    @ViewBuilder
    private var stalledFooter: some View {
        VStack(spacing: 16) {
            Text("Your plugin isn't responding. Make sure it's running on your computer, then try again.")
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: onStartOver) {
                    Text("Re-enter code")
                        .font(AppFonts.label)
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Button(action: onRetry) {
                    Text("Try again")
                        .font(AppFonts.label)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func stepRow(_ stepPhase: MatrixSession.SetupPhase, _ label: String) -> some View {
        let current = phase.rawValue
        let isDone = current > stepPhase.rawValue
        let isActive = current == stepPhase.rawValue
        HStack(spacing: 12) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.connected)
                } else if isActive {
                    // A stalled wait shows a warning where the spinner was, so the
                    // stuck step reads as "needs attention" rather than "in progress".
                    if stalled {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.reconnecting)
                    } else {
                        ProgressView().controlSize(.small).tint(AppColors.textSecondary)
                    }
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(AppColors.textTimestamp)
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)

            Text(label)
                .font(AppFonts.body)
                .foregroundStyle(isActive ? AppColors.textPrimary
                                 : (isDone ? AppColors.textSecondary : AppColors.textTimestamp))
            Spacer(minLength: 0)
        }
    }
}
