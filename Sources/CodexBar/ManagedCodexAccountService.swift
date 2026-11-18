import AppKit
import CodexBarCore
import Foundation

protocol ManagedCodexIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount
}

protocol ManagedCodexWorkspaceResolving: Sendable {
    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity]
}

extension ManagedCodexWorkspaceResolving {
    func availableWorkspaceIdentities(homePath _: String) async -> [CodexOpenAIWorkspaceIdentity] {
        []
    }
}

protocol ManagedCodexWorkspaceSelecting: Sendable {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
}

enum ManagedCodexAccountServiceError: Error, Equatable {
    case loginFailed(CodexLoginRunner.Result)
    case missingEmail
    case workspaceSelectionCancelled
    case unsafeManagedHome(String)
}

extension ManagedCodexAccountServiceError {
    var userFacingMessage: String {
        switch self {
        case let .loginFailed(result):
            CodexLoginAlertPresentation.managedLoginFailureMessage(for: result)
        case .missingEmail:
            L("managed_login_missing_email")
        case .workspaceSelectionCancelled:
            L("workspace_selection_cancelled")
        case let .unsafeManagedHome(path):
            String(format: L("unsafe_managed_home"), path)
        }
    }
}

struct DefaultManagedCodexIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        return UsageFetcher(environment: env).loadAuthBackedCodexAccount()
    }
}

struct DefaultManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    private let workspaceCache: CodexOpenAIWorkspaceIdentityCache

    init(
        workspaceCache: CodexOpenAIWorkspaceIdentityCache = CodexOpenAIWorkspaceIdentityCache())
    {
        self.workspaceCache = workspaceCache
    }

    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity? {
        let normalizedProviderAccountID = ManagedCodexAccount.normalizeProviderAccountID(providerAccountID)
            ?? providerAccountID
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)

        if let credentials = try? CodexOAuthCredentialsStore.load(env: env),
           let authoritativeIdentity = try? await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials)
        {
            try? self.workspaceCache.store(authoritativeIdentity)
            return authoritativeIdentity
        }

        let cachedLabel = self.workspaceCache.workspaceLabel(for: normalizedProviderAccountID)
        return CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: normalizedProviderAccountID,
            workspaceLabel: cachedLabel)
    }

    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity] {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: env),
              let identities = try? await CodexOpenAIWorkspaceResolver.listWorkspaces(credentials: credentials)
        else {
            return []
        }

        for identity in identities {
            try? self.workspaceCache.store(identity)
        }
        return identities
    }
}

struct CodexWorkspaceAlertSelector: ManagedCodexWorkspaceSelecting {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard workspaces.count > 1 else { return workspaces.first }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        let sortedWorkspaces = workspaces.sorted { lhs, rhs in
            self.workspaceTitle(lhs) < self.workspaceTitle(rhs)
        }
        for workspace in sortedWorkspaces {
            popup.addItem(withTitle: self.workspaceTitle(workspace))
            popup.lastItem?.representedObject = workspace.workspaceAccountID
        }
        if let currentWorkspaceID,
           let selectedIndex = sortedWorkspaces.firstIndex(where: { $0.workspaceAccountID == currentWorkspaceID })
        {
            popup.selectItem(at: selectedIndex)
        }

        let alert = NSAlert()
        alert.messageText = L("Choose Codex workspace")
        alert.informativeText = String(format: L("multiple_workspaces_found"), email)
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Add Workspace"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let selectedWorkspaceID = popup.selectedItem?.representedObject as? String
        return sortedWorkspaces.first { $0.workspaceAccountID == selectedWorkspaceID }
    }

    private func workspaceTitle(_ workspace: CodexOpenAIWorkspaceIdentity) -> String {
        workspace.workspaceLabel ?? workspace.workspaceAccountID
    }
}

