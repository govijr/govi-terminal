import Foundation
import Darwin

/// The one way Govi runs a subprocess: an argument array (no shell), no stdin,
/// a deadline, a cap on captured output, and optional cancellation. Call the
/// synchronous form off the UI thread; the async form runs on a detached task.
/// A hung helper, `git push` or network filesystem cannot block Govi forever.
enum GoviLocalProcess {
    /// What happens to the child's standard error.
    enum Errors: Sendable { case discard, merge, separate }

    struct Result: Sendable {
        let status: Int32
        let output: String
        /// Standard error when run with `.separate`; otherwise empty.
        let errors: String
        let timedOut: Bool
        let cancelled: Bool
    }

    /// Thread-safe flag a caller can set to stop a running process early.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        init() {}
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4, limit: Int = 262_144,
                    environment: [String: String]? = nil, directory: String? = nil, errors: Errors = .discard,
                    cancellation: Cancellation? = nil) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        let output = Pipe()
        let errorPipe = errors == .separate ? Pipe() : nil
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        switch errors {
        case .discard: process.standardError = FileHandle.nullDevice
        case .merge: process.standardError = output
        case .separate: process.standardError = errorPipe
        }
        guard (try? process.run()) != nil else { return nil }
        // Close our copies of the write ends so EOF arrives when the child exits.
        try? output.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()
        defer {
            try? output.fileHandleForReading.close()
            try? errorPipe?.fileHandleForReading.close()
        }

        var streams = [Stream(output.fileHandleForReading.fileDescriptor)]
        if let errorPipe { streams.append(Stream(errorPipe.fileHandleForReading.fileDescriptor)) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            for index in streams.indices { streams[index].drain(into: &buffer, limit: limit) }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, cancelled = false
        var descriptors = streams.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
        while process.isRunning {
            // Wake as soon as output arrives instead of sleeping a fixed interval.
            if Darwin.poll(&descriptors, nfds_t(descriptors.count), 10) > 0,
               descriptors.allSatisfy({ $0.revents & Int16(POLLIN) == 0 }) {
                usleep(1_000) // Only hang-ups are pending: the child is exiting.
            }
            drain()
            if cancellation?.isCancelled == true { cancelled = true; break }
            if Date() >= deadline { timedOut = true; break }
        }
        if timedOut || cancelled {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace { usleep(10_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        drain()
        return Result(status: process.terminationStatus,
                      output: String(decoding: streams[0].data, as: UTF8.self),
                      errors: streams.count > 1 ? String(decoding: streams[1].data, as: UTF8.self) : "",
                      timedOut: timedOut, cancelled: cancelled)
    }

    /// Runs on a detached task. Cancelling the calling task stops the process.
    static func runAsync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4, limit: Int = 262_144,
                         environment: [String: String]? = nil, directory: String? = nil,
                         errors: Errors = .discard) async -> Result? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                run(executable, arguments, timeout: timeout, limit: limit, environment: environment,
                    directory: directory, errors: errors, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private struct Stream {
        let fd: Int32
        var data = Data()
        init(_ fd: Int32) {
            self.fd = fd
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        /// Reads what is available, keeping at most `limit` bytes. Bounded so a
        /// child writing faster than we read still lets the deadline be checked.
        mutating func drain(into buffer: inout [UInt8], limit: Int) {
            for _ in 0..<32 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                if data.count < limit { data.append(contentsOf: buffer.prefix(min(count, limit - data.count))) }
            }
        }
    }
}

/// Git, run through `GoviLocalProcess` with prompts disabled. Credential or
/// SSH prompts fail fast instead of waiting on input nobody can see.
enum GoviGit {
    /// Git's well-known empty tree, used as the diff base before the first commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Default deadline for local commands; network commands pass a longer one.
    static let localTimeout: TimeInterval = 15
    static let networkTimeout: TimeInterval = 120

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        return environment
    }

    /// Runs git and returns its untrimmed standard output, so porcelain formats
    /// parse exactly. Throws with git's message when the status is not allowed.
    @discardableResult
    static func output(_ directory: String, _ arguments: [String], allow: Set<Int32> = [0], mergeErrors: Bool = false,
                       timeout: TimeInterval = localTimeout, limit: Int = 16_777_216,
                       cancellation: GoviLocalProcess.Cancellation? = nil) throws -> String {
        guard let result = GoviLocalProcess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout, limit: limit,
                                                environment: environment, errors: mergeErrors ? .merge : .separate,
                                                cancellation: cancellation) else {
            throw failure(-1, "Govi could not start /usr/bin/git.")
        }
        if result.cancelled { throw CancellationError() }
        if result.timedOut {
            throw failure(-2, "git \(arguments.first ?? "") did not finish within \(Int(timeout)) seconds and was stopped.")
        }
        guard allow.contains(result.status) else {
            let message = (mergeErrors ? result.output : result.errors).trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(result.status, message.isEmpty ? "git exited with status \(result.status)" : message)
        }
        return result.output
    }

    /// Runs git with merged output, trimmed. For commands whose text is a value.
    @discardableResult
    static func run(_ directory: String, _ arguments: [String], timeout: TimeInterval = localTimeout) throws -> String {
        try output(directory, arguments, mergeErrors: true, timeout: timeout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repository root containing `directory`, if any.
    static func topLevel(_ directory: String) -> String? {
        try? run(directory, ["rev-parse", "--show-toplevel"])
    }

    /// Creates a branch and worktree next to the repository, at
    /// `<parent>/<repo>.worktrees/<branch>`, based on the current HEAD.
    static func createWorktree(repository top: String, branch: String) throws -> String {
        _ = try run(top, ["check-ref-format", "--branch", branch])
        let repo = URL(fileURLWithPath: top)
        let folder = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + ".worktrees")
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        var path = folder.appendingPathComponent(slug).path
        var suffix = 2
        while FileManager.default.fileExists(atPath: path) {
            path = folder.appendingPathComponent("\(slug)-\(suffix)").path
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Checking out a large tree can take a while; it is still local work.
        _ = try run(top, ["worktree", "add", "-b", branch, "--", path], timeout: networkTimeout)
        return path
    }

    private static func failure(_ code: Int32, _ message: String) -> NSError {
        NSError(domain: "GoviGit", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The Changes panel's git calls: literal pathspecs and unquoted paths so
/// porcelain output maps back to file names exactly.
enum GoviGitRunner {
    static let emptyTree = GoviGit.emptyTree

    @discardableResult
    static func run(_ directory: String, _ arguments: [String], allow: Set<Int32> = [0], mergeErrors: Bool = false,
                    timeout: TimeInterval = GoviGit.localTimeout) throws -> String {
        try GoviGit.output(directory, ["--literal-pathspecs", "-c", "core.quotepath=off"] + arguments,
                           allow: allow, mergeErrors: mergeErrors, timeout: timeout)
    }
}
