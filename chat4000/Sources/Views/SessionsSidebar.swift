import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Hosts the chat screen alongside a hideable left **sessions sidebar**
/// (the room list). macOS shows the sidebar inline (collapsible); iOS shows it
/// as a slide-over drawer. Replaces the bare `ChatView` for the `.chat` screen.
struct ChatShell: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ChatViewModel
    var shouldConnect: Bool

    @State private var showSidebar: Bool = ChatShell.defaultSidebarVisible
    /// Live finger translation while dragging the iOS drawer (0 when idle).
    @State private var dragOffset: CGFloat = 0
    /// True while a horizontal drawer drag is in progress (suppresses snap anim).
    @State private var isDraggingSidebar = false
    /// Owns the Settings sheet so both the chat (iOS) and the sidebar can open it.
    @State private var showSettings = false

    /// iOS drawer width (also the closed-state offset).
    static let sidebarWidth: CGFloat = 300

    #if os(macOS)
    /// User-resizable macOS sidebar width, persisted across launches.
    @AppStorage("macSidebarWidth") private var macSidebarWidth: Double = 260
    /// Width captured at the start of a resize drag (nil when not dragging).
    @State private var sidebarResizeStartWidth: Double?
    private static let macSidebarMinWidth: Double = 200
    private static let macSidebarMaxWidth: Double = 460
    #endif

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
            #if os(macOS)
            // macOS Settings: a tap-to-dismiss overlay (a sheet would be modal and
            // couldn't close on an outside click).
            .overlay { macSettingsOverlay }
            #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macSettingsOverlay: some View {
        if showSettings {
            ZStack {
                // Outside-click backdrop — tapping anywhere off the panel closes it.
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { showSettings = false }

                SettingsSheet(
                    matrixSession: viewModel.matrixSession,
                    pluginVersion: nil,
                    pluginBundleId: nil,
                    onDisconnect: viewModel.disconnect,
                    onClearHistory: viewModel.clearHistory,
                    onClose: { showSettings = false }
                )
                .frame(width: 520, height: 680)
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .transition(.opacity)
        }
    }
    #endif

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if showSidebar {
                    sidebar
                        .frame(width: CGFloat(macSidebarWidth))
                        .transition(.move(edge: .leading))
                    sidebarResizeHandle
                }
                chat
            }
            .animation(sidebarResizeStartWidth == nil ? .easeInOut(duration: 0.2) : nil, value: showSidebar)

            // Persistent sidebar toggle at the window top-left, right of the
            // traffic lights (like the Claude desktop app). Visible whether the
            // sidebar is open or closed, so it's always the way to collapse/expand.
            // `ignoresSafeArea(.top)` lifts it INTO the title-bar row (beside the
            // traffic lights) — otherwise the ~40pt top safe-area inset drops it
            // into the gap above the sidebar title.
            macSidebarToggle
                .padding(.leading, 80)
                .padding(.top, 4)
                .ignoresSafeArea(.container, edges: .top)
        }
        #else
        // The drawer tracks the finger: `offset` is where the sidebar's leading
        // edge sits (−width = fully closed, 0 = fully open). During a drag we add
        // the live translation; on release we snap open/closed by position + fling.
        let width = Self.sidebarWidth
        let base: CGFloat = showSidebar ? 0 : -width
        let offset = min(0, max(-width, base + dragOffset))
        let openFraction = (offset + width) / width   // 0…1
        ZStack(alignment: .leading) {
            chat

            Color.black
                .opacity(0.45 * openFraction)
                .ignoresSafeArea()
                .allowsHitTesting(openFraction > 0.01)
                .onTapGesture { setSidebar(false) }

            sidebar
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(AppColors.cardBackground)
                .offset(x: offset)
        }
        // Animate snaps, but NOT while the finger is down (that would lag the drag).
        .animation(isDraggingSidebar ? nil : .easeInOut(duration: 0.22), value: showSidebar)
        .animation(isDraggingSidebar ? nil : .easeInOut(duration: 0.22), value: dragOffset)
        // Interactive drawer: swipe right reveals the session list, swipe left
        // dismisses it, and the panel follows the finger the whole way.
        // `simultaneousGesture` so it never blocks the chat's vertical scroll or
        // button taps; we only engage once a drag is clearly horizontal.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if !isDraggingSidebar {
                        // Engage only on a horizontal-dominant drag in a useful
                        // direction (open when closed / close when open).
                        guard abs(dx) > abs(dy) else { return }
                        guard (dx > 0 && !showSidebar) || (dx < 0 && showSidebar) else { return }
                        isDraggingSidebar = true
                    }
                    dragOffset = dx
                }
                .onEnded { value in
                    guard isDraggingSidebar else { return }
                    isDraggingSidebar = false
                    let projected = base + value.predictedEndTranslation.width
                    // Open if released past the halfway point OR flung that way.
                    let shouldOpen = projected > -width / 2
                    Haptics.impact()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showSidebar = shouldOpen
                        dragOffset = 0
                    }
                }
        )
        #endif
    }

    private func setSidebar(_ open: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) {
            showSidebar = open
            dragOffset = 0
        }
    }

    #if os(macOS)
    /// The divider between the sidebar and chat, with a wider invisible grab strip
    /// that drags to resize the sidebar (and shows a resize cursor on hover).
    private var sidebarResizeHandle: some View {
        Divider()
            .background(AppColors.inputBorder)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    // Measure the drag in GLOBAL space, not the handle's local
                    // space: resizing moves the handle under the cursor, and a
                    // local-space translation would then feed back on itself and
                    // make the divider vibrate. Global coords are anchored to the
                    // window, so the translation tracks the cursor cleanly.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = sidebarResizeStartWidth ?? macSidebarWidth
                                if sidebarResizeStartWidth == nil { sidebarResizeStartWidth = base }
                                macSidebarWidth = min(
                                    Self.macSidebarMaxWidth,
                                    max(Self.macSidebarMinWidth, base + value.translation.width)
                                )
                            }
                            .onEnded { _ in sidebarResizeStartWidth = nil }
                    )
            )
    }

    private var macSidebarToggle: some View {
        Button {
            Haptics.impact()
            withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
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
        .accessibilityLabel("Toggle sidebar")
    }
    #endif

    private var chat: some View {
        ChatView(
            viewModel: viewModel,
            onToggleSidebar: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } },
            showSettings: $showSettings
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
            onNewChat: { viewModel.matrixSession.requestNewSession() },
            onOpenSettings: { showSettings = true }
        )
    }
}

