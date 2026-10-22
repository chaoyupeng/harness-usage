import Foundation
import Combine

struct CodexLimitWindow: Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Date?

    var fractionUsed: Double {
        min(max((usedPercent ?? 0) / 100, 0), 1)
    }

    var label: String {
        guard let minutes = windowDurationMins else { return "Usage window" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))-Day Window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-Hour Window" }
        return "\(minutes)-Minute Window"
    }

    var shortLabel: String {
        guard let minutes = windowDurationMins else { return "use" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct CodexRateLimits: Equatable {
    let primary: CodexLimitWindow?
    let secondary: CodexLimitWindow?

    static func parse(_ result: [String: Any]) -> CodexRateLimits? {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let bucket else { return nil }
        let primary = parseWindow(bucket["primary"])
        let secondary = parseWindow(bucket["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateLimits(primary: primary, secondary: secondary)
    }

    private static func parseWindow(_ value: Any?) -> CodexLimitWindow? {
        guard let data = value as? [String: Any] else { return nil }
        let used = (data["usedPercent"] as? NSNumber)?.doubleValue
        let duration = (data["windowDurationMins"] as? NSNumber)?.intValue
        let reset = (data["resetsAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return CodexLimitWindow(usedPercent: used, windowDurationMins: duration, resetsAt: reset)
    }
}

struct CodexSnapshot {
    let isSignedIn: Bool
    let limits: CodexRateLimits?
}

enum CodexAppServerError: LocalizedError {
    case notInstalled
    case noResponse
    case response(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Codex CLI is not installed"
        case .noResponse: "Codex did not respond"
        case .response(let message): message
        }
    }
}

/// Talks to the documented Codex app-server account API. Codex handles its own
/// authentication, so this app never reads or stores Codex credentials.
struct CodexAppServerClient {
    let executableURL: URL

    static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        var paths = [String]()
        if let override = environment["CODEX_CLI_PATH"] { paths.append(override) }
        paths += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        paths += [
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return paths.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func fetch() throws -> CodexSnapshot {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.schedule(deadline: .now() + 12)
        timeout.setEventHandler { if process.isRunning { process.terminate() } }
        timeout.resume()
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        var reader = ResponseReader(handle: output.fileHandleForReading)
        try send(
            ["method": "initialize", "id": 1, "params": [
                "clientInfo": ["name": "ai_usage", "title": "AI Usage", "version": "1.0.0"]
            ]],
            to: input.fileHandleForWriting
        )
        _ = try reader.response(for: 1)
        try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try send(["method": "account/read", "id": 2, "params": ["refreshToken": false]], to: input.fileHandleForWriting)
        let account = try reader.response(for: 2)
        let accountType = ((account["result"] as? [String: Any])?["account"] as? [String: Any])?["type"] as? String
        guard accountType == "chatgpt" || accountType == "personalAccessToken" else {
            return CodexSnapshot(isSignedIn: false, limits: nil)
        }

        try send(["method": "account/rateLimits/read", "id": 3], to: input.fileHandleForWriting)
        let limitsResponse = try reader.response(for: 3)
        let result = limitsResponse["result"] as? [String: Any] ?? [:]
        return CodexSnapshot(isSignedIn: true, limits: CodexRateLimits.parse(result))
    }

    private func send(_ message: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private struct ResponseReader {
        let handle: FileHandle
        var line = Data()

        mutating func response(for id: Int) throws -> [String: Any] {
            while true {
                guard let byte = try handle.read(upToCount: 1)?.first else {
                    throw CodexAppServerError.noResponse
                }
                if byte == 0x0A {
                    defer { line.removeAll(keepingCapacity: true) }
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (object["id"] as? NSNumber)?.intValue == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw CodexAppServerError.response(
                            error["message"] as? String ?? "Codex returned an error"
                        )
                    }
                    return object
                }
                line.append(byte)
            }
        }
    }
}

@MainActor
final class CodexUsageService: ObservableObject {
    enum Status: Equatable {
        case checking
        case notInstalled
        case signedOut
        case available
        case unavailable
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var limits: CodexRateLimits?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    var isAvailable: Bool { status == .available }
    private var timer: Timer?
    private var isRefreshing = false

    func startPolling() {
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let executable = CodexAppServerClient.findExecutable() else {
            status = .notInstalled
            limits = nil
            lastError = nil
            return
        }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try CodexAppServerClient(executableURL: executable).fetch()
            }.value
            limits = snapshot.limits
            status = snapshot.isSignedIn ? (snapshot.limits == nil ? .unavailable : .available) : .signedOut
            lastError = snapshot.isSignedIn && snapshot.limits == nil ? "Codex usage is unavailable right now" : nil
            if snapshot.limits != nil { lastUpdated = Date() }
        } catch {
            status = .unavailable
            lastError = error.localizedDescription
        }
    }
}
