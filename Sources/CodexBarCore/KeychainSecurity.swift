import Foundation

enum KeychainTestSafety {
    static let suppressAccessEnvironmentKey = "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"
    static let allowAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"
    private nonisolated(unsafe) static var didApplyBlockedProcessSideEffects = false
    private static let blockedProcessSideEffectsLock = NSLock()

    private static func applyBlockedProcessSideEffectsOnce() {
        self.blockedProcessSideEffectsLock.lock()
        defer { self.blockedProcessSideEffectsLock.unlock() }
        guard !self.didApplyBlockedProcessSideEffects else { return }
        self.didApplyBlockedProcessSideEffects = true
        setenv(self.suppressAccessEnvironmentKey, "1", 1)
        #if os(macOS)
        KeychainLegacyInteraction.disableProcessWideInteraction()
        #endif
    }

    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let blocked = self.resolveShouldBlockRealKeychainAccess(
            processName: processName,
            environment: environment)
        if blocked { self.applyBlockedProcessSideEffectsOnce() }
        return blocked
    }

    static func resolveShouldBlockRealKeychainAccess(
        processName: String,
        environment: [String: String]) -> Bool
    {
        if environment[self.allowAccessEnvironmentKey] == "1" { return false }
        if environment[self.suppressAccessEnvironmentKey] == "1" { return true }
        if environment[KeychainAccessGate.disableAccessEnvironmentKey] == "1" { return true }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func shouldIsolateUserStateUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard environment[self.allowAccessEnvironmentKey] != "1" else { return false }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func isRunningUnderTests(
        processName: String,
        environment: [String: String]) -> Bool
    {
        processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || processName.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["TESTING_LIBRARY_VERSION"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }
}

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainReadDiagnostics {
    struct CallSite: Hashable, Sendable {
        let fileID: String
        let function: String
        let line: UInt

        var label: String {
            "\(self.fileID):\(self.line) \(self.function)"
        }
    }

    struct Event: Equatable, Sendable {
        let callSite: CallSite
        let timestamp: Date
    }

    struct Group: Equatable, Sendable {
        let callSite: CallSite
        let timestamps: [Date]

        var count: Int {
            self.timestamps.count
        }
    }

    final class Recorder: @unchecked Sendable {
        private static let eventLimit = 4096
        private let lock = NSLock()
        private var events: [Event?] = Array(repeating: nil, count: eventLimit)
        private var nextIndex = 0
        private var eventCount = 0

        func record(_ event: Event) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.events[self.nextIndex] = event
            self.nextIndex = (self.nextIndex + 1) % Self.eventLimit
            self.eventCount = min(self.eventCount + 1, Self.eventLimit)
        }

        func snapshot() -> [Event] {
            self.lock.lock()
            defer { self.lock.unlock() }
            let startIndex = self.eventCount == Self.eventLimit ? self.nextIndex : 0
            return (0..<self.eventCount).compactMap { offset in
                self.events[(startIndex + offset) % Self.eventLimit]
            }
        }
    }

    private static let sharedRecorder = Recorder()
    private static let log = CodexBarLog.logger(LogCategories.keychainRead)
    @TaskLocal private static var recorderOverrideForTesting: Recorder?

    static func record(fileID: StaticString, function: StaticString, line: UInt) {
        let timestamp = Date()
        let callSite = CallSite(fileID: "\(fileID)", function: "\(function)", line: line)
        let event = Event(callSite: callSite, timestamp: timestamp)
        let recorder = self.recorderOverrideForTesting ?? self.sharedRecorder
        recorder.record(event)

        guard self.recorderOverrideForTesting == nil else { return }
        self.log.info(
            "Keychain read",
            metadata: [
                "callSite": callSite.label,
                "timestampMs": String(Int64(timestamp.timeIntervalSince1970 * 1000)),
            ])
    }

    static func snapshot() -> [Event] {
        (self.recorderOverrideForTesting ?? self.sharedRecorder).snapshot()
    }

    static func groupedSnapshot(_ events: [Event]? = nil) -> [Group] {
        let source = events ?? self.snapshot()
        return Dictionary(grouping: source, by: \.callSite)
            .map { callSite, events in
                Group(callSite: callSite, timestamps: events.map(\.timestamp))
            }
            .sorted { $0.callSite.label < $1.callSite.label }
    }

    static func withRecorderForTesting<T>(
        _ recorder: Recorder,
        operation: () throws -> T) rethrows -> T
    {
        try self.$recorderOverrideForTesting.withValue(recorder) {
            try operation()
        }
    }

    static func withRecorderForTesting<T>(
        _ recorder: Recorder,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$recorderOverrideForTesting.withValue(recorder) {
            try await operation()
        }
    }
}