/// The room list itself.
struct SessionsSidebar: View {
    @Bindable var session: MatrixSession
    var onSelect: (String) -> Void
    var onNewChat: () -> Void
    var onOpenSettings: () -> Void

    @State private var renameTarget: MatrixSession.RoomSummary?
    @State private var renameText = ""
    /// Row the pointer is currently over (macOS hover highlight; nil on touch).
    @State private var hoveredRoomId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("chat4000")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                #if os(iOS)
                // iOS: Settings lives in the sidebar header top-right (where the
                // Claude app puts the account avatar).
                settingsButton
                #endif
            }
            .padding(.horizontal, 16)
            // macOS: the window's ~44pt top safe-area inset already clears the
            // floating toggle / traffic-light row, so only a small gap is needed
            // below it before the title.
            #if os(macOS)
            .padding(.top, 10)
            #else
            .padding(.top, 16)
            #endif
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

            #if os(macOS)
            // macOS: Settings pinned at the sidebar's bottom-left (like the Claude
            // desktop account row). Height matches the chat input bar exactly so
            // this divider lines up with the composer's divider: composer height
            // (35) + inputBarBottomInset (8) top & bottom = same block height.
            Divider().background(AppColors.inputBorder)
            HStack {
                settingsButton
                Spacer()
            }
            .frame(height: 35)
            .padding(.vertical, AppSpacing.inputBarBottomInset)
            .padding(.horizontal, 6)
            #endif
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

    private var settingsButton: some View {
        Button {
            Haptics.impact()
            onOpenSettings()
        } label: {
            #if os(macOS)
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                Text("Settings")
                    .font(AppFonts.label)
            }
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            #else
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private func roomRow(_ room: MatrixSession.RoomSummary) -> some View {
        let isActive = session.activeRoomId == room.id
        return ZStack(alignment: .trailing) {
            // Full-height selection target. The padding lives INSIDE the label and
            // `.contentShape` covers the whole rectangle, so a tap ANYWHERE on the
            // row (including the vertical gaps that used to be dead, and the Spacer
            // gap right of the name) selects the room.
            Button {
                onSelect(room.id)
            } label: {
                HStack(spacing: 8) {
                    Text(displayName(room))
                        .font(AppFonts.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if room.unreadCount > 0 {
                        unreadBadge(room.unreadCount)
                    }
                    // Reserve width for the trailing overlay (pin/mute icons + the
                    // dots, which live together on the right) so the name truncates
                    // before them instead of sliding underneath.
                    Color.clear.frame(width: trailingControlsWidth(room), height: 24)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 3-dots menu overlaid on the trailing edge: tapping the dots opens the
            // same actions as right-click / long-press; taps anywhere else select.
            // Use the vertical-ellipsis CHARACTER (U+22EE "⋮") as a Text label.
            // Why not the obvious alternatives: `ellipsis.vertical` is not a valid
            // SF Symbol; macOS's native Menu drops a `rotationEffect` on its label
            // (→ horizontal on Mac) AND won't render a shape-based label like a
            // VStack of Circles (→ invisible on Mac). A Text glyph renders reliably
            // on both platforms, and `.borderlessButton` removes the macOS bezel.
            HStack(spacing: 4) {
                // Pin/mute sit right next to the dots (non-interactive — taps fall
                // through to the row's selection button below).
                roomStatusIcons(room)
                    .allowsHitTesting(false)
                Menu {
                    roomMenuItems(room)
                } label: {
                    Text("\u{22EE}")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Session options")
            }
            .padding(.trailing, 8)
        }
        .background(rowBackground(isActive: isActive, roomId: room.id))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        // macOS hover highlight: light the row up a bit under the pointer. `onHover`
        // is a no-op on touch, so iOS is unaffected.
        .onHover { inside in
            if inside {
                hoveredRoomId = room.id
            } else if hoveredRoomId == room.id {
                hoveredRoomId = nil
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredRoomId)
        .contextMenu {
            roomMenuItems(room)
        }
    }

    /// Row background: active selection wins; otherwise a subtle hover tint.
    private func rowBackground(isActive: Bool, roomId: String) -> Color {
        if isActive { return AppColors.inputBackground }
        if hoveredRoomId == roomId { return Color.white.opacity(0.06) }
        return Color.clear
    }

    /// Width to reserve in the row for the trailing overlay (pin/mute icons + the
    /// 3-dots), so the name truncates before them instead of underlapping. Mirrors
    /// the overlay's real width: 14pt per status icon (4pt between two) + 4pt gap to
    /// the dots + 28pt dots + an 8pt safety margin.
    private func trailingControlsWidth(_ room: MatrixSession.RoomSummary) -> CGFloat {
        var iconCount = 0
        if room.isPinned { iconCount += 1 }
        if room.isMuted { iconCount += 1 }
        let iconsWidth = iconCount == 0 ? 0 : CGFloat(iconCount) * 14 + CGFloat(iconCount - 1) * 4
        let dotsBlock: CGFloat = 28 + (iconCount == 0 ? 0 : 4 + iconsWidth)
        return dotsBlock + 8
    }

    /// Shared by the 3-dots `Menu` and the long-press / right-click context menu.
    @ViewBuilder
    private func roomMenuItems(_ room: MatrixSession.RoomSummary) -> some View {
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
