import Foundation

enum HTMLCardSanitizer {
    private static let allowedElementNames: Set<String> = [
        "a", "article", "b", "blockquote", "br", "code", "div", "em", "h1", "h2",
        "h3", "h4", "h5", "h6", "hr", "i", "li", "mark", "ol", "p", "pre",
        "section", "small", "s", "span", "strong", "table", "tbody", "td", "th",
        "thead", "tr", "u", "ul"
    ]
    private static let voidElementNames: Set<String> = ["br", "hr"]
    private static let blockedContainerRegex: NSRegularExpression = makeRegex(
        #"<\s*(script|style|iframe|embed|object|form|select|textarea|video|audio|picture|svg|math)\b[^>]*>.*?<\s*/\s*\1\s*>"#
    )
    private static let blockedTagRegex: NSRegularExpression = makeRegex(
        #"<\s*/?\s*(script|style|iframe|embed|object|link|meta|base|input|button|source|img|use|track|canvas)\b[^>]*>"#
    )
    private static let commentRegex: NSRegularExpression = makeRegex(#"<!--.*?-->"#)
    private static let tagRegex: NSRegularExpression = makeRegex(
        #"<\s*(/)?\s*([A-Za-z][A-Za-z0-9:-]*)([^>]*)>"#
    )
    private static let hrefRegex: NSRegularExpression = makeRegex(
        #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    )

    static func sanitize(_ html: String) -> String {
        let withoutComments = replace(commentRegex, in: html, with: "")
        let withoutContainers = replace(blockedContainerRegex, in: withoutComments, with: "")
        let withoutBlockedTags = replace(blockedTagRegex, in: withoutContainers, with: "")
        return sanitizeTags(in: withoutBlockedTags)
    }

    static func plainText(from html: String) -> String {
        let text = replace(tagRegex, in: html, with: "")
        return decodeBasicEntities(text)
    }

    private static func sanitizeTags(in html: String) -> String {
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        let matches = tagRegex.matches(in: html, options: [], range: range)
        var output = ""
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let length = match.range.location - cursor
                output += nsHTML.substring(with: NSRange(location: cursor, length: length))
            }

            output += sanitizedTag(from: match, in: nsHTML)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsHTML.length {
            output += nsHTML.substring(from: cursor)
        }

        return output
    }

    private static func sanitizedTag(from match: NSTextCheckingResult, in html: NSString) -> String {
        let closingRange = match.range(at: 1)
        let nameRange = match.range(at: 2)
        guard nameRange.location != NSNotFound else { return "" }

        let name = html.substring(with: nameRange).lowercased()
        guard allowedElementNames.contains(name) else { return "" }

        if closingRange.location != NSNotFound {
            return voidElementNames.contains(name) ? "" : "</\(name)>"
        }

        if voidElementNames.contains(name) {
            return "<\(name)>"
        }

        if name == "a", let href = safeHref(from: match, in: html) {
            return #"<a href="\#(escapeAttribute(href))">"#
        }

        return "<\(name)>"
    }

    private static func safeHref(from match: NSTextCheckingResult, in html: NSString) -> String? {
        let attrsRange = match.range(at: 3)
        guard attrsRange.location != NSNotFound else { return nil }

        let attrs = html.substring(with: attrsRange)
        let nsAttrs = attrs as NSString
        let attrMatches = hrefRegex.matches(
            in: attrs,
            options: [],
            range: NSRange(location: 0, length: nsAttrs.length)
        )
        guard let attrMatch = attrMatches.first else { return nil }

        for index in 1...3 {
            let valueRange = attrMatch.range(at: index)
            if valueRange.location != NSNotFound {
                return allowedHref(nsAttrs.substring(with: valueRange))
            }
        }

        return nil
    }

    private static func allowedHref(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()

        if normalized.hasPrefix("javascript:") {
            return nil
        }

        guard let colon = normalized.firstIndex(of: ":") else {
            return trimmed
        }

        let scheme = String(normalized[..<colon])
        return ["http", "https", "mailto"].contains(scheme) ? trimmed : nil
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func decodeBasicEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        } catch {
            preconditionFailure("Invalid hard-coded HTML card sanitizer regex: \(pattern)")
        }
    }
}
