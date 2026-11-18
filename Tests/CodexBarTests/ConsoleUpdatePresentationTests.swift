import Foundation
import Testing
@testable import CodexBar

struct ConsoleUpdatePresentationTests {
    @Test
    func `sparkle check date wins over the manual fallback`() {
        let sparkleDate = Date(timeIntervalSince1970: 20)
        #expect(
            ConsoleUpdatePresentation.lastCheckDate(
                sparkleDate: sparkleDate,
                manualTimestamp: 10) == sparkleDate)
        #expect(
            ConsoleUpdatePresentation.lastCheckDate(
                sparkleDate: nil,
                manualTimestamp: 10) == Date(timeIntervalSince1970: 10))
        #expect(
            ConsoleUpdatePresentation.lastCheckDate(
                sparkleDate: nil,
                manualTimestamp: 0) == nil)
    }
}
