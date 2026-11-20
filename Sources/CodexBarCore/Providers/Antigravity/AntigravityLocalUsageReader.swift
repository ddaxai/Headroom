import Foundation

/// Where Antigravity and its CLI keep each conversation's transcript.
enum AntigravityTranscriptLocator {
    struct Transcript {
        let root: URL
        let sessionID: String
        let url: URL
    }

    static func transcripts(homeDirectory: URL, environment: [String: String]) -> [Transcript] {
        let fm = FileManager.default
        let geminiBase = homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
        var roots: [URL] = [
            geminiBase.appendingPathComponent("antigravity", isDirectory: true),
            geminiBase.appendingPathComponent("antigravity-cli", isDirectory: true),
        ]
        if let custom = environment["AGY_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            roots.append(URL(fileURLWithPath: custom, isDirectory: true))
        }

        var seen: Set<String> = []
        var found: [Transcript] = []
        for root in roots {
            let brainDir = root.appendingPathComponent("brain", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for sessionDir in entries {
                let sessionID = sessionDir.lastPathComponent
                let logsDir = sessionDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                // The full transcript keeps steps the compact one drops.
                let candidates = ["transcript_full.jsonl", "transcript.jsonl"]
                    .map { logsDir.appendingPathComponent($0, isDirectory: false) }
                guard let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
                      seen.insert("\(root.standardizedFileURL.path):\(sessionID)").inserted
                else { continue }
                found.append(Transcript(root: root, sessionID: sessionID, url: url))
            }
        }
        return found
    }
}

public enum AntigravityLocalUsageError: LocalizedError, Sendable, Equatable {
    case historyUnavailable

    public var errorDescription: String? {
        "Antigravity has no local conversation history with token counts yet."
    }
}

public struct AntigravityLocalUsageSnapshot: Sendable {
    public let report: CostUsageDailyReport
    public let rolling24Hours: CostUsageRolling24HourSummary
    public let hourly24Hours: [CostUsageHourlyEntry]

    public func toTokenSnapshot(now: Date, historyDays: Int, calendar: Calendar = .current) -> CostUsageTokenSnapshot {
        CostUsageFetcher.tokenSnapshot(
            from: self.report,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            rolling24Hours: self.rolling24Hours,
            hourly24Hours: self.hourly24Hours)
    }
}

/// Token totals from the transcripts Antigravity writes on this Mac. Tokens only: the plan is a
/// subscription, so the transcripts carry no price.
public struct AntigravityLocalUsageReader: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    struct Row: Equatable {
        let date: Date
        let model: String
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int

        var tokens: Int {
            self.input + self.cacheRead + self.cacheWrite + self.output
        }
    }

    public func fetch(
        now: Date = Date(),
        historyDays: Int = 30,
        calendar: Calendar = .current) throws -> AntigravityLocalUsageSnapshot
    {
        let days = max(1, min(365, historyDays))
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        let start = calendar.startOfDay(for: since)

        var rows: [Row] = []
        for transcript in AntigravityTranscriptLocator.transcripts(
            homeDirectory: self.homeDirectory,
            environment: self.environment)
        {
            let modifiedAt = (try? transcript.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // A transcript last written before the window cannot hold a reply inside it.
            if let modifiedAt, modifiedAt < start { continue }
            rows.append(contentsOf: Self.parseTranscript(at: transcript.url))
        }
        let inWindow = rows.filter { $0.date >= start && $0.date <= now }
        guard !inWindow.isEmpty else { throw AntigravityLocalUsageError.historyUnavailable }

        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recent = inWindow.filter { $0.date >= cutoff }
        return AntigravityLocalUsageSnapshot(
            report: Self.makeReport(from: inWindow, calendar: calendar),
            rolling24Hours: CostUsageRolling24HourSummary(
                totalTokens: recent.reduce(0) { $0 + $1.tokens },
                costUSD: nil,
                modelProviderBreakdowns: []),
            hourly24Hours: Self.makeHourly(from: inWindow, now: now, calendar: calendar))
    }

    static func parseTranscript(at url: URL) -> [Row] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // A step is rewritten as it progresses; the last line for an index is its final state.
        var stepsByIndex: [UInt64: [String: Any]] = [:]
        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let index = (object["step_index"] as? NSNumber)?.uint64Value
            else { return }
            stepsByIndex[index] = object
        }

