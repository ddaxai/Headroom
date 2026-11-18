import Foundation

enum ConsoleUpdatePresentation {
    static func lastCheckDate(sparkleDate: Date?, manualTimestamp: Double) -> Date? {
        sparkleDate ?? (manualTimestamp > 0 ? Date(timeIntervalSince1970: manualTimestamp) : nil)
    }
}