enum KeychainLegacyInteraction {
    private typealias SetUserInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus

    static func disableProcessWideInteraction() {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY | RTLD_NOLOAD) else { return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return }
        let setUserInteractionAllowed = unsafeBitCast(symbol, to: SetUserInteractionAllowedFn.self)
        _ = setUserInteractionAllowed(false)
    }
}

/// The only first-party entry point for Security.framework item operations.
/// Test processes fail closed before touching the user's Keychain, even when a test enables
/// higher-level Keychain logic with `KeychainAccessGate.withTaskOverrideForTesting(false)`.
public enum KeychainSecurity {
    private typealias CopyMatchingBackend = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    private struct CopyMatchingCallSite {
        let fileID: StaticString
        let function: StaticString
        let line: UInt
    }

    private final class CopyMatchingRequest: @unchecked Sendable {
        let query: CFDictionary
        let result: UnsafeMutablePointer<CFTypeRef?>?
        let callSite: CopyMatchingCallSite
        let backend: CopyMatchingBackend
        var status = errSecInternalComponent

        init(
            query: CFDictionary,
            result: UnsafeMutablePointer<CFTypeRef?>?,
            callSite: CopyMatchingCallSite,
            backend: @escaping CopyMatchingBackend)
        {
            self.query = query
            self.result = result
            self.callSite = callSite
            self.backend = backend
        }
    }

    private final class CopyMatchingCoordinator: @unchecked Sendable {
        private struct CacheEntry {
            let query: CFDictionary
            let status: OSStatus
            let result: CFTypeRef?
        }

        private let queue = DispatchQueue(label: "com.ddaxia.headroom.keychain-copy-matching")
        private var cache: [CacheEntry] = []

        func copyMatching(_ request: CopyMatchingRequest) -> OSStatus {
            self.queue.sync {
                self.perform(request)
            }
            return request.status
        }

        func invalidate() {
            self.queue.sync {
                self.cache.removeAll(keepingCapacity: true)
            }
        }

        private func perform(_ request: CopyMatchingRequest) {
            request.result?.pointee = nil
            let normalizedQuery = Self.normalizedQuery(
                request.query,
                wantsResult: request.result != nil)
            if let normalizedQuery,
               let cached = self.cache.first(where: { CFEqual($0.query, normalizedQuery) })
            {
                request.result?.pointee = cached.result
                request.status = cached.status
                return
            }

            KeychainReadDiagnostics.record(
                fileID: request.callSite.fileID,
                function: request.callSite.function,
                line: request.callSite.line)
            request.status = request.backend(request.query, request.result)

            guard let normalizedQuery, Self.shouldCache(status: request.status) else { return }
            self.cache.append(CacheEntry(
                query: normalizedQuery,
                status: request.status,
                result: request.result?.pointee))
        }

        private static func normalizedQuery(
            _ query: CFDictionary,
            wantsResult: Bool) -> CFDictionary?
        {
            let itemClassKey = Unmanaged.passUnretained(kSecClass).toOpaque()
            guard CFDictionaryContainsKey(query, itemClassKey) else { return nil }

            let matchLimitKey = Unmanaged.passUnretained(kSecMatchLimit).toOpaque()
            if let rawMatchLimit = CFDictionaryGetValue(query, matchLimitKey) {
                let matchLimit = Unmanaged<AnyObject>.fromOpaque(rawMatchLimit).takeUnretainedValue()
                if CFEqual(matchLimit, kSecMatchLimitAll) { return nil }
            }

            // Persistent references can identify items owned and mutated by another app, such as
            // Claude CLI credentials. Replaying their secret data for the whole Headroom process
            // would hide an external update even when a fresh enumeration detects it.
            let persistentReferenceKey = Unmanaged.passUnretained(kSecValuePersistentRef).toOpaque()
            guard !CFDictionaryContainsKey(query, persistentReferenceKey) else { return nil }

            guard let mutable = CFDictionaryCreateMutableCopy(nil, 0, query) else { return nil }
            let authenticationContextKey = Unmanaged.passUnretained(kSecUseAuthenticationContext).toOpaque()
            if let rawContext = CFDictionaryGetValue(mutable, authenticationContextKey) {
                let value = Unmanaged<AnyObject>.fromOpaque(rawContext).takeUnretainedValue()
                guard let context = value as? LAContext else { return nil }
                let normalizedContext = context.interactionNotAllowed ? kCFBooleanTrue! : kCFBooleanFalse!
                CFDictionarySetValue(
                    mutable,
                    authenticationContextKey,
                    Unmanaged.passUnretained(normalizedContext).toOpaque())
            }

            let wantsResultKeyValue =
                "com.ddaxia.headroom.keychain-copy-matching.wants-result" as CFString
            let wantsResultKey = Unmanaged.passUnretained(wantsResultKeyValue).toOpaque()
            let wantsResultValue = wantsResult ? kCFBooleanTrue! : kCFBooleanFalse!
            CFDictionarySetValue(
                mutable,
                wantsResultKey,
                Unmanaged.passUnretained(wantsResultValue).toOpaque())

            guard CFPropertyListIsValid(mutable, .binaryFormat_v1_0) else { return nil }
            return CFDictionaryCreateCopy(nil, mutable)
        }

