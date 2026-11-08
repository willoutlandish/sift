import Foundation

enum CompanionWindowTitle {
    static func make(path: String, names: [String: String]) -> String {
        let prefix = "/companion/app/"
        guard path.hasPrefix(prefix),
              let component = path.dropFirst(prefix.count).split(separator: "/").first,
              let resource = String(component).removingPercentEncoding,
              let name = names[resource], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Ollie" }
        return "Ollie · \(name)"
    }
}
