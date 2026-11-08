import Foundation

/// Plain previews only; never render HTML or load linked resources.
enum LarkPreview {
    static func plain(_ value: String) -> String {
        var text = String(value.prefix(20_000))
        text = text.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</?(?:p|div|br|li|h[1-6])\b[^>]*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&"]
        for key in ["&nbsp;", "&quot;", "&#39;", "&apos;", "&lt;", "&gt;", "&amp;"] { text = text.replacingOccurrences(of: key, with: entities[key]!) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digits = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
                let number = String(text[digits])
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
