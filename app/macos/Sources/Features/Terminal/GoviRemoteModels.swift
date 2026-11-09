import Foundation
import Darwin

/// A remote shell Govi can open in a pane. Stored with the pane's launch intent,
/// so templates and recovery keep working when the saved host list changes.
/// No passwords, passphrases or key material are stored: ssh-agent, the
/// Keychain and `~/.ssh/config` stay in charge of authentication.
struct GoviRemoteTarget: Codable, Equatable, Hashable {
    enum Transport: String, Codable, CaseIterable {
        /// OpenSSH with the user's own configuration.
        case ssh
        /// OpenSSH to a tailnet device. Govi trusts the host keys the tailnet
        /// publishes for that device, so there is no first-connection prompt.
        case tailscale
    }
    var name: String
    var host: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var jumpHost: String?
    /// Folder to start in on the remote machine. `~` and `~/…` are relative to its home.
    var directory: String?
    var transport: Transport = .ssh

    var destination: String { user.map { $0 + "@" + host } ?? host }

    /// Rejects values that OpenSSH could read as options or that can't be a host.
    var validationError: String? {
        func token(_ value: String, extra: String = "") -> Bool {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:%[]" + extra))
            return !value.isEmpty && value.utf8.count <= 253 && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy(allowed.contains)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this host a name." }
        if name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) || name.count > 128 { return "Use a shorter name without control characters." }
        if !token(host) { return "Enter a host name, IP address or ~/.ssh/config alias (no spaces, not starting with “-”)." }
        if let user, !token(user, extra: "@\\$") { return "User names can't contain spaces or start with “-”." }
        if let port, !(1...65535).contains(port) { return "Ports are 1 to 65535." }
        if let jumpHost, !token(jumpHost, extra: "@,") { return "Jump hosts look like user@host:port, separated by commas." }
        if let identityFile, identityFile.isEmpty || identityFile.utf8.count > 1024 || identityFile.hasPrefix("-")
            || identityFile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) || !(identityFile.hasPrefix("/") || identityFile.hasPrefix("~")) {
            return "Choose an identity file by its full path."
        }
        if let directory, directory.utf8.count > 1024 || directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "The remote folder can't contain control characters."
        }
        return nil
    }

    /// Empty optional fields are stored as nil so equal hosts compare equal.
    func normalized() -> Self {
        func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.user = clean(user); copy.identityFile = clean(identityFile); copy.jumpHost = clean(jumpHost); copy.directory = clean(directory)
        if copy.directory == "~" { copy.directory = nil }
        if transport == .tailscale { copy.port = nil; copy.identityFile = nil; copy.jumpHost = nil }
        return copy
    }
}

struct GoviRemoteHost: Codable, Equatable, Identifiable {
    var id = UUID()
    var target: GoviRemoteTarget
}

// MARK: - ~/.ssh/config

/// Concrete `Host` aliases from an OpenSSH client configuration. Patterns
/// (`*`, `?`, `!`) are skipped: they describe defaults, not machines.
enum GoviSSHConfig {
    struct Entry: Equatable {
        var alias: String
        var hostName: String?
        var user: String?
        var port: Int?
    }

