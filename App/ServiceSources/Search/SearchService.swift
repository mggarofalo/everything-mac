import Foundation

final class SearchService: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private var closed = false
    private let lease: ConnectionLease
    private let role: SearchClientRole
    private let automation: AutomationAccess
    private let testForward: (@Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void)?
    private let testCancel: (@Sendable () -> Void)?
    private var observerID: UUID?
    private var pending: [UUID: (ReplyOnce, @Sendable (Data) -> Void)] = [:]

    init(lease: ConnectionLease, role: SearchClientRole, automation: AutomationAccess,
         testForward: (@Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void)? = nil,
         testCancel: (@Sendable () -> Void)? = nil) {
        self.lease = lease
        self.role = role
        self.automation = automation
        self.testForward = testForward
        self.testCancel = testCancel
        super.init()
        if role == .cli {
            observerID = automation.observe { [weak self] in self?.revoke() }
        }
    }

    func perform(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let once = ReplyOnce()
        let request: ServiceRequest
        do {
            request = try JSONDecoder().decode(ServiceRequest.self, from: data)
        } catch {
            Self.send(.failure("Invalid service request", code: .invalidQuery), once: once, to: reply)
            return
        }
        handle(request, once: once, reply: reply)
    }

    private func handle(_ request: ServiceRequest, once: ReplyOnce,
                        reply: @escaping @Sendable (Data) -> Void) {
        guard role.allows(request.operation), role != .cli || automation.isEnabled else {
            Self.send(.failure("Command-line search access is disabled.", code: .permissionDenied),
                      once: once, to: reply)
            return
        }
        if request.operation == .getAutomationAccess {
            Self.send(.success(automation.isEnabled), once: once, to: reply)
            return
        }
        if request.operation == .setAutomationAccess {
            guard let payload = request.payload,
                  let enabled = try? JSONDecoder().decode(Bool.self, from: payload) else {
                Self.send(.failure("Invalid preference value", code: .invalidQuery), once: once, to: reply)
                return
            }
            do {
                try automation.setEnabled(enabled)
                Self.send(.success(true), once: once, to: reply)
            } catch {
                Self.send(.failure("Could not save command-line access", code: .internalError),
                          once: once, to: reply)
            }
            return
        }
        let forwarded: Data
        do {
            forwarded = try JSONEncoder().encode(request.trustedForwarding(interactive: role == .app))
        } catch {
            Self.send(.failure("Invalid service request", code: .invalidQuery), once: once, to: reply)
            return
        }
        forward(forwarded, once: once, reply: reply)
    }

    private func forward(_ forwarded: Data, once: ReplyOnce,
                         reply: @escaping @Sendable (Data) -> Void) {
        let replyID = UUID()
        connectionLock.lock()
        let accepted = !closed && pending.count < 32
        if accepted { pending[replyID] = (once, reply) }
        connectionLock.unlock()
        guard accepted else {
            Self.send(.failure("Too many requests", code: .overloaded), once: once, to: reply)
            return
        }
        if role == .cli && !automation.isEnabled {
            revoke()
            return
        }
        if let testForward {
            testForward(forwarded) { [weak self] data in self?.finish(replyID, data: data) }
            return
        }
        guard let connection = activeConnection() else {
            let failure: ServiceReply = role == .cli && !automation.isEnabled
                ? .failure("Command-line search access is disabled.", code: .permissionDenied)
                : .failure("Search session closed", code: .serviceUnavailable)
            finish(replyID, with: failure)
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.discardConnection(connection)
            self?.finish(replyID, with: .failure("Index service unavailable", code: .serviceUnavailable))
        }
        guard let service = proxy as? EverythingMacServiceProtocol else {
            finish(replyID, with: .failure("Index service unavailable", code: .serviceUnavailable))
            return
        }
        service.perform(forwarded) { [weak self] data in self?.finish(replyID, data: data) }
    }

    func close() {
        connectionLock.lock()
        closed = true
        let oldConnection = connection
        connection = nil
        let abandoned = Array(pending.values)
        pending.removeAll()
        connectionLock.unlock()
        automation.removeObserver(observerID)
        oldConnection?.invalidate()
        testCancel?()
        for (once, reply) in abandoned {
            Self.send(.failure("Search session closed", code: .serviceUnavailable), once: once, to: reply)
        }
        lease.close()
    }

    private func revoke() {
        connectionLock.lock()
        let oldConnection = connection
        connection = nil
        let abandoned = Array(pending.values)
        pending.removeAll()
        connectionLock.unlock()
        oldConnection?.invalidate()
        testCancel?()
        for (once, reply) in abandoned {
            Self.send(.failure("Command-line search access is disabled.", code: .permissionDenied),
                      once: once, to: reply)
        }
    }

    private func finish(_ id: UUID, data: Data) {
        connectionLock.lock()
        let callback = pending.removeValue(forKey: id)
        connectionLock.unlock()
        if let (once, reply) = callback {
            if role == .app {
                once.deliver(data, to: reply)
            } else if !automation.deliverIfEnabled({ once.deliver(data, to: reply) }) {
                Self.send(.failure("Command-line search access is disabled.", code: .permissionDenied),
                          once: once, to: reply)
            }
        }
    }

    private func finish(_ id: UUID, with failure: ServiceReply) {
        connectionLock.lock()
        let callback = pending.removeValue(forKey: id)
        connectionLock.unlock()
        if let (once, reply) = callback { Self.send(failure, once: once, to: reply) }
    }

    private static func send(_ value: ServiceReply, once: ReplyOnce,
                             to reply: @escaping @Sendable (Data) -> Void) {
        once.deliver((try? JSONEncoder().encode(value)) ?? Data(), to: reply)
    }

    private func activeConnection() -> NSXPCConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard !closed, role != .cli || automation.isEnabled else { return nil }
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: indexMachServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func discardConnection(_ candidate: NSXPCConnection) {
        connectionLock.lock()
        guard connection === candidate else {
            connectionLock.unlock()
            return
        }
        connection = nil
        connectionLock.unlock()
        candidate.invalidate()
    }
}
