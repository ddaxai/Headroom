import Foundation

/// Stable ASCII key used by client configuration files for a relay profile.
///
/// The profile name remains the user-facing label. Client schemas generally require an
/// identifier, so names are transliterated (for example, `梁` becomes `liang`) and then
/// restricted to lowercase ASCII letters, digits, and hyphens.
public enum RelayProviderKey {
    public static func slug(for name: String, fallbackID: UUID? = nil) -> String {
        let transliterated = name.applyingTransform(.toLatin, reverse: false) ?? name
        let folded = transliterated.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))

        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.unicodeScalars.append(UnicodeScalar(scalar.value | 0x20)!)
            case 0x2D, 0x5F, 0x20...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
                pendingSeparator = !result.isEmpty
            default:
                pendingSeparator = !result.isEmpty
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if !trimmed.isEmpty { return trimmed }
        if let fallbackID {
            return "relay-" + String(fallbackID.uuidString.lowercased().prefix(8))
        }
        return "relay"
    }
}
