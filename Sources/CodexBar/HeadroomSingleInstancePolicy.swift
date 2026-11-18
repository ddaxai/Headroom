import AppKit
import Darwin

enum HeadroomSingleInstanceDecision: Equatable {
    case launch
    case activateExisting
}

enum HeadroomSingleInstancePolicy {
    private static let lockFileName = "headroom-\(HeadroomIdentity.bundleIdentifier).instance.lock"
    private nonisolated(unsafe) static var lockFileDescriptor: Int32?

    static func decision(
        currentProcessIdentifier: Int32,
        runningProcessIdentifiers: [Int32]) -> HeadroomSingleInstanceDecision
    {
        runningProcessIdentifiers.contains { $0 != currentProcessIdentifier }
            ? .activateExisting
            : .launch
    }

    /// Returns false when another Headroom process already owns the status item.
    /// This is intentionally limited to the current bundle identifier: legacy CodexBar is removed by
    /// the installer/cleanup path and must not be treated as a competing provider installation.
    @MainActor
    static func acquire() -> Bool {
        // NSRunningApplication is normally enough, but two paths opened at the same instant can
        // both observe an empty process list. A non-blocking advisory lock closes that startup race;
        // the kernel releases it automatically if the process exits or crashes.
        guard self.acquireProcessLock() else {
            self.activateExistingInstance()
            return false
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: HeadroomIdentity.bundleIdentifier)
        let existing = running.first { application in
            application.processIdentifier != currentProcessIdentifier
        }
        guard let existing else { return true }
        self.releaseProcessLock()
        existing.activate(options: [])
        return false
    }

    private static func acquireProcessLock() -> Bool {
        guard self.lockFileDescriptor == nil else { return true }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(self.lockFileName)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        self.lockFileDescriptor = descriptor
        return true
    }

    private static func releaseProcessLock() {
        guard let descriptor = self.lockFileDescriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        self.lockFileDescriptor = nil
    }

    private static func activateExistingInstance() {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: HeadroomIdentity.bundleIdentifier)
            .first { $0.processIdentifier != currentProcessIdentifier }?
            .activate(options: [])
    }
}
