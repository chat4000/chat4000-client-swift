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

    private var iconView: some View {
        // SF Symbol mapped from the tool NAME (ignoring the plugin's emoji), so the
        // chips read consistently with the rest of the UI. `.frame` keeps every
        // icon the same width so the names line up.
        Image(systemName: Self.symbolName(forTool: message.toolName))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: 12, alignment: .center)
    }

    /// Map a tool name to an SF Symbol by keyword, so variants
    /// (`browser_navigate`, `browser.navigate`, …) all resolve. Order matters:
    /// more specific cases first. Falls back to a hammer for anything unmapped.
    static func symbolName(forTool name: String?) -> String {
        let n = (name ?? "").lowercased()
        switch true {
        case n.contains("snapshot"), n.contains("screenshot"):
            return "camera.viewfinder"
        case n.contains("console"), n.contains("log"):
            return "apple.terminal"
        case n.contains("browser"), n.contains("navigate"), n.contains("http"), n.contains("url"), n.contains("fetch"):
            return "globe"
        case n.contains("search"):
            return "magnifyingglass"
        case n.contains("extract"), n.contains("scrape"), n.contains("read"):
            return "doc.text"
        case n.contains("terminal"), n.contains("shell"), n.contains("bash"), n.contains("exec"), n.contains("command"), n.contains("run"):
            return "terminal"
        case n.contains("skill"):
            return "book"
        case n.contains("todo"), n.contains("task"), n.contains("checklist"):
            return "checklist"
        case n.contains("list"):
            return "list.bullet"
        case n.contains("write"), n.contains("edit"), n.contains("create"), n.contains("file"):
            return "square.and.pencil"
        case n.contains("code"):
            return "chevron.left.forwardslash.chevron.right"
        case n.contains("image"), n.contains("photo"), n.contains("vision"):
            return "photo"
        case n.contains("memory"), n.contains("remember"), n.contains("note"):
            return "brain"
        default:
            return "hammer.fill"
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