        var selectedModel: String?
        var rows: [Row] = []
        for index in stepsByIndex.keys.sorted() {
            guard let step = stepsByIndex[index] else { continue }
            let type = step["type"] as? String
            if type == "USER_INPUT",
               let content = step["content"] as? String,
               let switched = LocalAgentSpeedScanner.antigravityModelFromSettingsChange(content)
            {
                selectedModel = switched
            }
            guard type == "PLANNER_RESPONSE",
                  (step["status"] as? String) == "DONE",
                  let createdMs = (step["created_at"] as? String).flatMap(LocalAgentSpeedScanner.parseISO8601Millis)
            else { continue }

            let usage = step["usage"] as? [String: Any]
            func tokens(_ key: String) -> Int {
                max(0, (step[key] as? NSNumber)?.intValue ?? (usage?[key] as? NSNumber)?.intValue ?? 0)
            }
            let row = Row(
                date: Date(timeIntervalSince1970: Double(createdMs) / 1000),
                model: ((step["model"] as? String) ?? selectedModel)
                    .map(LocalAgentSpeedScanner.normalizeAntigravityModelID) ?? "antigravity",
                input: tokens("input_tokens"),
                cacheRead: tokens("cache_read_tokens"),
                cacheWrite: tokens("cache_write_tokens"),
                output: tokens("output_tokens"))
            if row.tokens > 0 {
                rows.append(row)
            }
        }
        return rows
    }

    private static func makeReport(from rows: [Row], calendar: Calendar) -> CostUsageDailyReport {
        let byDay = Dictionary(grouping: rows) {
            CostUsageScanner.CostUsageDayRange.dayKey(from: $0.date, calendar: calendar)
        }
        func sum(_ rows: [Row], _ value: (Row) -> Int) -> Int? {
            let total = rows.reduce(0) { $0 + value($1) }
            return total > 0 ? total : nil
        }
        let entries = byDay.keys.sorted().map { day in
            let dayRows = byDay[day] ?? []
            let byModel = Dictionary(grouping: dayRows, by: \.model)
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: sum(dayRows, \.input),
                outputTokens: sum(dayRows, \.output),
                cacheReadTokens: sum(dayRows, \.cacheRead),
                cacheCreationTokens: sum(dayRows, \.cacheWrite),
                totalTokens: sum(dayRows, \.tokens),
                requestCount: dayRows.count,
                costUSD: nil,
                modelsUsed: byModel.keys.sorted(),
                modelBreakdowns: byModel.keys.sorted().map { model in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: nil,
                        totalTokens: sum(byModel[model] ?? [], \.tokens),
                        requestCount: byModel[model]?.count)
                })
        }
        return CostUsageDailyReport(
            data: entries,
            summary: .init(
                totalInputTokens: sum(rows, \.input),
                totalOutputTokens: sum(rows, \.output),
                cacheReadTokens: sum(rows, \.cacheRead),
                cacheCreationTokens: sum(rows, \.cacheWrite),
                totalTokens: sum(rows, \.tokens),
                totalCostUSD: nil))
    }

    /// One entry for each of the 24 clock hours ending with the current one, empty hours included.
    private static func makeHourly(from rows: [Row], now: Date, calendar: Calendar) -> [CostUsageHourlyEntry] {
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start,
              let firstHour = calendar.date(byAdding: .hour, value: -23, to: currentHour)
        else { return [] }
        var tokensByHour: [Date: Int] = [:]
        for row in rows where row.date >= firstHour {
            guard let hour = calendar.dateInterval(of: .hour, for: row.date)?.start else { continue }
            tokensByHour[hour, default: 0] += row.tokens
        }
        guard !tokensByHour.isEmpty else { return [] }
        return (0..<24).compactMap { offset in
            calendar.date(byAdding: .hour, value: offset, to: firstHour).map {
                CostUsageHourlyEntry(startDate: $0, totalTokens: tokensByHour[$0] ?? 0, costUSD: nil)
            }
        }
    }
}
