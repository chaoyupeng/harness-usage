import Foundation
import Combine

struct CodexTokenUsage: Equatable {
    var input = 0
    var cachedInput = 0
    var cacheWriteInput = 0
    var output = 0
    var reasoningOutput = 0

    var total: Int { input + output }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input,
             cachedInput: a.cachedInput + b.cachedInput,
             cacheWriteInput: a.cacheWriteInput + b.cacheWriteInput,
             output: a.output + b.output,
             reasoningOutput: a.reasoningOutput + b.reasoningOutput)
    }

    static func parse(_ value: Any?) -> Self? {
        guard let fields = value as? [String: Any],
              let input = fields["input_tokens"] as? Int,
              let output = fields["output_tokens"] as? Int else { return nil }
        return Self(input: max(input, 0),
                    cachedInput: max(fields["cached_input_tokens"] as? Int ?? 0, 0),
                    cacheWriteInput: max(fields["cache_write_input_tokens"] as? Int ?? 0, 0),
                    output: max(output, 0),
                    reasoningOutput: max(fields["reasoning_output_tokens"] as? Int ?? 0, 0))
    }
}

struct CodexTokenRecord {
    let timestamp: Date
    let usage: CodexTokenUsage
    let responseKey: String?
}

struct CodexTokenStats {
    var allTime = CodexTokenUsage()
    var today = CodexTokenUsage()
    var responseCount = 0
}

enum CodexLogReader {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDateFormatter = ISO8601DateFormatter()

    static func parse(_ data: Data) -> [CodexTokenRecord] {
        var records: [CodexTokenRecord] = []
        var fallback: [CodexTokenRecord] = []
        var lastCumulative = -1
        for line in data.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestampString = row["timestamp"] as? String,
                  let timestamp = dateFormatter.date(from: timestampString)
                    ?? plainDateFormatter.date(from: timestampString),
                  let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "token_usage_record",
               let usage = CodexTokenUsage.parse(payload["usage"]), usage.total > 0 {
                let thread = payload["thread_id"] as? String ?? ""
                let response = payload["response_id"] as? String ?? ""
                records.append(CodexTokenRecord(timestamp: timestamp, usage: usage,
                    responseKey: response.isEmpty ? nil : "\(thread)|\(response)"))
            } else if row["type"] as? String == "event_msg",
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let cumulative = CodexTokenUsage.parse(info["total_token_usage"]),
                      let usage = CodexTokenUsage.parse(info["last_token_usage"]),
                      cumulative.total > lastCumulative {
                lastCumulative = cumulative.total
                if usage.total > 0 {
                    fallback.append(CodexTokenRecord(timestamp: timestamp, usage: usage, responseKey: nil))
                }
            }
        }
        // Newer Codex sessions include both event_msg and token_usage_record
        // for the same response. Use the response records when available.
        return records.isEmpty ? fallback : records
    }

    static func aggregate(_ records: [CodexTokenRecord], now: Date = Date()) -> CodexTokenStats {
        let todayStart = Calendar.current.startOfDay(for: now)
        var stats = CodexTokenStats()
        var seen = Set<String>()
        for record in records {
            if let key = record.responseKey, !seen.insert(key).inserted { continue }
            stats.allTime = stats.allTime + record.usage
            stats.responseCount += 1
            if record.timestamp >= todayStart && record.timestamp <= now {
                stats.today = stats.today + record.usage
            }
        }
        return stats
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexTokenStats {
        var records: [CodexTokenRecord] = []
        let manager = FileManager.default
        for directory in [home.appendingPathComponent(".codex/sessions"),
                          home.appendingPathComponent(".codex/archived_sessions")] {
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let data = try? Data(contentsOf: url) { records += parse(data) }
            }
        }
        return aggregate(records)
    }
}

@MainActor
final class CodexLogService: ObservableObject {
    @Published private(set) var stats = CodexTokenStats()
    private var timer: Timer?
    private var isRefreshing = false

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let updated = await Task.detached(priority: .utility) { CodexLogReader.load() }.value
            stats = updated
            isRefreshing = false
        }
    }
}