        private static func shouldCache(status: OSStatus) -> Bool {
            switch status {
            case errSecSuccess,
                 errSecItemNotFound,
                 errSecInteractionNotAllowed,
                 errSecAuthFailed,
                 errSecUserCanceled:
                true
            default:
                false
            }
        }
    }

    private static let sharedCopyMatchingCoordinator = CopyMatchingCoordinator()

    #if DEBUG
    typealias CopyMatchingOverride = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    @TaskLocal private static var copyMatchingOverrideForTesting: CopyMatchingOverride?
    @TaskLocal private static var copyMatchingCoordinatorOverrideForTesting: CopyMatchingCoordinator?
    #endif

    private static var copyMatchingCoordinator: CopyMatchingCoordinator {
        #if DEBUG
        self.copyMatchingCoordinatorOverrideForTesting ?? self.sharedCopyMatchingCoordinator
        #else
        self.sharedCopyMatchingCoordinator
        #endif
    }

    public static func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line) -> OSStatus
    {
        #if DEBUG
        if let override = self.copyMatchingOverrideForTesting {
            let request = CopyMatchingRequest(
                query: query,
                result: result,
                callSite: CopyMatchingCallSite(fileID: fileID, function: function, line: line),
                backend: override)
            return self.copyMatchingCoordinator.copyMatching(request)
        }
        #endif
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        let request = CopyMatchingRequest(
            query: query,
            result: result,
            callSite: CopyMatchingCallSite(fileID: fileID, function: function, line: line),
            backend: SecItemCopyMatching)
        return self.copyMatchingCoordinator.copyMatching(request)
    }

    public static func invalidateCopyMatchingCacheForProfileChange() {
        self.copyMatchingCoordinator.invalidate()
    }

    #if DEBUG
    static func withCopyMatchingOverrideForTesting<T>(
        _ override: @escaping CopyMatchingOverride,
        operation: () throws -> T) rethrows -> T
    {
        try self.$copyMatchingOverrideForTesting.withValue(override) {
            try operation()
        }
    }

    static func withCopyMatchingOverrideForTesting<T>(
        _ override: @escaping CopyMatchingOverride,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$copyMatchingOverrideForTesting.withValue(override) {
            try await operation()
        }
    }

    static func withIsolatedCopyMatchingCacheForTesting<T>(
        operation: () throws -> T) rethrows -> T
    {
        try self.$copyMatchingCoordinatorOverrideForTesting.withValue(CopyMatchingCoordinator()) {
            try operation()
        }
    }

    static func withIsolatedCopyMatchingCacheForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$copyMatchingCoordinatorOverrideForTesting.withValue(CopyMatchingCoordinator()) {
            try await operation()
        }
    }
    #endif

    public static func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        let status = SecItemUpdate(query, attributesToUpdate)
        if status == errSecSuccess {
            self.copyMatchingCoordinator.invalidate()
        }
        return status
    }

    public static func add(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        let status = SecItemAdd(attributes, result)
        if status == errSecSuccess {
            self.copyMatchingCoordinator.invalidate()
        }
        return status
    }

    public static func delete(_ query: CFDictionary) -> OSStatus {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        let status = SecItemDelete(query)
        if status == errSecSuccess {
            self.copyMatchingCoordinator.invalidate()
        }
        return status
    }
}
#endif
