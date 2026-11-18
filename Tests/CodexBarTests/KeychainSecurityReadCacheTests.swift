import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodexBarCore

#if os(macOS) && DEBUG
struct KeychainSecurityReadCacheTests {
    @Test
    func `different keychain queries share one serialized backend lane`() async {
        let probe = KeychainBackendProbe(delay: 0.02)

        let statuses = await KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            await KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                await withTaskGroup(of: OSStatus.self, returning: [OSStatus].self) { group in
                    for index in 0..<16 {
                        group.addTask {
                            var result: CFTypeRef?
                            return KeychainSecurity.copyMatching(
                                Self.cacheableQuery(account: "serialized-\(index)"),
                                &result)
                        }
                    }
                    var values: [OSStatus] = []
                    for await status in group {
                        values.append(status)
                    }
                    return values
                }
            }
        }

        #expect(statuses.count == 16)
        #expect(statuses.allSatisfy { $0 == errSecSuccess })
        #expect(probe.invocationCount == 16)
        #expect(probe.maximumConcurrentInvocations == 1)
    }

    @Test
    func `concurrent identical reads share one backend result`() async {
        let probe = KeychainBackendProbe(payloads: [Data("cached-value".utf8)], delay: 0.02)

        let values = await KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            await KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
                    for _ in 0..<16 {
                        group.addTask {
                            var result: CFTypeRef?
                            let status = KeychainSecurity.copyMatching(
                                Self.cacheableQuery(account: "shared"),
                                &result)
                            #expect(status == errSecSuccess)
                            return result as? Data
                        }
                    }
                    var results: [Data?] = []
                    for await result in group {
                        results.append(result)
                    }
                    return results
                }
            }
        }

        #expect(probe.invocationCount == 1)
        #expect(values.count == 16)
        #expect(values.allSatisfy { $0 == Data("cached-value".utf8) })
    }

    @Test
    func `profile invalidation forces the next matching read back to the backend`() {
        let probe = KeychainBackendProbe(payloads: [Data("v1".utf8), Data("v2".utf8)])

        let values = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                var firstResult: CFTypeRef?
                _ = KeychainSecurity.copyMatching(Self.cacheableQuery(account: "profile"), &firstResult)
                var cachedResult: CFTypeRef?
                _ = KeychainSecurity.copyMatching(Self.cacheableQuery(account: "profile"), &cachedResult)

                KeychainSecurity.invalidateCopyMatchingCacheForProfileChange()

                var refreshedResult: CFTypeRef?
                _ = KeychainSecurity.copyMatching(Self.cacheableQuery(account: "profile"), &refreshedResult)
                return [firstResult as? Data, cachedResult as? Data, refreshedResult as? Data]
            }
        }

        #expect(probe.invocationCount == 2)
        #expect(values == [Data("v1".utf8), Data("v1".utf8), Data("v2".utf8)])
    }

    @Test
    func `missing and authorization failures are cached for the process session`() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            let probe = KeychainBackendProbe(status: status)

            let statuses = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
                KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                    (0..<2).map { _ in
                        var result: CFTypeRef? = "stale" as CFString
                        let value = KeychainSecurity.copyMatching(
                            Self.cacheableQuery(account: "cached-status-\(status)"),
                            &result)
                        #expect(result == nil)
                        return value
                    }
                }
            }

            #expect(statuses == [status, status])
            #expect(probe.invocationCount == 1)
        }
    }

    @Test
    func `fresh no UI contexts produce one semantic cache key`() {
        let probe = KeychainBackendProbe(payloads: [Data("no-ui".utf8)])

        KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                for _ in 0..<2 {
                    var query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "com.ddaxia.headroom.test.no-ui",
                        kSecAttrAccount as String: "account",
                        kSecMatchLimit as String: kSecMatchLimitOne,
                        kSecReturnData as String: true,
                    ]
                    KeychainNoUIQuery.apply(to: &query)
                    var result: CFTypeRef?
                    #expect(KeychainSecurity.copyMatching(query as CFDictionary, &result) == errSecSuccess)
                }
            }
        }

        #expect(probe.invocationCount == 1)
    }

    @Test
    func `access groups remain distinct cache identities`() {
        let probe = KeychainBackendProbe(payloads: [Data("first".utf8), Data("second".utf8)])

        KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                for accessGroup in ["group.one", "group.two"] {
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "com.ddaxia.headroom.test.access-group",
                        kSecAttrAccount as String: "account",
                        kSecAttrAccessGroup as String: accessGroup,
                        kSecMatchLimit as String: kSecMatchLimitOne,
                        kSecReturnData as String: true,
                    ]
                    var result: CFTypeRef?
                    #expect(KeychainSecurity.copyMatching(query as CFDictionary, &result) == errSecSuccess)
                }
            }
        }

        #expect(probe.invocationCount == 2)
    }

    @Test
    func `unknown serializable queries always reach the backend`() {
        let probe = KeychainBackendProbe()

        KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                for _ in 0..<2 {
                    var result: CFTypeRef?
                    _ = KeychainSecurity.copyMatching(
                        ["unknown-selector": "value"] as CFDictionary,
                        &result)
                }
            }
        }

        #expect(probe.invocationCount == 2)
    }

    @Test
    func `enumerating queries always reach the backend`() {
        let probe = KeychainBackendProbe()
        var query = Self.cacheableQueryDictionary(account: "enumeration")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                for _ in 0..<2 {
                    var result: CFTypeRef?
                    _ = KeychainSecurity.copyMatching(query as CFDictionary, &result)
                }
            }
        }

        #expect(probe.invocationCount == 2)
    }

    @Test
    func `persistent reference queries always reach the backend`() {
        let first = Data("external-v1".utf8)
        let second = Data("external-v2".utf8)
        let probe = KeychainBackendProbe(payloads: [first, second])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: Data([0x01, 0x02, 0x03]),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        let values = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                (0..<2).map { _ in
                    var result: CFTypeRef?
                    #expect(KeychainSecurity.copyMatching(
                        query as CFDictionary,
                        &result) == errSecSuccess)
                    return result as? Data
                }
            }
        }

        #expect(probe.invocationCount == 2)
        #expect(values == [first, second])
    }

    @Test
    func `cached result survives the first callers lifetime`() {
        let probe = KeychainBackendProbe(payloads: [Data("retained-value".utf8)])

        let replayed = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainSecurity.withCopyMatchingOverrideForTesting(probe.invoke) {
                autoreleasepool {
                    var firstResult: CFTypeRef?
                    #expect(KeychainSecurity.copyMatching(
                        Self.cacheableQuery(account: "lifetime"),
                        &firstResult) == errSecSuccess)
                    #expect(firstResult as? Data == Data("retained-value".utf8))
                }

                var replayedResult: CFTypeRef?
                #expect(KeychainSecurity.copyMatching(
                    Self.cacheableQuery(account: "lifetime"),
                    &replayedResult) == errSecSuccess)
                return replayedResult as? Data
            }
        }

        #expect(probe.invocationCount == 1)
        #expect(replayed == Data("retained-value".utf8))
    }

    private static func cacheableQuery(account: String) -> CFDictionary {
        self.cacheableQueryDictionary(account: account) as CFDictionary
    }

    private static func cacheableQueryDictionary(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ddaxia.headroom.test",
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
    }
}

