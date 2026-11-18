import Foundation
import Observation

struct HeadroomSourceUpdateConfiguration: Equatable, Sendable {
    let sourceDirectory: URL
    let branch: String
    let scriptURL: URL
    let logURL: URL
    let cloneCommand: String

    static var `default`: Self {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let sourceDirectory = homeDirectory.appending(path: "Developer/Headroom", directoryHint: .isDirectory)
        return self.make(
            sourceDirectory: sourceDirectory,
            branch: "main")
    }

    static func make(sourceDirectory: URL, branch: String) -> Self {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let defaultSourceDirectory = homeDirectory.appending(path: "Developer/Headroom", directoryHint: .isDirectory)
        let commandPath = sourceDirectory.standardizedFileURL == defaultSourceDirectory.standardizedFileURL
            ? "~/Developer/Headroom"
            : Self.shellQuoted(sourceDirectory.path)
        return Self(
            sourceDirectory: sourceDirectory,
            branch: branch,
            scriptURL: sourceDirectory.appending(path: "Scripts/update_headroom.sh"),
            logURL: homeDirectory.appending(path: "Library/Logs/Headroom/update.log"),
            cloneCommand: "git clone https://github.com/ddaxai/Headroom.git \(commandPath) && " +
                "cd \(commandPath) && git checkout \(branch)")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum HeadroomSourceUpdateStage: Equatable, Sendable {
    case preflight
    case fetching
    case comparing
    case syncing
    case building
    case stopping
    case installing
    case scheduled
    case finished

    static func parse(_ line: String) -> Self? {
        let normalized = line.lowercased()
        if normalized.contains("[headroom] fetching origin") || normalized.contains("[fetch]") {
            return .fetching
        }
        if normalized.contains("[headroom] building headroom") || normalized.contains("[package]") {
            return .building
        }
        if normalized.contains("[headroom] installing headroom") || normalized.contains("[install]") {
            return .installing
        }
        if normalized.contains("[preflight]") { return .preflight }
        if normalized.contains("[compare]") { return .comparing }
        if normalized.contains("[sync]") { return .syncing }
        if normalized.contains("[stop]") { return .stopping }
        if normalized.contains("[finalize]") || normalized.contains("[scheduled]") { return .scheduled }
        if normalized.contains("[done]") { return .finished }
        return nil
    }
}

enum HeadroomSourceUpdateStatusKind: String, Equatable, Sendable {
    case available
    case upToDate = "up_to_date"
    case scheduled
    case completed
    case failed
    case localAhead = "local_ahead"
    case diverged
}

struct HeadroomSourceUpdateStatus: Equatable, Sendable {
    let kind: HeadroomSourceUpdateStatusKind
    let localCommit: String?
    let remoteCommit: String?
    let behind: Int?
    let reason: String?

    static func parse(_ line: String) -> Self? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first,
              first.hasPrefix("HEADROOM_UPDATE_STATUS=")
        else { return nil }
        let rawKind = String(first.dropFirst("HEADROOM_UPDATE_STATUS=".count))
        guard let kind = HeadroomSourceUpdateStatusKind(rawValue: rawKind), !rawKind.isEmpty else {
            return nil
        }
        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0]] = pair[1]
        }
        let behind = values["behind"].flatMap(Int.init)
        return Self(
            kind: kind,
            localCommit: values["local"],
            remoteCommit: values["remote"],
            behind: behind,
            reason: values["reason"])
    }

    static func latest(in text: String) -> Self? {
        text.split(whereSeparator: { $0.isNewline })
            .reversed()
            .compactMap { Self.parse(String($0)) }
            .first
    }
}

struct HeadroomSourceUpdateOptions: Equatable, Sendable {
    var ignoreUntracked = false
    var allowLocalReset = false
}

enum HeadroomSourceUpdateRecoveryAction: Equatable, Sendable {
    case retryIgnoringUntracked
    case retryReplacingLocalCommits
    case copySSHCheck
    case revealSource
    case chooseSource
}

