import Foundation
import IndexCore

struct CLIOptions: Equatable {
    enum Format: String { case paths, json }
    let query: String
    let format: Format
    let usesNull: Bool
    let limit: Int
    let timeout: TimeInterval
    let matchPath: Bool
    let caseSensitive: Bool
    let wholeWord: Bool

    static let help = """
    Usage: everythingmac search [options] -- <query>

    Options:
      --format paths|json  Output format (default: paths)
      --null               Separate paths with NUL bytes
      --limit N            Maximum results, 1...10000 (default: 1000)
      --timeout SECONDS    End-to-end deadline, at most 3600 (default: 30)
      --match-path         Match ancestor path components
      --case-sensitive     Match case exactly
      --whole-word         Match whole words
      --help               Show this help
      --version            Show the version

    Examples:
      everythingmac search -- 'kind:pdf "annual report"'
      everythingmac search --match-path -- 'path:~/Documents'
      everythingmac search --format json -- 'rx:^report[0-9]+$'
      everythingmac search --null -- 'kind:image' | xargs -0 -n1 printf '%s\\n'
    """

    static func parse(arguments: [String]) throws -> CLIOptions? {
        guard !arguments.isEmpty else { throw CLIError.invalidArguments("Expected a command.") }
        if arguments == ["--help"] || arguments == ["help"] || arguments == ["search", "--help"] || arguments == ["search", "--version"] { return nil }
        if arguments == ["--version"] { return nil }
        guard arguments.first == "search" else { throw CLIError.invalidArguments("Expected `search`.") }
        var values = Values()
        var query: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let values = Array(arguments.dropFirst(index + 1))
                guard values.count == 1 else { throw CLIError.invalidArguments("Provide exactly one query after `--`.") }
                query = values[0]
                break
            }
            index = try values.consume(argument, in: arguments, at: index)
            index += 1
        }
        guard let query else { throw CLIError.invalidArguments("Provide a query after `--`.") }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !query.utf8.contains(0), query.lengthOfBytes(using: .utf8) <= 16 * 1024 else {
            throw CLIError.invalidArguments("Query must be nonblank, contain no NUL bytes, and be at most 16 KiB.")
        }
        guard !values.usesNull || values.format == .paths else { throw CLIError.invalidArguments("`--null` requires `--format paths`.") }
        return CLIOptions(query: query, format: values.format, usesNull: values.usesNull, limit: values.limit, timeout: values.timeout,
                          matchPath: values.matchPath, caseSensitive: values.caseSensitive, wholeWord: values.wholeWord)
    }

    private struct Values {
        var format: Format = .paths
        var usesNull = false
        var limit = 1_000
        var timeout: TimeInterval = 30
        var matchPath = false
        var caseSensitive = false
        var wholeWord = false

        mutating func consume(_ argument: String, in arguments: [String], at index: Int) throws -> Int {
            if consumeFlag(argument) { return index }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { throw CLIError.invalidArguments("Missing value for `\(argument)`.") }
            switch argument {
            case "--format":
                guard let value = Format(rawValue: arguments[valueIndex]) else { throw CLIError.invalidArguments("`--format` must be `paths` or `json`.") }
                format = value
            case "--limit":
                guard let value = Int(arguments[valueIndex]), (1...10_000).contains(value) else { throw CLIError.invalidArguments("`--limit` must be an integer from 1 to 10000.") }
                limit = value
            case "--timeout":
                guard let value = TimeInterval(arguments[valueIndex]), value.isFinite,
                      value > 0, value <= 3_600 else {
                    throw CLIError.invalidArguments("`--timeout` must be finite, positive, and at most 3600 seconds.")
                }
                timeout = value
            default: throw CLIError.invalidArguments("Unknown option `\(argument)`.")
            }
            return valueIndex
        }

        private mutating func consumeFlag(_ argument: String) -> Bool {
            switch argument {
            case "--null": usesNull = true
            case "--match-path": matchPath = true
            case "--case-sensitive": caseSensitive = true
            case "--whole-word": wholeWord = true
            default: return false
            }
            return true
        }
    }
}

enum CLIError: Error, Equatable {
    case invalidArguments(String), unavailable(String), timeout, interrupted, internalError(String)

    var exitCode: Int32 {
        switch self {
        case .invalidArguments: 2
        case .unavailable: 3
        case .timeout: 4
        case .interrupted: 130
        case .internalError: 5
        }
    }

