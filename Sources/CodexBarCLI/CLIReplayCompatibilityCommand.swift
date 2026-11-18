import CodexBarCore
import Commander
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension CodexBarCLI {
    static func runPrepareReplayRequest(_ values: ParsedValues) -> Never {
        let output = CLIOutputPreferences.from(values: values)
        guard let input = values.options["inputFile"]?.last else {
            self.exit(code: .failure, message: "--input-file is required.", output: output, kind: .args)
        }
        let boundary: CodexReplayCompatibility.Boundary = values.flags.contains("crossBackend")
            ? .crossBackend : .sameBackend
        do {
            let projection = try CodexReplayCompatibility.prepare(
                requestData: Data(contentsOf: URL(fileURLWithPath: input)),
                boundary: boundary)
            if let destination = values.options["outputFile"]?.last, let data = projection.requestData {
                try Self.writeReplayRequest(data, to: URL(fileURLWithPath: destination))
            }
            if output.usesJSONOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = output.pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
                let data = try encoder.encode(ReplayCompatibilityCLIReport(
                    status: projection.report.ready ? "ready" : "blocked",
                    requestFileWritten: values.options["outputFile"]?.last != nil && projection.report.ready,
                    report: projection.report))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(Self.replayCompatibilityText(projection.report))
            }
            Self.platformExit(projection.report.ready ? 0 : 2)
        } catch {
            // Parser and filesystem errors may contain supplied content/paths; keep diagnostics bounded.
            let message = (error as? CodexReplayCompatibility.Failure)?.errorDescription
                ?? "Could not read the input or create the output file. Output must be a new file."
            self.exit(code: .failure, message: message, output: output, kind: .config)
        }
    }

    static func replayCompatibilityText(_ report: CodexReplayCompatibility.Report) -> String {
        var lines = [
            report
                .ready ? "Request projection ready (offline)." : "Request projection blocked; no request was written.",
            "Input items: \(report.inputItemCount); cleared IDs: \(report.clearedItemIDs); " +
                "omitted reasoning: \(report.omittedReasoningItems).",
        ]
        lines.append(contentsOf: report.issues.map { issue in
            "\(issue.inputIndex.map { "input[\($0)]" } ?? "request"): \(issue.reason.rawValue)"
        })
        lines.append("This command does not switch accounts, edit history, or intercept desktop requests.")
        return lines.joined(separator: "\n")
    }

    /// Exclusive creation also rejects hard links and symlinks to the original input/history.
    /// Set owner-only permissions before writing content, and never overwrite an existing file.
    static func writeReplayRequest(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReplayRequestWriteFailure.create }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func prepareReplayRequestHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar history prepare-request --input-file <request.json>
                                          [--cross-backend] [--output-file <new.json>] [--json]

        Prepare a complete Responses request for offline compatibility verification.
        Input must be the active model-visible input array, not a JSONL rollout or a partial delta.
        The default checks type-specific item IDs on the same backend. --cross-backend also removes
        portable item IDs and reasoning state when backend/account identity changes or is unknown.
        Opaque compaction, server-side history references, foreign file IDs and incomplete tool
        exchanges block projection. The exit code is 0 for ready, 2 for blocked, 1 for invalid input.
        Without --output-file, only content-free diagnostics are printed. Output must be a new file.
        Source files, accounts and routes are never changed. This is not a desktop request hook.
        """
    }
}

private struct ReplayCompatibilityCLIReport: Encodable {
    let status: String
    let requestFileWritten: Bool
    let report: CodexReplayCompatibility.Report
}

private enum ReplayRequestWriteFailure: Error {
    case create
}

struct PrepareReplayRequestOptions: CommanderParsable {
    @Option(name: .long("input-file"), help: "Complete Responses request JSON (no default history scan)")
    var inputFile: String?

    @Option(name: .long("output-file"), help: "New owner-only request file; never overwrite an existing file")
    var outputFile: String?

    @Flag(name: .long("cross-backend"), help: "Backend/account changed, or item provenance is unknown")
    var crossBackend: Bool = false

    @Flag(name: .long("json"), help: "Emit content-free JSON diagnostics")
    var jsonShortcut: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON diagnostics")
    var pretty: Bool = false
}
