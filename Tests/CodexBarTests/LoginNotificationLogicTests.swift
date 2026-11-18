import Testing
@testable import CodexBar

@Suite(.serialized)
struct LoginNotificationLogicTests {
    @Test
    func `login success notification copy follows Simplified Chinese app language`() {
        Self.withAppLanguage("zh-Hans") {
            let copy = LoginNotificationLogic.notificationCopy(providerName: "Codex")

            #expect(copy.title == "Codex 登录成功")
            #expect(copy.body == "可以返回应用了，认证已完成。")
        }
    }

    private static func withAppLanguage(_ language: String, perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language, operation: body)
    }
}
