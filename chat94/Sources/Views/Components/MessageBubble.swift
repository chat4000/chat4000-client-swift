import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showsTimestamp = false

    private var isUser: Bool { message.sender == .user }
    private var timestampText: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            messageLayout
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, AppSpacing.messageRowInset)
    }

    @ViewBuilder
    private var messageLayout: some View {
        if showsTimestamp {
            ViewThatFits(in: .horizontal) {
                sideTimestampLayout
                stackedTimestampLayout
            }
        } else {
            bubbleContent
        }
    }

    private var sideTimestampLayout: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                timestampLabel
                bubbleContent
            } else {
                bubbleContent
                timestampLabel
            }
        }
    }

    private var stackedTimestampLayout: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            bubbleContent
            timestampLabel
        }
    }

    private var timestampLabel: some View {
        Text(timestampText)
            .font(AppFonts.timestamp)
            .foregroundStyle(AppColors.textTimestamp)
            .fixedSize()
            .padding(.bottom, 2)
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

            if !message.text.isEmpty {
                Text(message.text)
                    .font(AppFonts.body)
                    .foregroundStyle(isUser ? Color(hex: 0xF3F4F6) : AppColors.agentBubbleText)
                    .textSelection(.enabled)
#if os(iOS)
                    .onTapGesture {
                        showsTimestamp.toggle()
                    }
#elseif os(macOS)
                    .onTapGesture(count: 2) {
                        showsTimestamp.toggle()
                    }
#endif
                    .contextMenu {
                        Button("Copy") {
                            copyText(message.text)
                        }
                    }
            }
        }
        .padding(.horizontal, AppSpacing.messagePaddingH)
        .padding(.vertical, AppSpacing.messagePaddingV)
        .background(isUser ? AppColors.background : AppColors.agentBubble)
        .clipShape(BubbleShape(isUser: isUser))
        .overlay(
            BubbleShape(isUser: isUser)
                .stroke(isUser ? Color(hex: 0x71767A) : .clear, lineWidth: 1.5)
        )
    }

    private var contentSpacing: CGFloat {
        let contentCount = [
            message.imageData != nil,
            message.audioData != nil,
            !message.text.isEmpty,
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

        if isUser {
            // User: small radius on bottom-right
            return RoundedCornerShape(
                topLeft: r, topRight: r,
                bottomLeft: r, bottomRight: tail
            ).path(in: rect)
        } else {
            // Agent: small radius on bottom-left
            return RoundedCornerShape(
                topLeft: r, topRight: r,
                bottomLeft: tail, bottomRight: r
            ).path(in: rect)
        }
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
