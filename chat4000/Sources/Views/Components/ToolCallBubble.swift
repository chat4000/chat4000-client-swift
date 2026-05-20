import SwiftUI

/// Renders a Hermes tool-call as an agent-side bubble.
///
/// Visual contract:
///   - Always agent-aligned (left). Tool calls never originate from the user.
///   - Header row: hammer icon · tool name · status indicator (spinner/✓/✗)
///   - Collapsed by default. Tap to expand args + result blocks.
///   - Monospace font for args/result, syntax-color-free (just text).
///   - Long-press / context menu copies args or result to clipboard.
///
/// Wire-protocol fields used (per chat4000 protocol §6.4.x, tool_start /
/// tool_delta / tool_end):
///   - toolId — stable correlator across frames
///   - toolName — short tool identifier
///   - toolArgs — JSON-stringified, plugin-truncated to ~2 KB
///   - toolResult — short result summary, plugin-truncated to ~4 KB
///   - toolStatus — running / done / failed
///   - toolDurationMs — wall-clock ms, nil while running
struct ToolCallBubble: View {
    let message: ChatMessage
    @State private var expanded: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            bubbleContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.messageRowInset)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.impact()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }

            if expanded {
                expandedDetails
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, AppSpacing.messagePaddingH)
        .padding(.vertical, AppSpacing.messagePaddingV)
        .background(AppColors.agentBubble)
        .clipShape(BubbleShape(isUser: false))
    }

    // ─── Header (always visible) ──────────────────────────────────────

    private var headerRow: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18, height: 18)

            Text(message.toolName ?? "tool")
                .font(AppFonts.mono(13, weight: .semibold))
                .foregroundStyle(AppColors.agentBubbleText)
                .lineLimit(1)

            statusBadge

            Spacer(minLength: 4)

            if let durationMs = message.toolDurationMs {
                Text(formatDuration(ms: durationMs))
                    .font(AppFonts.mono(11, weight: .regular))
                    .foregroundStyle(AppColors.textTimestamp)
                    .monospacedDigit()
            }

            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.textTimestamp)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch message.toolStatus {
        case .running:
            // Subtle in-line spinner. SwiftUI's ProgressView size is
            // hard to control — use a simple rotating circle stroke.
            SpinnerBadge()
                .frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.connected)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.destructive)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        // Prefer the per-tool emoji shipped by the plugin
        // (`agent.display.get_tool_emoji` on the gateway side). Falls
        // back to the SF Symbol hammer when the icon is missing — older
        // plugin versions, custom tools without a registered emoji, etc.
        if let icon = message.toolIcon, !icon.isEmpty {
            Text(icon)
                .font(.system(size: 14))
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    private var iconColor: Color {
        switch message.toolStatus {
        case .failed: return AppColors.destructive
        case .done:   return AppColors.connected
        default:      return AppColors.textSecondary
        }
    }

    // ─── Expanded details (args + result) ─────────────────────────────

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let args = message.toolArgs, !args.isEmpty {
                detailBlock(label: "args", content: args)
            }
            if let result = message.toolResult, !result.isEmpty {
                detailBlock(label: "result", content: result)
            }
        }
    }

    private func detailBlock(label: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(AppFonts.mono(9, weight: .semibold))
                .foregroundStyle(AppColors.textTimestamp)
                .tracking(1.2)

            Text(content)
                .font(AppFonts.mono(11, weight: .regular))
                .foregroundStyle(AppColors.agentBubbleText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button("Copy \(label)") { copyText(content) }
                }
        }
    }

    private func formatDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(remainder)s"
    }
}

/// Tiny CPU-cheap spinner — beats SwiftUI's ProgressView at this size
/// because we don't want the indeterminate-bar variant and the iOS
/// default circle is too thick.
private struct SpinnerBadge: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                AppColors.textSecondary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 0.9).repeatForever(autoreverses: false)
                ) {
                    rotation = 360
                }
            }
    }
}

#if os(iOS)
import UIKit
private func copyText(_ text: String) {
    UIPasteboard.general.string = text
}
#elseif os(macOS)
import AppKit
private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
#endif

#Preview {
    VStack(spacing: 16) {
        ToolCallBubble(message: ChatMessage(
            sender: .agent,
            kind: .toolCall,
            toolId: "abc",
            toolName: "bash",
            toolArgs: "ls -la /tmp",
            toolResult: "total 16\ndrwxrwxrwt  5 root  wheel  160 May 20 11:23 .",
            toolStatus: .done,
            toolDurationMs: 234
        ))
        ToolCallBubble(message: ChatMessage(
            sender: .agent,
            kind: .toolCall,
            toolId: "def",
            toolName: "web.search",
            toolArgs: "{\"query\":\"hermes agent docs\"}",
            toolResult: "",
            toolStatus: .running,
            toolDurationMs: nil
        ))
        ToolCallBubble(message: ChatMessage(
            sender: .agent,
            kind: .toolCall,
            toolId: "ghi",
            toolName: "read_file",
            toolArgs: "{\"path\":\"/etc/shadow\"}",
            toolResult: "permission denied",
            toolStatus: .failed,
            toolDurationMs: 8
        ))
    }
    .padding()
    .background(AppColors.background)
}
