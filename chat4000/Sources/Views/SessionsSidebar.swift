import SwiftUI
import SwiftData

/// Hosts the chat screen alongside a hideable left **sessions sidebar**
/// (the room list). macOS shows the sidebar inline (collapsible); iOS shows it
/// as a slide-over drawer. Replaces the bare `ChatView` for the `.chat` screen.
struct ChatShell: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ChatViewModel
    var shouldConnect: Bool

    @State private var showSidebar: Bool = ChatShell.defaultSidebarVisible

    /// Room ids we've already seen, so a NEW session appearing fires a celebratory
    /// haptic. We only start watching once the workspace is ready (the initial
    /// room list arrives in batches during setup — those aren't "new sessions").
    @State private var knownRoomIds: Set<String> = []
    @State private var armedForNewRoomHaptic = false

    private static var defaultSidebarVisible: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        content
            .onAppear {
                if shouldConnect { viewModel.setupMatrix(modelContext: modelContext) }
                viewModel.syncActiveRoomFromSession()
            }
            .onChange(of: shouldConnect) { _, newValue in
                guard newValue else { return }
                viewModel.setupMatrix(modelContext: modelContext)
                viewModel.syncActiveRoomFromSession()
            }
            // The session auto-selects the most-recent room, and the sidebar
            // selects others; both flow through here into the view model.
            .onChange(of: viewModel.matrixSession.activeRoomId) { _, _ in
                // G1: when the session resets (e.g. a new pairing) the active room
                // goes nil — clear the visible room + messages so we don't keep
                // showing the OLD room's persisted messages with no session.
                viewModel.syncActiveRoomFromSession()
            }
            .alert(
                "Couldn't reach your plugin",
                isPresented: Binding(
                    get: { viewModel.matrixSession.lastCommandError != nil },
                    set: { if !$0 { viewModel.matrixSession.clearCommandError() } }
                )
            ) {
                Button("OK", role: .cancel) { viewModel.matrixSession.clearCommandError() }
            } message: {
                Text(viewModel.matrixSession.lastCommandError ?? "")
            }
            // Arm new-session detection once the workspace is ready: seed the
            // baseline so the rooms already present at setup don't each buzz.
            .onChange(of: viewModel.matrixSession.isWorkspaceReady) { _, ready in
                guard ready, !armedForNewRoomHaptic else { return }
                knownRoomIds = Set(viewModel.matrixSession.rooms.map(\.id))
                armedForNewRoomHaptic = true
            }
            // A room id appearing after we're armed = a brand-new session was
            // created (by the user or the plugin) → celebratory haptic.
            .onChange(of: viewModel.matrixSession.rooms) { _, rooms in
                let ids = Set(rooms.map(\.id))
                guard armedForNewRoomHaptic else { knownRoomIds = ids; return }
                let added = ids.subtracting(knownRoomIds)
                knownRoomIds = ids
                if !added.isEmpty { Haptics.celebrate() }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 260)
                    .transition(.move(edge: .leading))
                Divider().background(AppColors.inputBorder)
            }
            chat
        }
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        #else
        ZStack(alignment: .leading) {
            chat

            if showSidebar {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false } }

                sidebar
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(AppColors.cardBackground)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        // Standard drawer gesture: swipe right reveals the session list, swipe
        // left dismisses it. `simultaneousGesture` so it never blocks the chat's
        // vertical scroll or button taps; we only act on a horizontal-dominant
        // swipe past a threshold.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy), abs(dx) > 60 else { return }
                    if dx > 0, !showSidebar {
                        Haptics.impact()
                        withAnimation(.easeInOut(duration: 0.2)) { showSidebar = true }
                    } else if dx < 0, showSidebar {
                        Haptics.impact()
                        withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
                    }
                }
        )
        #endif
    }

    private var chat: some View {
        ChatView(
            viewModel: viewModel,
            onToggleSidebar: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        SessionsSidebar(
            session: viewModel.matrixSession,
            onSelect: { id in
                Haptics.impact()   // G5: tactile feedback on session switch
                viewModel.switchRoom(id: id)
                #if os(iOS)
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
                #endif
            },
            onNewChat: { viewModel.matrixSession.requestNewSession() }
        )
    }
}

/// The room list itself.
struct SessionsSidebar: View {
    @Bindable var session: MatrixSession
    var onSelect: (String) -> Void
    var onNewChat: () -> Void

    @State private var renameTarget: MatrixSession.RoomSummary?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("chat4000")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // I2: hide the new-session button until the plugin is keyed, so a tap
            // can't fire a command encrypted to 0 recipients (the 3-tap bug).
            if session.isWorkspaceReady {
                Button(action: onNewChat) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New chat")
                            .font(AppFonts.label)
                        Spacer()
                    }
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider().background(AppColors.inputBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if session.rooms.isEmpty {
                        Text("No sessions yet")
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    ForEach(session.rooms) { room in
                        roomRow(room)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.cardBackground)
        .alert("Rename session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget,
                   !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    session.renameSession(roomId: target.id, title: renameText)
                }
                renameTarget = nil
            }
        }
    }

    private func roomRow(_ room: MatrixSession.RoomSummary) -> some View {
        let isActive = session.activeRoomId == room.id
        return Button {
            onSelect(room.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textSecondary)
                Text(displayName(room))
                    .font(AppFonts.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if room.unreadCount > 0 {
                    unreadBadge(room.unreadCount)
                }
                roomStatusIcons(room)
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isActive ? AppColors.inputBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button {
                renameText = room.name
                renameTarget = room
            } label: { Label("Rename", systemImage: "pencil") }
            if room.isPinned {
                Button {
                    session.unpinSession(roomId: room.id)
                } label: { Label("Unpin", systemImage: "pin.slash") }
            } else {
                Button {
                    session.pinSession(roomId: room.id)
                } label: { Label("Pin", systemImage: "pin") }
            }
            if room.isMuted {
                Button {
                    session.unmuteRoom(room.id)
                } label: { Label("Unmute", systemImage: "bell") }
            } else {
                Button {
                    session.muteRoom(room.id)
                } label: { Label("Mute", systemImage: "bell.slash") }
            }
            Button(role: .destructive) {
                session.deleteSession(roomId: room.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func unreadBadge(_ count: Int) -> some View {
        Text(unreadBadgeText(count))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AppColors.background)
            .frame(minWidth: 20, minHeight: 18)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .background(AppColors.connected)
            .clipShape(Capsule())
            .accessibilityLabel("\(count) unread messages")
    }

    private func unreadBadgeText(_ count: Int) -> String {
        count > 99 ? "99+" : "\(max(0, count))"
    }

    @ViewBuilder
    private func roomStatusIcons(_ room: MatrixSession.RoomSummary) -> some View {
        if room.isPinned || room.isMuted {
            HStack(spacing: 4) {
                if room.isPinned {
                    statusIcon(systemName: "pin.fill", accessibilityLabel: "Pinned")
                }
                if room.isMuted {
                    statusIcon(systemName: "bell.slash.fill", accessibilityLabel: "Muted")
                }
            }
        }
    }

    private func statusIcon(systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: 14, height: 14)
            .accessibilityLabel(accessibilityLabel)
    }

    /// Best-effort label. TODO(v2): resolve real room display names.
    private func displayName(_ room: MatrixSession.RoomSummary) -> String {
        if room.name != room.id { return room.name }
        // Room ids look like `!abc123:server` — show the local part.
        let trimmed = room.id.hasPrefix("!") ? String(room.id.dropFirst()) : room.id
        return trimmed.split(separator: ":").first.map(String.init) ?? room.id
    }
}
