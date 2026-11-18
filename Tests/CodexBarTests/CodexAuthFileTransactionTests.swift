import CodexBarCore
import Foundation
import Testing

struct CodexAuthFileTransactionTests {
    @Test
    func `successful replacement returns original bytes and verifies readback`() throws {
        let fixture = try AuthTransactionFixture()
        defer { fixture.cleanup() }
        let original = Data([0x00, 0x41, 0xFF, 0x0A])
        let replacement = Data("replacement-auth".utf8)
        try original.write(to: fixture.authURL)

        let backup = try CodexAuthFileTransaction().replace(replacement, at: fixture.authURL)

        #expect(backup.originalData == original)
        #expect(try Data(contentsOf: fixture.authURL) == replacement)
    }

    @Test
    func `corrupt readback restores original bytes exactly`() throws {
        let fixture = try AuthTransactionFixture()
        defer { fixture.cleanup() }
        let original = Data([0x00, 0x41, 0xFF, 0x0A])
        try original.write(to: fixture.authURL)
        let fileSystem = FailingAuthFileSystem(targetURL: fixture.authURL, failure: .corruptAfterWrite)
        let transaction = CodexAuthFileTransaction(fileSystem: fileSystem)

        #expect(throws: CodexAuthFileTransactionError.readbackMismatch(fixture.authURL)) {
            try transaction.replace(Data("replacement-auth".utf8), at: fixture.authURL)
        }
        #expect(try Data(contentsOf: fixture.authURL) == original)
    }

    @Test
    func `partial write failure restores original bytes exactly`() throws {
        let fixture = try AuthTransactionFixture()
        defer { fixture.cleanup() }
        let original = Data([0x10, 0x20, 0x30, 0x40])
        try original.write(to: fixture.authURL)
        let fileSystem = FailingAuthFileSystem(targetURL: fixture.authURL, failure: .throwAfterPartialWrite)
        let transaction = CodexAuthFileTransaction(fileSystem: fileSystem)

        #expect(throws: AuthTransactionTestError.injected) {
            try transaction.replace(Data("replacement-auth".utf8), at: fixture.authURL)
        }
        #expect(try Data(contentsOf: fixture.authURL) == original)
    }
}

private struct AuthTransactionFixture {
    let root: URL
    let authURL: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-auth-transaction-\(UUID().uuidString)", isDirectory: true)
        self.authURL = self.root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private final class FailingAuthFileSystem: CodexAuthFileSystem, @unchecked Sendable {
    enum Failure {
        case corruptAfterWrite
        case throwAfterPartialWrite
    }

    private let base = LocalCodexAuthFileSystem()
    private let targetURL: URL
    private let failure: Failure
    private let lock = NSLock()
    private var hasFailed = false

    init(targetURL: URL, failure: Failure) {
        self.targetURL = targetURL
        self.failure = failure
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try self.base.readData(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        self.lock.lock()
        let shouldFail = url == self.targetURL && !self.hasFailed
        if shouldFail { self.hasFailed = true }
        self.lock.unlock()
        guard shouldFail else {
            try self.base.writeAtomically(data, to: url)
            return
        }
        switch self.failure {
        case .corruptAfterWrite:
            try self.base.writeAtomically(Data("corrupt".utf8), to: url)
        case .throwAfterPartialWrite:
            try self.base.writeAtomically(Data("partial".utf8), to: url)
            throw AuthTransactionTestError.injected
        }
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }
}

private enum AuthTransactionTestError: Error {
    case injected
}
