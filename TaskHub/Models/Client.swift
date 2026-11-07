import SwiftUI

/// A client or area of life, used to color-code and filter the board.
/// Items are matched by keyword against their project, title and account name.
struct ClientTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    /// Case-insensitive whole-word matches, e.g. ["RealVNC"] or ["AHX", "Auto Hauler"].
    var keywords: [String]

    var color: Color { Color(hex: colorHex) }

    func matches(_ text: String) -> Bool {
        (keywords + [name]).contains { keyword in
            let k = keyword.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return false }
            let pattern = "(^|[^A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: k) + "($|[^A-Za-z0-9])"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Removes a leading "Client — " / "Client: " prefix, since the card already shows the client.
    func strippingPrefix(from title: String) -> String {
        for keyword in [name] + keywords where !keyword.isEmpty {
            for separator in [" — ", " – ", " - ", ": "] {
                let prefix = keyword + separator
                if title.lowercased().hasPrefix(prefix.lowercased()) {
                    return String(title.dropFirst(prefix.count))
                }
            }
        }
        return title
    }

    static let palette = ["#3b82f6", "#a855f7", "#f97316", "#14b8a6", "#22c55e", "#ec4899", "#eab308", "#ef4444", "#64748b"]

    static let defaults: [ClientTag] = [
        ClientTag(name: "RealVNC", colorHex: "#3b82f6", keywords: ["RealVNC"]),
        ClientTag(name: "Stackit/AHX", colorHex: "#a855f7", keywords: ["AHX", "Auto Hauler Exchange"]),
        ClientTag(name: "Stackit/Czar", colorHex: "#f97316", keywords: ["Czar"]),
        ClientTag(name: "Stackit/Basis", colorHex: "#14b8a6", keywords: ["Stackit/Basis"]),
        ClientTag(name: "Lycoming College", colorHex: "#22c55e", keywords: ["Lycoming"]),
        ClientTag(name: "WorkProud", colorHex: "#ec4899", keywords: ["WorkProud"]),
        ClientTag(name: "Personal/Family", colorHex: "#eab308", keywords: ["Personal", "Family"]),
    ]
}

enum BoardLane: String, Codable, CaseIterable, Identifiable {
    case now, next, someday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Now"
        case .next: return "Next"
        case .someday: return "Someday"
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