    /// `include` resolves an `Include` argument to the text of each matching file.
    static func parse(_ text: String, depth: Int = 0, include: (String) -> [String] = { _ in [] }) -> [Entry] {
        var entries: [Entry] = []
        var current: [Int] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let (keyword, arguments) = split(String(rawLine))
            guard let keyword else { continue }
            switch keyword {
            case "host":
                current = []
                for alias in arguments where !alias.contains(where: { "*?!".contains($0) }) && !alias.hasPrefix("-") {
                    if let index = entries.firstIndex(where: { $0.alias == alias }) { current.append(index) }
                    else { entries.append(.init(alias: alias)); current.append(entries.count - 1) }
                }
            case "match":
                current = []
            case "include":
                guard depth < 4 else { continue }
                for pattern in arguments {
                    for file in include(pattern) {
                        for entry in parse(file, depth: depth + 1, include: include) where !entries.contains(where: { $0.alias == entry.alias }) {
                            entries.append(entry)
                        }
                    }
                }
            case "hostname", "user", "port":
                guard let value = arguments.first else { continue }
                // OpenSSH uses the first value it sees for each option.
                for index in current {
                    switch keyword {
                    case "hostname": if entries[index].hostName == nil { entries[index].hostName = value }
                    case "user": if entries[index].user == nil { entries[index].user = value }
                    default: if entries[index].port == nil, let port = Int(value), (1...65535).contains(port) { entries[index].port = port }
                    }
                }
            default: continue
            }
        }
        return entries
    }

    /// Splits `Keyword args`, `Keyword=args` and double-quoted arguments; drops comments.
    static func split(_ line: String) -> (String?, [String]) {
        var tokens: [String] = [], token = "", quoted = false, started = false
        for character in line {
            if character == "\"" { quoted.toggle(); started = true; continue }
            if !quoted && character == "#" && token.isEmpty { break }
            if !quoted && (character == " " || character == "\t" || (character == "=" && tokens.isEmpty)) {
                if started || !token.isEmpty { tokens.append(token); token = ""; started = false }
                continue
            }
            token.append(character)
        }
        if started || !token.isEmpty { tokens.append(token) }
        guard let first = tokens.first, !first.isEmpty else { return (nil, []) }
        return (first.lowercased(), Array(tokens.dropFirst()))
    }

    /// Reads `~/.ssh/config` and its `Include`s from disk. Call off the main thread.
    static func load(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [Entry] {
        let sshDirectory = home + "/.ssh"
        func read(_ path: String) -> String? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let text = read(sshDirectory + "/config") else { return [] }
        return parse(text) { pattern in
            var expanded = pattern
            if expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst() }
            else if !expanded.hasPrefix("/") { expanded = sshDirectory + "/" + expanded }
            var result = glob_t()
            defer { globfree(&result) }
            guard glob(expanded, 0, nil, &result) == 0 else { return [] }
            return (0..<Int(result.gl_matchc)).prefix(64).compactMap { index in
                result.gl_pathv[index].flatMap { read(String(cString: $0)) }
            }
        }
    }
}

// MARK: - Tailscale

/// The subset of `tailscale status --json` Govi shows. Unknown fields are ignored.
struct GoviTailnet: Equatable {
    struct Device: Equatable, Identifiable {
        var id: String
        var name: String
        var dnsName: String?
        var addresses: [String]
        var os: String?
        var online: Bool
        /// Present when the device runs Tailscale SSH.
        var sshHostKeys: [String]
        var tags: [String]
        var isSelf: Bool

        var sshHost: String? { dnsName ?? addresses.first }
        var runsTailscaleSSH: Bool { !sshHostKeys.isEmpty }
        var target: GoviRemoteTarget? {
            guard let host = sshHost else { return nil }
            return .init(name: name, host: host, transport: .tailscale)
        }
    }
    var backendState: String
    var tailnetName: String?
    var magicDNSSuffix: String?
    var devices: [Device]
    var isRunning: Bool { backendState == "Running" }

    private struct Status: Decodable {
        let BackendState: String?
        let MagicDNSSuffix: String?
        let CurrentTailnet: Tailnet?
        let me: Peer?
        let peers: [String: Peer]?
        struct Tailnet: Decodable { let Name: String? }
        enum CodingKeys: String, CodingKey { case BackendState, MagicDNSSuffix, CurrentTailnet, me = "Self", peers = "Peer" }
    }
    private struct Peer: Decodable {
        let ID: String?
        let HostName: String?
        let DNSName: String?
        let TailscaleIPs: [String]?
        let OS: String?
        let Online: Bool?
        let sshHostKeys: [String]?
        let Tags: [String]?
        /// Mullvad exit nodes carry a location and aren't SSH targets.
        let Location: AnyCodable?
        struct AnyCodable: Decodable { init(from decoder: Decoder) throws {} }
    }

