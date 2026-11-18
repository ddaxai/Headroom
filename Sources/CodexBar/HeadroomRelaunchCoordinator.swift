import AppKit
import CodexBarCore
import Foundation

struct HeadroomRelaunchCommand: Equatable {
    let executablePath: String
    let arguments: [String]
}

enum HeadroomRelaunchCoordinator {
    private static let shellPath = "/bin/sh"
    private static let relaunchScript = """
    sleep 0.25
    while kill -0 "$1" 2>/dev/null; do sleep 0.1; done
    exec /usr/bin/open "$2"
    """

    static func relaunchCommand(
        parentProcessIdentifier: Int32,
        bundlePath: String) -> HeadroomRelaunchCommand
    {
        HeadroomRelaunchCommand(
            executablePath: self.shellPath,
            arguments: [
                "-c",
                self.relaunchScript,
                "headroom-relaunch",
                String(parentProcessIdentifier),
                bundlePath,
            ])
    }

    @discardableResult
    @MainActor
    static func scheduleRelaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        parentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier)
        -> Bool
    {
        guard bundleURL.pathExtension == "app" else {
            CodexBarLog.logger(LogCategories.app).error(
                "Cannot schedule Headroom relaunch from an unbundled executable",
                metadata: ["path": bundleURL.path])
            return false
        }

        let command = self.relaunchCommand(
            parentProcessIdentifier: parentProcessIdentifier,
            bundlePath: bundleURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            CodexBarLog.logger(LogCategories.app).error(
                "Failed to schedule Headroom relaunch",
                metadata: ["error": error.localizedDescription])
            return false
        }
    }
}
