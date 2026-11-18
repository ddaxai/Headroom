import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct SessionQuotaNotificationLogicTests {
    @Test
    func `does nothing without previous value`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: nil, currentRemaining: 0)
        #expect(transition == .none)
    }

    @Test
    func `detects depleted transition`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 12, currentRemaining: 0)
        #expect(transition == .depleted)
    }

    @Test
    func `detects restored transition`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 5)
        #expect(transition == .restored)
    }

    @Test
    func `ignores non transitions`() {
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 0) == .none)
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 10, currentRemaining: 10) == .none)
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 10, currentRemaining: 9) == .none)
    }

    @Test
    func `treats tiny positive remaining as depleted`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 0.00001)
        #expect(transition == .none)
    }

    @Test
    func `depleted notification copy follows Simplified Chinese app language`() {
        Self.withAppLanguage("zh-Hans") {
            let copy = SessionQuotaNotificationLogic.notificationCopy(
                transition: .depleted,
                providerName: "Codex")

            #expect(copy.title == "Codex 会话额度已用尽")
            #expect(copy.body == "剩余 0%。可用时会通知你。")
        }
    }

    @Test
    func `restored notification copy follows Simplified Chinese app language`() {
        Self.withAppLanguage("zh-Hans") {
            let copy = SessionQuotaNotificationLogic.notificationCopy(
                transition: .restored,
                providerName: "Codex")

            #expect(copy.title == "Codex 会话已恢复")
            #expect(copy.body == "会话额度已重新可用。")
        }
    }

    private static func withAppLanguage(_ language: String, perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language, operation: body)
    }
}