    static func decode(_ data: Data) -> GoviTailnet? {
        guard data.count <= 16_777_216, let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        func device(_ peer: Peer, isSelf: Bool) -> Device? {
            guard peer.Location == nil else { return nil }
            let dns = peer.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
            let addresses = (peer.TailscaleIPs ?? []).sorted { a, b in !a.contains(":") && b.contains(":") }
            let short = dns.flatMap { $0.split(separator: ".").first.map(String.init) }
            guard let name = short ?? peer.HostName.flatMap({ $0.isEmpty ? nil : $0 }), dns != nil || !addresses.isEmpty else { return nil }
            let keys = (peer.sshHostKeys ?? []).filter { key in
                let parts = key.split(separator: " ")
                return parts.count >= 2 && (parts[0].hasPrefix("ssh-") || parts[0].hasPrefix("ecdsa-")) && key.utf8.count <= 8192
                    && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
            return .init(id: peer.ID ?? dns ?? addresses[0], name: name, dnsName: dns, addresses: addresses, os: peer.OS,
                         online: isSelf || peer.Online == true, sshHostKeys: keys, tags: peer.Tags ?? [], isSelf: isSelf)
        }
        var devices = (status.peers ?? [:]).values.compactMap { device($0, isSelf: false) }
        devices.sort { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
        if let me = status.me.flatMap({ device($0, isSelf: true) }) { devices.insert(me, at: 0) }
        let suffix = status.MagicDNSSuffix.flatMap { $0.isEmpty ? nil : $0 }
        return .init(backendState: status.BackendState ?? "Unknown", tailnetName: status.CurrentTailnet?.Name ?? suffix,
                     magicDNSSuffix: suffix, devices: devices)
    }

    /// OpenSSH known_hosts lines for every device that publishes host keys.
    var knownHosts: String {
        var lines: [String] = []
        for device in devices where device.runsTailscaleSSH {
            let names = ([device.dnsName].compactMap { $0 } + device.addresses).joined(separator: ",")
            for key in device.sshHostKeys { lines.append(names + " " + key) }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Standalone and Homebrew installs, then the Mac app's bundled CLI.
    static let executableCandidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                                       "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
}

// MARK: - Commands

enum GoviRemoteCommand {
    /// Tailnet host keys Govi trusts in addition to the user's known_hosts.
    /// Kept out of paths with spaces, which ssh's option parser splits.
    static var tailnetKnownHostsPath: String? {
        let identity = Bundle.main.bundleIdentifier ?? "dev.govi.terminal"
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/" + identity + "/tailnet_known_hosts"
        return path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) ? nil : path
    }

    /// The remote half: start in a folder, then the user's login shell.
    static func remoteStartup(_ directory: String) -> String {
        let q = GoviShell.quote
        let cd: String
        if directory.hasPrefix("~/") { cd = "cd -- \"$HOME\"/" + q(String(directory.dropFirst(2))) }
        else { cd = "cd -- " + q(directory) }
        let script = cd + " 2>/dev/null || printf '%s\\n' " + q("Govi: " + directory + " is not available on this host.") + " >&2; exec \"${SHELL:-/bin/sh}\" -l"
        return "exec /bin/sh -c " + q(script)
    }

    /// The ssh invocation as separate arguments, or nil if the target is invalid.
    static func arguments(_ target: GoviRemoteTarget, ssh: String = "/usr/bin/ssh", knownHosts: String? = tailnetKnownHostsPath) -> [String]? {
        let target = target.normalized()
        guard target.validationError == nil else { return nil }
        var argv = [ssh]
        if let port = target.port { argv += ["-p", String(port)] }
        if let identity = target.identityFile {
            let path = identity.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + identity.dropFirst() : identity
            argv += ["-i", path]
        }
        if let jump = target.jumpHost { argv += ["-J", jump] }
        // Same compatibility as Ghostty's ssh-env shell integration.
        argv += ["-o", "SetEnv COLORTERM=truecolor", "-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        if target.transport == .tailscale, let knownHosts {
            argv += ["-o", "UserKnownHostsFile ~/.ssh/known_hosts " + knownHosts]
        }
        if let directory = target.directory {
            argv += ["-t", "--", target.destination, remoteStartup(directory)]
        } else {
            argv += ["--", target.destination]
        }
        return argv
    }

    /// What a person would type, for copying.
    static func display(_ target: GoviRemoteTarget) -> String? {
        guard var argv = arguments(target) else { return nil }
        argv[0] = "ssh"
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_~[]"))
        return argv.map { $0.unicodeScalars.allSatisfy(plain.contains) && !$0.isEmpty ? $0 : GoviShell.quote($0) }.joined(separator: " ")
    }

    /// The program a pane runs: a login shell for the user's PATH (ProxyCommand
    /// helpers often live in Homebrew), then a POSIX loop that offers to
    /// reconnect when the connection drops instead of closing the pane.
    static func pane(_ target: GoviRemoteTarget, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                     ssh: String = "/usr/bin/ssh") -> String? {
        guard let argv = arguments(target, ssh: ssh) else { return nil }
        let q = GoviShell.quote
        let name = target.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        let loop = """
        case "$TERM" in xterm-ghostty) TERM=xterm-256color; export TERM;; esac
        while :; do
          \(argv.map(q).joined(separator: " "))
          s=$?
          [ "$s" -eq 0 ] && exit 0
          printf '\\r\\n\\033[2m%s (exit %s). Press Return to reconnect, or Control-D to close.\\033[0m\\r\\n' \(q("Connection to " + name + " ended")) "$s"
          read -r _ || exit "$s"
        done
        """
        return q(shell) + " -lc " + q("exec /bin/sh -c " + q(loop))
    }
}