enum HeadroomSourceUpdateState: Equatable, Sendable {
    case idle
    case setupRequired
    case checking
    case updating
    case upToDate
    case updateAvailable
    case completed
    case failed
}

enum HeadroomSourceUpdatePresentation {
    static let statusStripHeight: CGFloat = 52
}

@MainActor
@Observable
final class HeadroomSourceUpdateController {
    private(set) var configuration: HeadroomSourceUpdateConfiguration
    private(set) var state: HeadroomSourceUpdateState
    private(set) var stage: HeadroomSourceUpdateStage?
    private(set) var detail = ""
    private(set) var isRunning = false
    private(set) var sourceReady: Bool
    private(set) var recoveryAction: HeadroomSourceUpdateRecoveryAction?

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var detachedStatusTask: Task<Void, Never>?
    @ObservationIgnored private var outputHandle: FileHandle?
    @ObservationIgnored private var outputURL: URL?
    @ObservationIgnored private var outputText = ""
    @ObservationIgnored private var activeMode: Mode?

    enum Mode: Equatable, Sendable {
        case check
        case update
    }

    nonisolated static func timeout(for mode: Mode) -> TimeInterval {
        mode == .check ? 60 : 20 * 60
    }

    nonisolated static func arguments(
        for mode: Mode,
        options: HeadroomSourceUpdateOptions) -> [String]
    {
        var arguments = mode == .check ? ["--check-only"] : []
        if options.ignoreUntracked {
            arguments.append("--ignore-untracked")
        }
        if options.allowLocalReset {
            arguments.append("--allow-local-reset")
        }
        return arguments
    }

    nonisolated static func recoveryAction(for reason: String?) -> HeadroomSourceUpdateRecoveryAction? {
        switch reason {
        case "untracked_files": .retryIgnoringUntracked
        case "local_ahead", "diverged": .retryReplacingLocalCommits
        case "fetch_failed": .copySSHCheck
        case "tracked_dirty", "branch_missing", "remote_missing", "required_script_missing": .revealSource
        case "checkout_missing": .chooseSource
        default: nil
        }
    }

    init(
        configuration: HeadroomSourceUpdateConfiguration = .default,
        fileManager: FileManager = .default)
    {
        self.configuration = configuration
        self.fileManager = fileManager
        let sourceReady = Self.isSourceReady(configuration: configuration, fileManager: fileManager)
        self.sourceReady = sourceReady
        self.state = sourceReady ? .idle : .setupRequired
        self.recoveryAction = nil
        if sourceReady {
            self.restorePersistedStatus()
        }
    }

    func refreshAvailability() {
        self.sourceReady = Self.isSourceReady(
            configuration: self.configuration,
            fileManager: self.fileManager)
        guard !self.isRunning else { return }
        if !self.sourceReady {
            self.state = .setupRequired
        } else if self.state == .setupRequired {
            self.state = .idle
        }
    }

    func configure(sourceDirectory: URL, branch: String) {
        guard !self.isRunning else { return }
        self.configuration = .make(sourceDirectory: sourceDirectory, branch: branch)
        self.detail = ""
        self.stage = nil
        self.recoveryAction = nil
        self.refreshAvailability()
        if self.sourceReady {
            self.restorePersistedStatus()
        }
    }

    func check() {
        self.start(mode: .check, options: .init())
    }

    func updateAndRelaunch(options: HeadroomSourceUpdateOptions = .init()) {
        self.start(mode: .update, options: options)
    }

    private func start(mode: Mode, options: HeadroomSourceUpdateOptions) {
        guard !self.isRunning else { return }
        self.detachedStatusTask?.cancel()
        self.detachedStatusTask = nil
        self.refreshAvailability()
        guard self.sourceReady else {
            self.state = .setupRequired
            return
        }

        let outputURL = self.fileManager.temporaryDirectory
            .appending(path: "headroom-source-update-\(UUID().uuidString).log")
        guard self.fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            self.state = .failed
            self.detail = L("source_update_temporary_log_failed")
            return
        }

