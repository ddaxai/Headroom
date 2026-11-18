import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RelayUsageQueryError: LocalizedError, Equatable, Sendable {
    case disabled
    case missingCredential
    case invalidCustomBalanceConfiguration
    case unsupportedResponse
    case invalidCredential
    case apiError(Int)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Relay usage query is disabled."
        case .missingCredential:
            "Relay usage query needs a saved API key."
        case .invalidCustomBalanceConfiguration:
            "Custom balance needs a valid endpoint, JSON paths, currency, and divisor."
        case .unsupportedResponse:
            "The relay response did not contain a recognizable balance."
        case .invalidCredential:
            "The relay rejected the API key used for the usage query."
        case let .apiError(statusCode):
            "Relay usage query returned HTTP \(statusCode)."
        }
    }
}

public enum RelayUsageQueryFetcher {
    public static func fetch(
        mode: RelayUsageQueryMode,
        apiKey: String,
        baseURL: URL,
        customBalance: RelayCustomBalanceConfiguration? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> RelayUsageSummary
    {
        let credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw RelayUsageQueryError.missingCredential }

        switch mode {
        case .disabled:
            throw RelayUsageQueryError.disabled
        case .sub2API:
            let snapshot = try await Sub2APIUsageFetcher.fetchUsage(
                apiKey: credential,
                baseURL: baseURL,
                transport: transport,
                updatedAt: updatedAt)
            let remaining = snapshot.balance ?? snapshot.remaining ?? snapshot.quota?.remaining
            let used = snapshot.quota?.used
            let total = snapshot.quota?.limit ?? Self.sum(remaining, used)
            guard remaining != nil || used != nil || total != nil else {
                throw RelayUsageQueryError.unsupportedResponse
            }
            return RelayUsageSummary(
                remaining: remaining,
                used: used,
                total: total,
                unit: snapshot.unit,
                planName: snapshot.planName,
                updatedAt: updatedAt,
                recentUsage: snapshot.rolling24HoursUsage.map {
                    RelayRecentUsageSummary(
                        period: .rolling24Hours,
                        totalTokens: $0.totalTokens,
                        actualCostUSD: $0.actualCostUSD,
                        cacheReadTokens: $0.cacheReadTokens,
                        cacheCreationTokens: $0.cacheCreationTokens)
                } ?? snapshot.todayUsage.map {
                    RelayRecentUsageSummary(
                        period: .today,
                        totalTokens: $0.totalTokens,
                        actualCostUSD: $0.actualCostUSD,
                        cacheReadTokens: $0.cacheReadTokens,
                        cacheCreationTokens: $0.cacheCreationTokens)
                })
        case .genericBalance:
            var request = URLRequest(url: self.genericBalanceURL(baseURL: baseURL))
            request.httpMethod = "GET"
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200..<300:
                return try self.parseGenericBalance(response.data, updatedAt: updatedAt)
            case 401, 403:
                throw RelayUsageQueryError.invalidCredential
            default:
                throw RelayUsageQueryError.apiError(response.statusCode)
            }
        case .customBalance:
            guard let customBalance, self.isValid(customBalance) else {
                throw RelayUsageQueryError.invalidCustomBalanceConfiguration
            }
            var request = URLRequest(url: self.customBalanceURL(
                baseURL: baseURL,
                endpointPath: customBalance.endpointPath))
            request.httpMethod = "GET"
            switch customBalance.authentication {
            case .bearer:
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            case .xAPIKey:
                request.setValue(credential, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200..<300:
                return try self.parseCustomBalance(response.data, configuration: customBalance, updatedAt: updatedAt)
            case 401, 403:
                throw RelayUsageQueryError.invalidCredential
            default:
                throw RelayUsageQueryError.apiError(response.statusCode)
            }
        }
    }

    public static func _parseGenericBalanceForTesting(_ data: Data, updatedAt: Date) throws -> RelayUsageSummary {
        try self.parseGenericBalance(data, updatedAt: updatedAt)
    }

