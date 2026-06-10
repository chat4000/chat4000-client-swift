import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.sender == .user }
    private var isUnavailable: Bool { message.kind == .unavailable }

    var body: some View {
        // Tool-call rows render with a dedicated component — they have
        // their own header/expand/status UI distinct from text bubbles.
        if message.kind == .toolCall {
            ToolCallBubble(message: message)
        } else if message.kind == .htmlCard {
            HTMLCardBubble(message: message)
        } else {
            HStack(alignment: .top, spacing: 8) {
                bubbleContent
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(.horizontal, AppSpacing.messageRowInset)
        }
    }

    /// Tiny inline tick that lives at the bottom-right inside user bubbles
    /// (per the chat-app convention). Agent bubbles get no tick.
    /// Color: timestamp grey for sending/sent, green for delivered, red for
    /// failed. Per protocol section 6.6.7.
    @ViewBuilder
    private var statusTick: some View {
        if isUser {
            switch message.status {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            case .delivered:
                // WhatsApp-style double tick: two checkmarks overlapping
                // very tightly so they read as a single stacked glyph. Blue
                // marks the "delivered to plugin" terminal state.
                ZStack {
                    Image(systemName: "checkmark").offset(x: -1.5)
                    Image(systemName: "checkmark").offset(x: 1.5)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(hex: 0x53BDEB))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            if let imageData = message.imageData,
               let image = BubblePlatformImage(data: imageData) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            if let audioData = message.audioData {
                VoicePlaybackStrip(
                    sourceKey: "message-\(message.id.uuidString)",
                    audioData: audioData,
                    waveform: message.audioWaveform,
                    duration: message.audioDuration,
                    activeColor: isUser ? Color.white : Color(hex: 0x111111),
                    inactiveColor: isUser ? Color.white.opacity(0.22) : AppColors.textTimestamp.opacity(0.22),
                    backgroundColor: .clear,
                    textColor: isUser ? Color(hex: 0xF3F4F6) : AppColors.agentBubbleText,
                    compact: true
                )
            }

            if isUnavailable {
                Label {
                    Text(message.text.isEmpty ? "Message unavailable on this device" : message.text)
                } icon: {
                    Image(systemName: "lock.slash")
                }
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textTimestamp)
            } else if !message.text.isEmpty {
                Text(attributedText)
                    .font(AppFonts.body)
                    .foregroundStyle(isUser ? Color(hex: 0xF3F4F6) : AppColors.agentBubbleText)
                    // Text stays selectable (inherits the message list's
                    // `.textSelection(.enabled)`): drag-select + ⌘C on macOS,
                    // long-press on iOS. Copy is also in the context menu below.
                    .contextMenu {
                        Button("Copy") {
                            copyText(message.text)
                        }
                    }
            }
        }
        .padding(.horizontal, AppSpacing.messagePaddingH)
        .padding(.vertical, AppSpacing.messagePaddingV)
        .background(bubbleBackground)
        .clipShape(BubbleShape(isUser: isUser))
        .overlay(
            BubbleShape(isUser: isUser)
                .stroke(isUser ? Color(hex: 0x71767A) : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .bottomTrailing) {
            // Tiny inline tick anchored to the bottom-right corner of the
            // user bubble. Doesn't affect text layout; floats over the
            // padding region.
            if isUser {
                statusTick
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    private var bubbleBackground: Color {
        if isUnavailable {
            return AppColors.agentBubble.opacity(0.58)
        }
        return isUser ? AppColors.background : AppColors.agentBubble
    }

    /// Render the body as Markdown (bold/italic/`code`/~~strike~~/links), falling
    /// back to plain text if parsing fails. We use `.inlineOnlyPreservingWhitespace`
    /// so newlines/blank lines in a chat message are kept verbatim (the `.full`
    /// syntax would collapse them and try to lay out block elements, which `Text`
    /// can't render). Inline `code` spans get a monospaced font here because the
    /// parser only tags the intent — `Text` won't change the font on its own.
    private var attributedText: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var attributed = try? AttributedString(markdown: message.text, options: options) else {
            return AttributedString(message.text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
        }
        return attributed
    }

    private var contentSpacing: CGFloat {
        let contentCount = [
            message.imageData != nil,
            message.audioData != nil,
            !message.text.isEmpty
        ].filter { $0 }.count
        return contentCount > 1 ? 8 : 0
    }
}

// Custom bubble shape with tail corner
struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r = AppRadius.messageBubble
        let tail = AppRadius.messageTail

        guard isUser else {
            // Agent: small radius on bottom-left
            return RoundedCornerShape(
                topLeft: r, topRight: r,
                bottomLeft: tail, bottomRight: r
            ).path(in: rect)
        }
        // User: small radius on bottom-right
        return RoundedCornerShape(
            topLeft: r, topRight: r,
            bottomLeft: r, bottomRight: tail
        ).path(in: rect)
    }
}

#if os(iOS)
import UIKit
private typealias BubblePlatformImage = Image
private extension BubblePlatformImage {
    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        self = Image(uiImage: image)
    }
}
private func copyText(_ text: String) {
    UIPasteboard.general.string = text
}
#elseif os(macOS)
import AppKit
private typealias BubblePlatformImage = Image
private extension BubblePlatformImage {
    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self = Image(nsImage: image)
    }
}
private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
#endif

struct RoundedCornerShape: Shape {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRight),
            radius: topRight
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            radius: bottomRight
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            radius: bottomLeft
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + topLeft, y: rect.minY),
            radius: topLeft
        )

        return path
    }
}

#Preview {
    VStack(spacing: 20) {
        MessageBubble(message: ChatMessage(
            text: "Hello! I'm your AI assistant. How can I help you today?",
            sender: .agent
        ))
        MessageBubble(message: ChatMessage(
            text: "What can you do?",
            sender: .user
        ))
    }
    .padding()
    .background(AppColors.background)
}
