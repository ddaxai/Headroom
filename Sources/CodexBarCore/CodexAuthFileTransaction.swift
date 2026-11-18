#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public protocol CodexAuthFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

public struct LocalCodexAuthFileSystem: CodexAuthFileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagedURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).headroom-staged-\(UUID().uuidString)",
            isDirectory: false)
        let descriptor = stagedURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw Self.posixError(code: errno, path: stagedURL.path)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var handleIsOpen = true
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.posixError(code: errno, path: stagedURL.path)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            handleIsOpen = false
            try Self.renameItem(at: stagedURL, to: url)
        } catch {
            if handleIsOpen {
                try? handle.close()
            }
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    public func removeItem(at url: URL) throws {
        guard self.fileExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func renameItem(at sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw self.posixError(code: errno, path: destinationURL.path)
        }
    }

    private static func posixError(code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path])
    }
}

public enum CodexAuthFileTransactionError: Error, Equatable, Sendable {
    case readbackMismatch(URL)
    case rollbackReadbackMismatch(URL)
    case rollbackFailed(URL)
}

public struct CodexAuthFileTransaction: Sendable {
    public struct Backup: Equatable, Sendable {
        public let url: URL
        public let originalData: Data?

        public init(url: URL, originalData: Data?) {
            self.url = url
            self.originalData = originalData
        }
    }

    private let fileSystem: any CodexAuthFileSystem

    public init(fileSystem: any CodexAuthFileSystem = LocalCodexAuthFileSystem()) {
        self.fileSystem = fileSystem
    }

    @discardableResult
    public func replace(_ data: Data, at url: URL) throws -> Backup {
        let backup = Backup(
            url: url,
            originalData: self.fileSystem.fileExists(at: url) ? try self.fileSystem.readData(at: url) : nil)
        do {
            try self.fileSystem.writeAtomically(data, to: url)
            guard try self.fileSystem.readData(at: url) == data else {
                throw CodexAuthFileTransactionError.readbackMismatch(url)
            }
            return backup
        } catch {
            do {
                try self.rollback(backup)
            } catch {
                throw CodexAuthFileTransactionError.rollbackFailed(url)
            }
            throw error
        }
    }

    public func rollback(_ backup: Backup) throws {
        if let originalData = backup.originalData {
            try self.fileSystem.writeAtomically(originalData, to: backup.url)
            guard try self.fileSystem.readData(at: backup.url) == originalData else {
                throw CodexAuthFileTransactionError.rollbackReadbackMismatch(backup.url)
            }
        } else {
            try self.fileSystem.removeItem(at: backup.url)
            guard !self.fileSystem.fileExists(at: backup.url) else {
                throw CodexAuthFileTransactionError.rollbackReadbackMismatch(backup.url)
            }
        }
    }
}
