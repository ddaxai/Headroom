import CodexBarCore
import Foundation
import Testing

struct RelayUsageQueryTests {
    @Test
    func `usage summary cache round trips with owner only permissions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-usage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("usage.json")
        let profileID = UUID()
        let summary = RelayUsageSummary(
            remaining: 12,
            used: 3,
            total: 15,
            unit: "USD",
            planName: "Team",
            updatedAt: Date(timeIntervalSince1970: 20))
        let store = FileRelayUsageSummaryStore(fileURL: fileURL)

        try store.store(summary, profileID: profileID)

        #expect(store.load(profileID: profileID) == summary)
        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #endif
    }

    @Test
    func `usage summary cache exposes ttl and preserves last good on failure`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-usage-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 100)
        let summary = RelayUsageSummary(
            remaining: 9,
            used: 1,
            total: 10,
            unit: "USD",
            planName: nil,
            updatedAt: updatedAt)
        let store = FileRelayUsageSummaryStore(fileURL: root.appendingPathComponent("usage.json"))
        try store.store(summary, profileID: profileID)

        #expect(store.loadFresh(profileID: profileID, now: updatedAt.addingTimeInterval(60)) == summary)
        #expect(store.loadFresh(profileID: profileID, now: updatedAt.addingTimeInterval(301)) == nil)

        try store.recordFailure(profileID: profileID, error: "timeout", at: updatedAt.addingTimeInterval(302))
        let state = store.loadState(profileID: profileID, now: updatedAt.addingTimeInterval(302))
        #expect(state.summary == summary)
        #expect(state.lastAttemptAt == updatedAt.addingTimeInterval(302))
        #expect(state.lastError == "timeout")
        #expect(!state.isFresh)
    }

    @Test
    func `generic balance parses nested common fields`() throws {
        let data = Data(#"{"data":{"balance":42.5,"used":7.5,"total":50,"currency":"USD","group":"Pro"}}"#.utf8)

        let summary = try RelayUsageQueryFetcher._parseGenericBalanceForTesting(
            data,
            updatedAt: Date(timeIntervalSince1970: 10))

        #expect(summary.remaining == 42.5)
        #expect(summary.used == 7.5)
        #expect(summary.total == 50)
        #expect(summary.unit == "USD")
        #expect(summary.planName == "Pro")
    }

    @Test
    func `generic balance request uses relay bearer key`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://relay.example/user/balance")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-relay")
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"balance":8,"unit":"USD"}"#.utf8), response)
        }

        let summary = try await RelayUsageQueryFetcher.fetch(
            mode: .genericBalance,
            apiKey: "sk-relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            transport: transport)

        #expect(summary.remaining == 8)
    }

    @Test
    func `custom balance maps configured paths with x api key and divisor`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://relay.example/account/quota")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-relay")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"payload":{"left":1500,"spent":500,"limit":2000}}"#.utf8), response)
        }
        let configuration = RelayCustomBalanceConfiguration(
            endpointPath: "/account/quota",
            authentication: .xAPIKey,
            remainingJSONPath: "payload.left",
            usedJSONPath: "payload.spent",
            totalJSONPath: "payload.limit",
            currencyCode: "USD",
            divisor: 100)

        let summary = try await RelayUsageQueryFetcher.fetch(
            mode: .customBalance,
            apiKey: "sk-relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            customBalance: configuration,
            transport: transport)

        #expect(summary.remaining == 15)
        #expect(summary.used == 5)
        #expect(summary.total == 20)
        #expect(summary.unit == "USD")
    }

    @Test
    func `sub2api query reuses existing usage endpoint`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.path == "/v1/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-group")
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            let data = Data(#"""
            {
              "mode": "unrestricted",
              "isValid": true,
              "balance": 12.25,
              "unit": "USD",
              "usage": {
                "rolling_24_hours": {
                  "total_tokens": 3210,
                  "actual_cost": 4.75,
                  "cache_read_tokens": 210,
                  "cache_creation_tokens": 40
                }
              }
            }
            """#.utf8)
            return (data, response)
        }

        let summary = try await RelayUsageQueryFetcher.fetch(
            mode: .sub2API,
            apiKey: "sk-group",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            transport: transport)

        #expect(summary.remaining == 12.25)
        #expect(summary.unit == "USD")
        #expect(summary.recentUsage?.period == .rolling24Hours)
        #expect(summary.recentUsage?.totalTokens == 3210)
        #expect(summary.recentUsage?.actualCostUSD == 4.75)
        #expect(summary.recentUsage?.cacheReadTokens == 210)
        #expect(summary.recentUsage?.cacheCreationTokens == 40)
        #expect(summary.recentUsage?.hasReportedCacheTokens == true)
    }

    @Test
    func `sub2api today totals remain honestly labelled as calendar day data`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            let data = Data(#"""
            {
              "balance": 8,
              "unit": "USD",
              "usage": { "today": { "total_tokens": 900, "actual_cost": 1.25 } }
            }
            """#.utf8)
            return (data, response)
        }

        let summary = try await RelayUsageQueryFetcher.fetch(
            mode: .sub2API,
            apiKey: "sk-group",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            transport: transport)

        #expect(summary.recentUsage?.period == .today)
        #expect(summary.recentUsage?.totalTokens == 900)
        #expect(summary.recentUsage?.actualCostUSD == 1.25)
    }
}
