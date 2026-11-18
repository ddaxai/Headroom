import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS) && DEBUG
import Security

struct KeychainReadDiagnosticsTests {
    @Test
    func `copy matching records timestamped reads grouped by call site`() {
        let recorder = KeychainReadDiagnostics.Recorder()

        let events = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainReadDiagnostics.withRecorderForTesting(recorder) {
                KeychainSecurity.withCopyMatchingOverrideForTesting { _, _ in errSecItemNotFound } operation: {
                    var firstResult: CFTypeRef?
                    _ = KeychainSecurity.copyMatching(["diagnostic-query": 1] as CFDictionary, &firstResult)

                    var secondResult: CFTypeRef?
                    _ = KeychainSecurity.copyMatching(["diagnostic-query": 2] as CFDictionary, &secondResult)
                }

                return KeychainReadDiagnostics.snapshot()
            }
        }

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.timestamp.timeIntervalSince1970 > 0 })
        #expect(events.map(\.callSite.fileID) == [#fileID, #fileID])
        #expect(events.map(\.callSite.function).allSatisfy {
            $0.contains("copy matching records timestamped reads grouped by call site")
        })
        #expect(Set(events.map(\.callSite.line)).count == 2)

        let groups = KeychainReadDiagnostics.groupedSnapshot(events)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.count == 1 })
        #expect(groups.flatMap(\.timestamps).count == 2)
    }

    @Test
    func `concurrent reads do not lose diagnostic events`() async {
        let recorder = KeychainReadDiagnostics.Recorder()

        let events = await KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            await KeychainReadDiagnostics.withRecorderForTesting(recorder) {
                await KeychainSecurity.withCopyMatchingOverrideForTesting { _, _ in errSecItemNotFound } operation: {
                    await withTaskGroup(of: Void.self) { group in
                        for index in 0..<64 {
                            group.addTask {
                                var result: CFTypeRef?
                                _ = KeychainSecurity.copyMatching(
                                    ["diagnostic-query": index] as CFDictionary,
                                    &result)
                            }
                        }
                    }
                    return KeychainReadDiagnostics.snapshot()
                }
            }
        }

        #expect(events.count == 64)
        #expect(KeychainReadDiagnostics.groupedSnapshot(events).map(\.count) == [64])
    }

    @Test
    func `production wrapper preserves its keychain call site`() {
        let recorder = KeychainReadDiagnostics.Recorder()

        let events = KeychainSecurity.withIsolatedCopyMatchingCacheForTesting {
            KeychainReadDiagnostics.withRecorderForTesting(recorder) {
                KeychainSecurity.withCopyMatchingOverrideForTesting { _, _ in errSecItemNotFound } operation: {
                    _ = ClaudeOAuthKeychainQueryTiming.copyMatching([:])
                }
                return KeychainReadDiagnostics.snapshot()
            }
        }

        #expect(events.count == 1)
        #expect(events[0].callSite.fileID.hasSuffix("/ClaudeOAuthKeychainQueryTiming.swift"))
        #expect(events[0].callSite.function.contains("copyMatching"))
        #expect(events[0].callSite.line > 0)
        #expect(KeychainReadDiagnostics.groupedSnapshot(events).map(\.count) == [1])
    }

    @Test
    func `recorder keeps newest events in order after wrapping`() {
        let recorder = KeychainReadDiagnostics.Recorder()
        let callSite = KeychainReadDiagnostics.CallSite(
            fileID: "CodexBarTests/KeychainReadDiagnosticsTests.swift",
            function: "ringBufferProbe()",
            line: 1)

        for index in 0...4096 {
            recorder.record(KeychainReadDiagnostics.Event(
                callSite: callSite,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))))
        }

        let events = recorder.snapshot()
        #expect(events.count == 4096)
        #expect(events.first?.timestamp == Date(timeIntervalSince1970: 1))
        #expect(events.last?.timestamp == Date(timeIntervalSince1970: 4096))
    }
}
#endif
