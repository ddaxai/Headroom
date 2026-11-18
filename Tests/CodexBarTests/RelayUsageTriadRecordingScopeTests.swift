import CryptoKit
import Foundation
import Testing
#if DEBUG
import SnapshotTesting
@testable import CodexBar
#endif

@Suite("Relay triad snapshot recording scope")
struct RelayUsageTriadRecordingScopeTests {
    @Test
    func `triad recording switch is absent from every legacy snapshot suite`() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let snapshotFiles = try FileManager.default.contentsOfDirectory(
            at: testsDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("SnapshotTests.swift") }
        let recordingKey = "CODEXBAR_RECORD_RELAY_TRIAD_SNAPSHOTS"
        let readers = try snapshotFiles.compactMap { file -> String? in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.contains(recordingKey) ? file.lastPathComponent : nil
        }

        #expect(readers == ["RelayUsageTriadSnapshotTests.swift"])
        #expect(!readers.contains("HeadroomDesignGallerySnapshotTests.swift"))
    }

    #if DEBUG
    @MainActor
    @Test
    func `triad recording switch cannot rewrite the seventeen frozen gallery references`() throws {
        let key = "CODEXBAR_RECORD_RELAY_TRIAD_SNAPSHOTS"
        let originalValue = ProcessInfo.processInfo.environment[key]
        defer {
            if let originalValue {
                setenv(key, originalValue, 1)
            } else {
                unsetenv(key)
            }
        }
        setenv(key, "1", 1)

        let urls = HeadroomDesignGallerySnapshotTests.legacyReferenceURLs
        #expect(urls.count == 17)
        let before = try urls.map(Self.referenceState)

        let recordMode = HeadroomDesignGallerySnapshotTests.legacyRecordMode
        try #require(recordMode == .never)
        try HeadroomDesignGallerySnapshotTests.assertFrozenLegacyReferences()

        let after = try urls.map(Self.referenceState)
        #expect(after == before)
    }

    private struct ReferenceState: Equatable {
        let digest: String
        let modificationDate: Date
    }

    private static func referenceState(_ url: URL) throws -> ReferenceState {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ReferenceState(digest: digest, modificationDate: modificationDate)
    }
    #endif
}
