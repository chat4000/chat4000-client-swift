import SwiftUI

/// Renders a chat4000.tool event as a STATIC chip "<icon> <name>" (protocol E,
/// "Tool calls — persistent, START-ONLY"). One event per tool, never updated:
/// no spinner, no status, no result, no duration, no completion. Just a small,
/// boxless footnote that a tool was used, at ~70% the size of a message.
struct ToolCallBubble: View {
    let message: ChatMessage

    private let nameFontSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 5) {
            iconView
            Text(message.toolName ?? "tool")
                .font(AppFonts.mono(nameFontSize, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.messageRowInset)
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var iconView: some View {
        // Prefer the per-tool emoji shipped by the plugin; fall back to a hammer.
        if let icon = message.toolIcon, !icon.isEmpty {
            Text(icon)
                .font(.system(size: 10))
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        ToolCallBubble(message: ChatMessage(
            sender: .agent, kind: .toolCall, toolId: "abc",
            toolName: "skill_view", toolIcon: "📚"))
        ToolCallBubble(message: ChatMessage(
            sender: .agent, kind: .toolCall, toolId: "def",
            toolName: "browser_navigate"))
    }
    .padding()
    .background(AppColors.background)
}