    private static func genericBalanceURL(baseURL: URL) -> URL {
        var root = baseURL
        if root.path.split(separator: "/").last?.lowercased() == "v1" {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("user/balance")
    }

    private static func customBalanceURL(baseURL: URL, endpointPath: String) -> URL {
        var root = baseURL
        if root.path.split(separator: "/").last?.lowercased() == "v1" {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent(endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func isValid(_ configuration: RelayCustomBalanceConfiguration) -> Bool {
        !configuration.endpointPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configuration.remainingJSONPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configuration.usedJSONPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configuration.totalJSONPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configuration.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            configuration.divisor.isFinite && configuration.divisor > 0
    }

    private static func parseCustomBalance(
        _ data: Data,
        configuration: RelayCustomBalanceConfiguration,
        updatedAt: Date) throws -> RelayUsageSummary
    {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayUsageQueryError.unsupportedResponse
        }
        let divisor = configuration.divisor
        let remaining = self.number(at: configuration.remainingJSONPath, in: root).map { $0 / divisor }
        let used = self.number(at: configuration.usedJSONPath, in: root).map { $0 / divisor }
        let total = self.number(at: configuration.totalJSONPath, in: root).map { $0 / divisor }
        guard remaining != nil || used != nil || total != nil else {
            throw RelayUsageQueryError.unsupportedResponse
        }
        return RelayUsageSummary(
            remaining: remaining,
            used: used,
            total: total,
            unit: configuration.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines),
            planName: nil,
            updatedAt: updatedAt)
    }

    private static func number(at path: String, in root: [String: Any]) -> Double? {
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var value: Any = root
        for part in parts {
            guard let object = value as? [String: Any], let next = object[part] else { return nil }
            value = next
        }
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func parseGenericBalance(_ data: Data, updatedAt: Date) throws -> RelayUsageSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayUsageQueryError.unsupportedResponse
        }
        let nested = root["data"] as? [String: Any]
        let candidates = [nested, root].compactMap(\.self)
        let remaining = self.firstNumber(
            keys: ["remaining", "balance", "availableBalance", "available_balance", "total_balance"],
            in: candidates)
        let used = self.firstNumber(keys: ["used", "usedQuota", "used_quota", "total_usage"], in: candidates)
        let explicitTotal = self.firstNumber(keys: ["total", "quota", "totalBalance"], in: candidates)
        let total = explicitTotal ?? self.sum(remaining, used)
        guard remaining != nil || used != nil || total != nil else {
            throw RelayUsageQueryError.unsupportedResponse
        }
        return RelayUsageSummary(
            remaining: remaining,
            used: used,
            total: total,
            unit: self.firstString(keys: ["unit", "currency"], in: candidates) ?? "USD",
            planName: self.firstString(keys: ["planName", "plan_name", "group"], in: candidates),
            updatedAt: updatedAt,
            recentUsage: self.recentUsage(in: candidates))
    }

    private static func recentUsage(in objects: [[String: Any]]) -> RelayRecentUsageSummary? {
        for object in objects {
            guard let usage = object["usage"] as? [String: Any] else { continue }
            for (key, period) in [
                ("rolling_24_hours", RelayRecentUsageSummary.Period.rolling24Hours),
                ("last_24_hours", RelayRecentUsageSummary.Period.rolling24Hours),
                ("today", RelayRecentUsageSummary.Period.today),
            ] {
                guard let bucket = usage[key] as? [String: Any],
                      let tokens = self.firstNumber(keys: ["total_tokens", "totalTokens"], in: [bucket]),
                      let cost = self.firstNumber(keys: ["actual_cost", "actualCost", "actual_cost_usd"], in: [bucket])
                else { continue }
                return RelayRecentUsageSummary(
                    period: period,
                    totalTokens: max(0, Int(tokens.rounded())),
                    actualCostUSD: max(0, cost),
                    cacheReadTokens: self.firstNumber(
                        keys: [
                            "cache_read_tokens",
                            "cacheReadTokens",
                            "cache_read_input_tokens",
                            "cacheReadInputTokens",
                        ],
                        in: [bucket]).map { max(0, Int($0.rounded())) },
                    cacheCreationTokens: self.firstNumber(
                        keys: [
                            "cache_creation_tokens",
                            "cacheCreationTokens",
                            "cache_creation_input_tokens",
                            "cacheCreationInputTokens",
                        ],
                        in: [bucket]).map { max(0, Int($0.rounded())) })
            }
        }
        return nil
    }

    private static func firstNumber(keys: [String], in objects: [[String: Any]]) -> Double? {
        for object in objects {
            for key in keys {
                if let value = self.number(object[key]) { return value }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let parsed = Double(value), parsed.isFinite { return parsed }
        return nil
    }

    private static func firstString(keys: [String], in objects: [[String: Any]]) -> String? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? String {
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        return nil
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}