private final class KeychainBackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let status: OSStatus
    private let payloads: [Data]
    private let delay: TimeInterval
    private var activeInvocations = 0
    private var recordedInvocationCount = 0
    private var recordedMaximumConcurrentInvocations = 0

    init(
        status: OSStatus = errSecSuccess,
        payloads: [Data] = [Data("value".utf8)],
        delay: TimeInterval = 0)
    {
        self.status = status
        self.payloads = payloads
        self.delay = delay
    }

    var invocationCount: Int {
        self.lock.withLock { self.recordedInvocationCount }
    }

    var maximumConcurrentInvocations: Int {
        self.lock.withLock { self.recordedMaximumConcurrentInvocations }
    }

    func invoke(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        let invocationIndex = self.lock.withLock { () -> Int in
            self.activeInvocations += 1
            self.recordedInvocationCount += 1
            self.recordedMaximumConcurrentInvocations = max(
                self.recordedMaximumConcurrentInvocations,
                self.activeInvocations)
            return self.recordedInvocationCount - 1
        }
        if self.delay > 0 {
            Thread.sleep(forTimeInterval: self.delay)
        }
        defer {
            self.lock.withLock {
                self.activeInvocations -= 1
            }
        }

        guard self.status == errSecSuccess else {
            result?.pointee = nil
            return self.status
        }
        let payload = self.payloads[min(invocationIndex, self.payloads.count - 1)] as CFData
        result?.pointee = payload
        return self.status
    }
}
#endif
