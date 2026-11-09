import Foundation
import Combine
import Darwin

/// A private, local connection to zsh's line editor. The shell owns rendering
/// and Tab acceptance; this service only returns text candidates, never input
/// to a terminal, commands to execute, or changes to the user's startup files.
@MainActor final class GoviInlineService {
    static let shared = GoviInlineService()
    private var listener: DispatchSourceRead?
    private var directory: String?
    private var path: String?
    private var clients: [UUID: Client] = [:]
    private var preferencesObserver: NSObjectProtocol?
    private var recent: [String] = []
    private var preferences = Preferences()
    private let io = DispatchQueue(label: "app.govi.inline.io", qos: .userInitiated)

    func start() -> String? {
        if let path { return path }
        var template = Array("/tmp/govi-inline-XXXXXX".utf8CString)
        guard
            let directory = template.withUnsafeMutableBufferPointer({ buffer in
                mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
            })
        else { return nil }
        let path = directory + "/s"
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 64) == 0 else {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: directory)
            return nil
        }
        Self.configure(descriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: io)
        let io = self.io
        source.setEventHandler { [weak self] in
            while true {
                let peer = Darwin.accept(descriptor, nil, nil)
                if peer < 0 { return }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(peer, &uid, &gid) == 0, uid == geteuid() else {
                    Darwin.close(peer)
                    continue
                }
                Self.configure(peer)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.path != nil, self.clients.count < 64 else {
                        Darwin.close(peer)
                        return
                    }
                    self.add(peer, queue: io)
                }
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.directory = directory
        self.path = path
        listener = source
        source.resume()
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let updated = Preferences()
                guard updated != self.preferences else { return }
                self.preferences = updated
                for client in self.clients.values { self.refresh(client) }
            }
        }
        return path
    }
    func stop() {
        path = nil
        listener?.cancel()
        listener = nil
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        for client in clients.values {
            client.suggestions?.stop()
            client.peer.close()
        }
        clients.removeAll()
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }
    nonisolated private static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }
    private func add(_ descriptor: Int32, queue: DispatchQueue) {
        let id = UUID()
        let peer = GoviInlinePeer(descriptor: descriptor, queue: queue)
        let client = Client(peer: peer)
        clients[id] = client
        peer.onLine = { [weak self] line in self?.receive(line, from: id) }
        peer.onClose = { [weak self] in self?.clients.removeValue(forKey: id)?.suggestions?.stop() }
        peer.start()
    }
    private func receive(_ line: String, from id: UUID) {
        guard let client = clients[id] else { return }
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let sequence = UInt64(fields[1]) else {
            client.peer.close()
            return
        }
        let value = fields[2]
        switch fields[0] {
        case "A":
            if let signal = GoviActivitySignal.decode(value) { GoviActivityCenter.shared.receive(signal) }
            client.peer.close()
        case "P":
            guard let data = value.data(using: .utf8),
                let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = packet["id"] as? String, let pane = UUID(uuidString: text),
                let live = packet["live"] as? Bool, let recovered = packet["recovered"] as? Bool
            else {
                client.peer.close()
                return
            }
            GoviPersistence.confirm(pane, live: live, recovered: recovered)
            client.peer.close()
        case "Q":
            guard !value.isEmpty, value.count <= 512, GoviCommandText.isSingleLine(value) else { return }
            client.sequence = String(sequence)
            client.prefix = value
            refresh(client)
        case "C":
            client.sequence = "0"
            client.prefix = ""
            client.suggestions?.update("\u{0}", saved: [])
        case "H":
            guard !value.hasPrefix(" "), value.count <= 512, GoviCommandText.isSingleLine(value) else { return }
            recent.removeAll { $0 == value }
            recent.append(value)
            if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        default: client.peer.close()
        }
    }
    private func refresh(_ client: Client) {
        guard !client.prefix.isEmpty else { return }
        if client.suggestions == nil {
            let suggestions = GoviSuggestions()
            client.suggestions = suggestions
            client.observer = suggestions.$items.sink { [weak client] items in
                guard let client, client.sequence != "0", !client.prefix.isEmpty else { return }
                let candidate = items.first?.command ?? ""
                let color = GoviTheme.hex(GoviTheme.current.muted)
                client.peer.send("S\t\(client.sequence)\t\(color)\t\(client.prefix)\t\(candidate)\n")
            }
        }
        client.suggestions?.update(client.prefix, saved: GoviNotebook.shared.commands, recent: recent)
    }
    @MainActor private final class Client {
        let peer: GoviInlinePeer
        var suggestions: GoviSuggestions?
        var observer: AnyCancellable?
        var sequence = "0"
        var prefix = ""
        init(peer: GoviInlinePeer) { self.peer = peer }
    }
    private struct Preferences: Equatable {
        var enabled = UserDefaults.standard.object(forKey: "GoviLocalSuggestions") as? Bool != false
        var ranking = UserDefaults.standard.bool(forKey: "GoviJevRanking")
        var theme = UserDefaults.standard.string(forKey: "GoviTheme") ?? "graphite"
        var commands = UserDefaults.standard.data(forKey: "GoviCommands")
    }
}

/// Nonblocking, bounded UTF-8 lines. No shell interpolation, evaluation, or
/// credentials cross this socket. All descriptor operations use one IO queue.
private final class GoviInlinePeer: @unchecked Sendable {
    let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var writable: DispatchSourceWrite?
    private var incoming = Data(), outgoing = Data()
    private var closed = false
    var onLine: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?
    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
    }
    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            let descriptor = self.descriptor
            source.setCancelHandler { Darwin.close(descriptor) }
            self.source = source
            source.resume()
        }
    }
    func send(_ line: String) {
        let data = Data(line.utf8)
        queue.async { [self] in
            guard !closed else { return }
            guard outgoing.count + data.count <= 32_768 else {
                closeOnQueue()
                return
            }
            outgoing.append(data)
            flush()
        }
    }
    func close() { queue.async { [self] in closeOnQueue() } }
    private func readAvailable() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { closeOnQueue() }
                return
            }
            guard count > 0 else {
                closeOnQueue()
                return
            }
            incoming.append(contentsOf: bytes.prefix(count))
            guard incoming.count <= 16_384 else {
                closeOnQueue()
                return
            }
            while let newline = incoming.firstIndex(of: 10) {
                guard let line = String(data: incoming[..<newline], encoding: .utf8), line.utf8.count <= 4096 else {
                    closeOnQueue()
                    return
                }
                incoming.removeSubrange(...newline)
                DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
            }
        }
    }
    private func flush() {
        guard !closed else { return }
        while !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if writable == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                        source.setEventHandler { [weak self] in self?.flush() }
                        writable = source
                        source.resume()
                    }
                } else {
                    closeOnQueue()
                }
                return
            }
            guard count > 0 else {
                closeOnQueue()
                return
            }
            outgoing.removeFirst(count)
        }
        writable?.cancel()
        writable = nil
    }
    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        writable?.cancel()
        writable = nil
        source?.cancel()
        source = nil
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