    var message: String {
        switch self {
        case let .invalidArguments(message), let .unavailable(message), let .internalError(message): message
        case .timeout: "Search timed out."
        case .interrupted: "Search interrupted."
        }
    }
}

protocol CLISearchTransport: Sendable {
    func search(_ request: SearchRequest, requestID: UUID, deadline: Date) async throws -> SearchResponse
    func cancel(_ requestID: UUID) async
}

struct CLIResult: Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

struct CLIRunner {
    let transport: any CLISearchTransport
    let now: @Sendable () -> Date

    init(transport: any CLISearchTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func run(arguments: [String]) async -> CLIResult {
        do {
            if arguments == ["--help"] || arguments == ["help"] || arguments == ["search", "--help"] {
                return success(stdout: Data((CLIOptions.help + "\n").utf8))
            }
            if arguments == ["--version"] || arguments == ["search", "--version"] {
                return success(stdout: Data("EverythingMac 0.9.7\n".utf8))
            }
            let options = try CLIOptions.parse(arguments: arguments)
            guard let options else { return success(stdout: Data((CLIOptions.help + "\n").utf8)) }
            let requestID = UUID()
            let request = SearchRequest(text: options.query, matchPath: options.matchPath,
                                        caseInsensitive: !options.caseSensitive, wholeWord: options.wholeWord,
                                        usesRegularExpression: false, sort: .name, ascending: true,
                                        limit: options.limit, supersedeExisting: false)
            let response = try await response(for: request, requestID: requestID, timeout: options.timeout)
            return success(stdout: format(response, as: options))
        } catch let error as CLIError {
            return failure(error)
        } catch {
            return failure(.internalError(error.localizedDescription))
        }
    }

    private func response(for request: SearchRequest, requestID: UUID, timeout: TimeInterval) async throws -> SearchResponse {
        let deadline = now().addingTimeInterval(timeout)
        do {
            let race = CLIResponseContinuation()
            let searchTask = Task {
                do {
                    race.complete(.success(try await transport.search(request, requestID: requestID, deadline: deadline)))
                } catch {
                    race.complete(.failure(error))
                }
            }
            let timerTask = Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    race.complete(.failure(CLIError.timeout))
                } catch { }
            }
            defer { searchTask.cancel(); timerTask.cancel() }
            return try await withTaskCancellationHandler(operation: {
                try await race.wait()
            }, onCancel: {
                race.complete(.failure(CancellationError()))
            })
        } catch is CancellationError {
            await transport.cancel(requestID)
            throw CLIError.interrupted
        } catch let error as CLIError {
            await transport.cancel(requestID)
            throw error
        }
    }

    private func format(_ response: SearchResponse, as options: CLIOptions) -> Data {
        switch options.format {
        case .paths:
            let delimiter = options.usesNull ? "\0" : "\n"
            return Data((response.records.map(\.path).joined(separator: delimiter) + (response.records.isEmpty ? "" : delimiter)).utf8)
        case .json:
            let formatter = ISO8601DateFormatter()
            let records = response.records.map { record in
                CLIJSONResult(path: record.path, name: record.name, isDirectory: record.isDir,
                              sizeBytes: record.id == 0 ? nil : Int64(exactly: record.size),
                              modifiedAt: record.id == 0 ? nil : formatter.string(
                                  from: Date(timeIntervalSince1970: TimeInterval(record.mtime))
                              ))
            }
            let envelope = CLIJSONEnvelope(schemaVersion: 1, results: records, returnedCount: records.count,
                                           limit: response.limit, truncated: response.truncated, scanning: response.scanning)
            return (try? JSONEncoder().encode(envelope)) ?? Data()
        }
    }

    private func success(stdout: Data) -> CLIResult { CLIResult(exitCode: 0, stdout: stdout, stderr: Data()) }
    private func failure(_ error: CLIError) -> CLIResult {
        CLIResult(exitCode: error.exitCode, stdout: Data(), stderr: Data((error.message + "\n").utf8))
    }
}

private final class CLIResponseContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SearchResponse, Error>?
    private var result: Result<SearchResponse, Error>?

    func wait() async throws -> SearchResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ result: Result<SearchResponse, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct CLIJSONEnvelope: Encodable {
    let schemaVersion: Int
    let results: [CLIJSONResult]
    let returnedCount: Int
    let limit: Int
    let truncated: Bool
    let scanning: Bool
}

private struct CLIJSONResult: Encodable {
    let path: String
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let modifiedAt: String?
}
