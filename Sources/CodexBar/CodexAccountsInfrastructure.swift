import CodexBarCore
import Foundation

protocol ManagedCodexHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

protocol ManagedCodexLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result
}

struct ManagedCodexHomeFactory: ManagedCodexHomeProducing {
    let root: URL

    init(root: URL = Self.defaultRootURL(), fileManager: FileManager = .default) {
        let standardizedRoot = root.standardizedFileURL
        if standardizedRoot.path != root.path {
            self.root = standardizedRoot
        } else {
            self.root = root
        }
        _ = fileManager
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(rootPrefix), targetPath != rootPath else {
            throw ManagedCodexAccountServiceError.unsafeManagedHome(url.path)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

struct DefaultManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result {
        await CodexLoginRunner.run(homePath: homePath, timeout: timeout)
    }
}