        do {
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let process = Process()
            process.executableURL = self.configuration.scriptURL
            process.arguments = Self.arguments(for: mode, options: options)
            process.currentDirectoryURL = self.configuration.sourceDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["HEADROOM_SOURCE_DIR"] = self.configuration.sourceDirectory.path
            environment["HEADROOM_BRANCH"] = self.configuration.branch
            environment["HEADROOM_UPDATE_LOG"] = self.configuration.logURL.path
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_SSH_COMMAND"] =
                "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
            process.environment = environment
            process.standardOutput = outputHandle
            process.standardError = outputHandle
            process.terminationHandler = { [weak self] completedProcess in
                let status = completedProcess.terminationStatus
                Task { @MainActor [weak self] in
                    self?.finish(status: status)
                }
            }

            self.outputURL = outputURL
            self.outputHandle = outputHandle
            self.outputText = ""
            self.activeMode = mode
            self.stage = .preflight
            self.detail = L("source_update_preparing")
            self.recoveryAction = nil
            self.state = mode == .check ? .checking : .updating
            try process.run()
            self.process = process
            self.timedOut = false
            self.startedAt = Date()
            self.isRunning = true
            self.beginMonitoring()
        } catch {
            try? self.outputHandle?.close()
            self.outputHandle = nil
            self.outputURL = nil
            try? self.fileManager.removeItem(at: outputURL)
            self.state = .failed
            self.detail = error.localizedDescription
        }
    }

    private func beginMonitoring() {
        self.monitorTask?.cancel()
        self.monitorTask = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                self.consumeOutput()
                if let startedAt = self.startedAt,
                   Date().timeIntervalSince(startedAt) >= Self.timeout(for: self.activeMode ?? .check)
                {
                    self.timedOut = true
                    self.detail = L("source_update_timeout")
                    self.process?.terminate()
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func consumeOutput() {
        guard let outputURL = self.outputURL,
              let data = try? Data(contentsOf: outputURL),
              !data.isEmpty
        else { return }

        guard let output = String(bytes: data, encoding: .utf8) else { return }
        self.outputText = output
        let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init)
        for line in lines {
            if let stage = HeadroomSourceUpdateStage.parse(line) {
                self.stage = stage
            }
        }
        if let latestLine = lines.last {
            self.detail = latestLine
        }
    }

    private func finish(status: Int32) {
        self.consumeOutput()
        self.isRunning = false
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.process = nil
        self.startedAt = nil
        try? self.outputHandle?.close()
        self.outputHandle = nil

        let mode = self.activeMode
        self.activeMode = nil
        if let outputURL = self.outputURL {
            try? self.fileManager.removeItem(at: outputURL)
        }
        self.outputURL = nil

        let parsedStatus = HeadroomSourceUpdateStatus.latest(in: self.outputText)
        guard status == 0, parsedStatus?.kind != .failed else {
            self.state = .failed
            self.recoveryAction = Self.recoveryAction(for: parsedStatus?.reason)
            self.detail = self.failureDetail(status: status, parsedStatus: parsedStatus)
            return
        }

        if parsedStatus?.kind == .scheduled {
            self.stage = .scheduled
            self.detail = L("source_update_scheduled_detail")
            self.state = .updating
        } else if parsedStatus?.kind == .available {
            self.state = .updateAvailable
            self.detail = L("source_update_available_detail")
        } else if parsedStatus?.kind == .upToDate {
            self.state = .upToDate
            self.detail = L("source_update_current_detail")
        } else if parsedStatus?.kind == .completed {
            self.stage = .finished
            self.state = .completed
            self.detail = L("source_update_completed_detail")
        } else if parsedStatus?.kind == .localAhead {
            self.state = .failed
            self.recoveryAction = .retryReplacingLocalCommits
            self.detail = L("source_update_local_ahead")
        } else if parsedStatus?.kind == .diverged {
            self.state = .failed
            self.recoveryAction = .retryReplacingLocalCommits
            self.detail = L("source_update_diverged")
        } else if mode == .update {
            self.stage = .finished
            self.state = .completed
            self.detail = L("source_update_completed_detail")
        } else {
            self.stage = .finished
            self.state = .upToDate
            self.detail = L("source_update_current_detail")
        }
    }

    private func failureDetail(
        status: Int32,
        parsedStatus: HeadroomSourceUpdateStatus?) -> String
    {
        if self.timedOut {
            return L("source_update_timeout")
        }
        if let reason = parsedStatus?.reason, !reason.isEmpty {
            return self.localizedFailureDetail(reason: reason)
        }
        let lines = self.outputText.split(whereSeparator: { $0.isNewline }).map(String.init)
        if let errorLine = lines.last(where: { $0.contains("ERROR:") }) {
            return errorLine
        }
        if let latestLine = lines.last, !latestLine.isEmpty {
            return latestLine
        }
        return L("source_update_failed_status", Int(status))
    }

    private func localizedFailureDetail(reason: String) -> String {
        switch reason {
        case "checkout_missing": L("source_update_checkout_missing")
        case "branch_missing": L("source_update_branch_missing")
        case "remote_missing": L("source_update_remote_missing")
        case "tracked_dirty": L("source_update_tracked_dirty")
        case "untracked_files": L("source_update_untracked_files")
        case "fetch_failed": L("source_update_ssh_failed")
        case "local_ahead": L("source_update_local_ahead")
        case "diverged": L("source_update_diverged")
        case "required_script_missing": L("source_update_required_script_missing")
        case "package_failed": L("source_update_package_failed")
        case "finalize_submit_failed": L("source_update_finalize_failed")
        case "stop_failed": L("source_update_stop_failed")
        case "install_failed": L("source_update_install_failed")
        default: L("source_update_failed_reason", reason)
        }
    }

    private static func isSourceReady(
        configuration: HeadroomSourceUpdateConfiguration,
        fileManager: FileManager) -> Bool
    {
        let gitPath = configuration.sourceDirectory.appending(path: ".git").path
        return fileManager.fileExists(atPath: gitPath)
            && fileManager.isExecutableFile(atPath: configuration.scriptURL.path)
    }

    private func restorePersistedStatus() {
        guard let data = try? Data(contentsOf: self.configuration.logURL),
              let text = String(data: data, encoding: .utf8),
              let status = HeadroomSourceUpdateStatus.latest(in: text)
        else { return }
        self.applyPersistedStatus(status)
        if status.kind == .scheduled {
            self.beginDetachedStatusMonitoring()
        }
    }

    private func applyPersistedStatus(_ status: HeadroomSourceUpdateStatus) {
        self.recoveryAction = nil
        switch status.kind {
        case .completed:
            self.state = .completed
            self.stage = .finished
            self.detail = L("source_update_completed_detail")
        case .failed, .localAhead, .diverged:
            self.state = .failed
            let reason = status.reason ?? status.kind.rawValue
            self.recoveryAction = Self.recoveryAction(for: reason)
            self.detail = self.localizedFailureDetail(reason: reason)
        case .available:
            self.state = .updateAvailable
            self.detail = L("source_update_available_detail")
        case .upToDate:
            self.state = .upToDate
            self.detail = L("source_update_current_detail")
        case .scheduled:
            self.state = .updating
            self.stage = .scheduled
            self.detail = L("source_update_scheduled_detail")
        }
    }

    private func beginDetachedStatusMonitoring() {
        self.detachedStatusTask?.cancel()
        self.detachedStatusTask = Task { @MainActor [weak self] in
            for _ in 0..<480 {
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard let data = try? Data(contentsOf: self.configuration.logURL),
                      let text = String(data: data, encoding: .utf8),
                      let status = HeadroomSourceUpdateStatus.latest(in: text),
                      status.kind != .scheduled
                else { continue }
                self.applyPersistedStatus(status)
                self.detachedStatusTask = nil
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.state = .failed
            self.detail = L("source_update_finalize_timeout")
            self.detachedStatusTask = nil
        }
    }

    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var timedOut = false
}
