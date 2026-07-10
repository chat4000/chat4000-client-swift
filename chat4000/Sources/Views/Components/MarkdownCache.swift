import Foundation
import SwiftUI

@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private let capacity = 400
    private var values: [String: AttributedString] = [:]
    private var accessOrder: [String] = []

    private init() {}

    func attributed(msgId: String?, text: String) -> AttributedString {
        let key = "\(msgId ?? "nil")|\(text.hashValue)"
        if let cached = values[key] {
            noteAccess(key)
            return cached
        }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            let fallback = AttributedString(text)
            store(fallback, for: key)
            return fallback
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
        }
        store(attributed, for: key)
        return attributed
    }

    private func store(_ value: AttributedString, for key: String) {
        values[key] = value
        noteAccess(key)
        while accessOrder.count > capacity {
            let evicted = accessOrder.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    private func noteAccess(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}
