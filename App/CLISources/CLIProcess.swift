import Foundation
import Dispatch
import Darwin

enum CLIProcess {
    static func run(transport: any CLISearchTransport, arguments: [String]) async {
        signal(SIGPIPE, SIG_IGN)
        let task = Task { await CLIRunner(transport: transport).run(arguments: arguments) }
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interruption.setEventHandler { task.cancel() }
        termination.setEventHandler { task.cancel() }
        interruption.resume()
        termination.resume()
        let result = await task.value
        interruption.cancel()
        termination.cancel()
        let outputStatus = write(result.stdout, to: STDOUT_FILENO)
        let errorStatus = write(result.stderr, to: STDERR_FILENO)
        exit(outputStatus == 0 && errorStatus == 0 ? result.exitCode : 5)
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if errno == EINTR { continue }
                if errno == EPIPE { return 0 }
                return 5
            }
            return 0
        }
    }
}
