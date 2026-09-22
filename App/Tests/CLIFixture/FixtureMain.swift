import Foundation
import IndexCore

@main
enum CLIFixtureMain {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let transport = FixtureTransport(
            mode: environment["EVERYTHINGMAC_FIXTURE_MODE"] ?? "trap",
            readyPath: environment["EVERYTHINGMAC_FIXTURE_READY_PATH"],
            releasePath: environment["EVERYTHINGMAC_FIXTURE_RELEASE_PATH"],
            cancelPath: environment["EVERYTHINGMAC_FIXTURE_CANCEL_PATH"]
        )
        await CLIProcess.run(transport: transport,
                             arguments: Array(CommandLine.arguments.dropFirst()))
    }
}

private final class FixtureTransport: CLISearchTransport, @unchecked Sendable {
    let mode: String
    let readyPath: String?
    let releasePath: String?
    let cancelPath: String?

    init(mode: String, readyPath: String?, releasePath: String?, cancelPath: String?) {
        self.mode = mode
        self.readyPath = readyPath
        self.releasePath = releasePath
        self.cancelPath = cancelPath
    }

    func search(_ request: SearchRequest, requestID: UUID, deadline: Date) async throws -> SearchResponse {
        switch mode {
        case "unavailable": throw CLIError.unavailable("Fixture search service unavailable.")
        case "never":
            mark(readyPath)
            try await Task.sleep(for: .seconds(3_600))
            fatalError("Never-reply transport unexpectedly completed")
        case "results":
            mark(readyPath)
            if let releasePath {
                while !FileManager.default.fileExists(atPath: releasePath) {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let record = FileRecord(id: 1, name: "fixture-result", path: "/tmp/fixture-result",
                                    parent: 0, size: 0, mtime: 0, isDir: false, volID: 1)
            return SearchResponse(records: [record], limit: request.limit)
        default: fatalError("Offline command invoked the fixture transport")
        }
    }

    func cancel(_ requestID: UUID) async { mark(cancelPath) }

    private func mark(_ path: String?) {
        guard let path else { return }
        try? Data("ready".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
