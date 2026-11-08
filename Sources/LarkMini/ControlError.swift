import Foundation

enum ControlError {
    static func message(_ value: Any?) -> String {
        if let object = value as? [String: Any] {
            let code = object["code"] as? String
            if code == "DAEMON_UNREACHABLE" { return "Can't reach the Control daemon right now (DAEMON_UNREACHABLE)" }
            for key in ["message", "error", "reason", "cause"] {
                if let nested = object[key] {
                    let text = message(nested)
                    if text != fallback { return code.map { "\(text) (\($0))" } ?? text }
                }
            }
            return code ?? fallback
        }
        guard let raw = value as? String else { return fallback }
        let text = raw.hasPrefix("Error: ") ? String(raw.dropFirst(7)) : raw
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { return message(json) }
        if text.contains("[object Object]") || text.isEmpty { return fallback }
        return String(text.split(separator: "\n").first ?? "").prefix(500).description
    }
    static let fallback = "Can't read Control right now. Refresh to retry."

    // Preserve only structured code/message/reason, never serialize arbitrary RPC payloads.
    static let script = #"""
    const errorReason = (value, depth = 0) => {
      if (depth > 5 || value == null) return "Can't read Control right now. Refresh to retry.";
      if (typeof value === 'string') {
        try { return errorReason(JSON.parse(value), depth + 1); } catch {}
        return value.includes('[object Object]') ? "Can't read Control right now. Refresh to retry." : value.split('\n')[0].slice(0, 500);
      }
      if (typeof value !== 'object') return "Can't read Control right now. Refresh to retry.";
      if (value.code === 'DAEMON_UNREACHABLE') return "Can't reach the Control daemon right now (DAEMON_UNREACHABLE)";
      const detail = value.message ?? value.error ?? value.reason ?? value.cause;
      return detail != null ? errorReason(detail, depth + 1) + (typeof value.code === 'string' ? ` (${value.code})` : '') :
        (typeof value.code === 'string' ? value.code : "Can't read Control right now. Refresh to retry.");
    };
    """#
}