@MainActor
final class ManagedCodexAccountService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let loginRunner: any ManagedCodexLoginRunning
    private let identityReader: any ManagedCodexIdentityReading
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let workspaceSelector: any ManagedCodexWorkspaceSelecting
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        loginRunner: any ManagedCodexLoginRunning,
        identityReader: any ManagedCodexIdentityReading,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        workspaceSelector: any ManagedCodexWorkspaceSelecting = CodexWorkspaceAlertSelector(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.loginRunner = loginRunner
        self.identityReader = identityReader
        self.workspaceResolver = workspaceResolver
        self.workspaceSelector = workspaceSelector
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedCodexLoginRunner(),
            identityReader: DefaultManagedCodexIdentityReader(),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
            workspaceSelector: CodexWorkspaceAlertSelector(),
            fileManager: fileManager)
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathsToDelete: [String]

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout)
            guard case .success = result.outcome else { throw ManagedCodexAccountServiceError.loginFailed(result) }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedCodexAccountServiceError.missingEmail
            }
            let authenticatedProviderAccountID: String? = switch identity.identity {
            case let .providerAccount(id):
                ManagedCodexAccount.normalizeProviderAccountID(id)
            case .emailOnly, .unresolved:
                nil
            }
            let selectedWorkspace = try await self.selectedWorkspaceIdentity(
                email: rawEmail,
                homePath: homeURL.path,
                authenticatedProviderAccountID: authenticatedProviderAccountID)
            let providerAccountID = selectedWorkspace?.workspaceAccountID ?? authenticatedProviderAccountID
            let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let selectedWorkspace {
                selectedWorkspace
            } else {
                await self.resolvedWorkspaceIdentity(
                    homePath: homeURL.path,
                    providerAccountID: providerAccountID)
            }

            let now = Date().timeIntervalSince1970
            let existing = self.reconciledExistingAccount(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                snapshot: snapshot)
            let persistedMetadata = self.persistedProviderMetadata(
                authenticatedProviderAccountID: providerAccountID,
                resolvedWorkspaceIdentity: workspaceIdentity,
                existingAccount: existing)

            account = ManagedCodexAccount(
                id: existing?.id ?? UUID(),
                email: rawEmail,
                providerAccountID: persistedMetadata.providerAccountID,
                workspaceLabel: persistedMetadata.workspaceLabel,
                workspaceAccountID: persistedMetadata.workspaceAccountID,
                authFingerprint: CodexAuthFingerprint.fingerprint(
                    homePath: homeURL.path,
                    fileManager: self.fileManager),
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now)
            let replacedAccountIDs = self.replacedAccountIDs(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                matchedAccountID: existing?.id,
                snapshot: snapshot)
            existingHomePathsToDelete = snapshot.accounts
                .filter { replacedAccountIDs.contains($0.id) }
                .map(\.managedHomePath)

            let updatedSnapshot = ManagedCodexAccountSet(
                version: snapshot.version,
                accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
            try self.store.storeAccounts(updatedSnapshot)
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        try self.removeManagedAccount(account, from: snapshot)
    }

    /// Commits the exact snapshot that was inspected by the caller. Keeping
    /// the validation and write on the main actor avoids a second stale read
    /// between duplicate confirmation and the destructive store update.
    private func removeManagedAccount(
        _ account: ManagedCodexAccount,
        from snapshot: ManagedCodexAccountSet) throws
    {
        let remaining = snapshot.accounts.filter { $0.id != account.id }
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: snapshot.version,
            accounts: remaining))

        let homeStillReferenced = remaining.contains { $0.managedHomePath == account.managedHomePath }
        if !homeStillReferenced {
            try? self.removeManagedHomeIfSafe(atPath: account.managedHomePath)
        }
    }

    /// Confirm a destructive duplicate-removal action against the current
    /// persisted identities. A stale diagnostic must never delete a newly
    /// reauthenticated or no-longer-duplicated account.
    func removeManagedAccountIfStillDuplicate(
        id: UUID,
        expectedAuthFingerprint: String?,
        expectedWorkspaceAccountID: String?) async throws -> Bool
    {
        let snapshot = try self.store.loadAccounts()
        guard let target = snapshot.account(id: id) else { return false }
        // A destructive confirmation must prove the live auth state. Persisted
        // fingerprints are useful diagnostics, but are not sufficient proof
        // once the auth file is unreadable or absent.
        guard let currentFingerprint = CodexAuthFingerprint.fingerprint(
            homePath: target.managedHomePath,
            fileManager: self.fileManager)
        else { return false }
        guard currentFingerprint == expectedAuthFingerprint,
              target.workspaceAccountID == expectedWorkspaceAccountID
        else { return false }
        let stillDuplicate = snapshot.accounts.contains { other in
            guard other.id != target.id else { return false }
            let otherFingerprint = CodexAuthFingerprint.fingerprint(
                homePath: other.managedHomePath,
                fileManager: self.fileManager)
            // A persisted diagnostic is never a destructive witness. If the
            // other home cannot prove its current auth identity, only a live
            // workspace match can keep this confirmation eligible.
            let sameAuth = otherFingerprint.map { currentFingerprint == $0 } ?? false
            let sameWorkspace = target.workspaceAccountID != nil &&
                target.workspaceAccountID == other.workspaceAccountID
            return sameAuth || sameWorkspace
        }
        guard stillDuplicate else { return false }
        try self.removeManagedAccount(target, from: snapshot)
        return true
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }

    private func selectedWorkspaceIdentity(
        email: String,
        homePath: String,
        authenticatedProviderAccountID: String?) async throws -> CodexOpenAIWorkspaceIdentity?
    {
        let workspaces = await self.workspaceResolver.availableWorkspaceIdentities(homePath: homePath)
        guard workspaces.count > 1 else {
            return workspaces.first { $0.workspaceAccountID == authenticatedProviderAccountID }
        }
        guard let selected = await self.workspaceSelector.selectWorkspace(
            email: email,
            currentWorkspaceID: authenticatedProviderAccountID,
            workspaces: workspaces)
        else {
            throw ManagedCodexAccountServiceError.workspaceSelectionCancelled
        }
        try self.persistSelectedWorkspaceID(selected.workspaceAccountID, homePath: homePath)
        return selected
    }

    private func resolvedWorkspaceIdentity(
        homePath: String,
        providerAccountID: String?) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard let providerAccountID else { return nil }
        return await self.workspaceResolver.resolveWorkspaceIdentity(
            homePath: homePath,
            providerAccountID: providerAccountID)
    }

    private func persistSelectedWorkspaceID(_ workspaceID: String, homePath: String) throws {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        let credentials = try CodexOAuthCredentialsStore.load(env: env)
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                idToken: credentials.idToken,
                accountId: workspaceID,
                lastRefresh: credentials.lastRefresh),
            env: env)
    }

    private func reconciledExistingAccount(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        snapshot: ManagedCodexAccountSet)
        -> ManagedCodexAccount?
    {
        if let providerAccountID,
           let existingByProviderAccountID = snapshot.account(
               email: authenticatedEmail,
               workspaceAccountID: providerAccountID)
        {
            return existingByProviderAccountID
        }
        if let existingAccountID,
           let existingByID = snapshot.account(id: existingAccountID),
           existingByID.email == Self.normalizeEmail(authenticatedEmail),
           providerAccountID == nil || existingByID.providerAccountID == nil
        {
            return existingByID
        }
        return nil
    }

    private func replacedAccountIDs(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        matchedAccountID: UUID?,
        snapshot: ManagedCodexAccountSet) -> Set<UUID>
    {
        var ids: Set<UUID> = []
        let normalizedEmail = Self.normalizeEmail(authenticatedEmail)
        if let matchedAccountID {
            ids.insert(matchedAccountID)
        }

        guard let existingAccountID,
              existingAccountID != matchedAccountID,
              let existingByID = snapshot.account(id: existingAccountID)
        else {
            return ids
        }

        if existingByID.providerAccountID == nil,
           existingByID.email == normalizedEmail,
           providerAccountID != nil
        {
            ids.insert(existingAccountID)
        }
        return ids
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persistedProviderMetadata(
        authenticatedProviderAccountID: String?,
        resolvedWorkspaceIdentity: CodexOpenAIWorkspaceIdentity?,
        existingAccount: ManagedCodexAccount?) -> (
        providerAccountID: String?,
        workspaceLabel: String?,
        workspaceAccountID: String?)
    {
        if let authenticatedProviderAccountID {
            let isExistingProviderMatch = existingAccount?.providerAccountID == authenticatedProviderAccountID
            return (
                providerAccountID: authenticatedProviderAccountID,
                workspaceLabel: resolvedWorkspaceIdentity?.workspaceLabel
                    ?? (isExistingProviderMatch ? existingAccount?.workspaceLabel : nil),
                workspaceAccountID: resolvedWorkspaceIdentity?.workspaceAccountID ??
                    (isExistingProviderMatch ? existingAccount?.workspaceAccountID : nil) ??
                    authenticatedProviderAccountID)
        }

        guard let existingAccount, existingAccount.providerAccountID != nil else {
            return (providerAccountID: nil, workspaceLabel: nil, workspaceAccountID: nil)
        }

        return (
            providerAccountID: existingAccount.providerAccountID,
            workspaceLabel: existingAccount.workspaceLabel,
            workspaceAccountID: existingAccount.workspaceAccountID ?? existingAccount.providerAccountID)
    }
}
