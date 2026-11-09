import Foundation

/// Remote host regressions: ssh config discovery, tailnet status parsing,
/// option-injection rejection, and the exact commands panes run (executed
/// against a fake ssh, so no network connection is made).
@main struct RemoteChecks {
    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() throws {
        sshConfig()
        tailnet()
        validation()
        try commands()
        print("Remote checks passed.")
    }

    static func sshConfig() {
        let text = """
            # comment
            Host *
              ServerAliveInterval 30
            Host web web-alias "quoted host"
              HostName 203.0.113.10
              User deploy
              Port 2222
              Port 9999
            Host=db
              hostname=db.internal  # trailing comment
            Host !bad prod-*
              User nobody
            Match host foo
              User matched
            Host -oProxyCommand=evil
            Include conf.d/*
            Include loop
            """
        let included = "Host extra\n  User x\nHost web\n  User ignored\n"
        var loops = 0
        let entries = GoviSSHConfig.parse(text) { pattern in
            if pattern == "conf.d/*" { return [included] }
            if pattern == "loop" {
                loops += 1
                return ["Include loop\nHost deep\(loops)"]
            }
            return []
        }
        let aliases = entries.map(\.alias)
        check(aliases.prefix(5) == ["web", "web-alias", "quoted host", "db", "extra"], "aliases \(aliases)")
        check(!aliases.contains(where: { $0.contains("*") || $0.hasPrefix("!") || $0.hasPrefix("-") }), "patterns skipped")
        check(entries[0] == .init(alias: "web", hostName: "203.0.113.10", user: "deploy", port: 2222), "first value wins \(entries[0])")
        check(entries[3].hostName == "db.internal", "Keyword=value and trailing comments")
        check(entries.first { $0.alias == "extra" }?.user == "x", "Include parsed")
        check(loops <= 5, "Include recursion is bounded (\(loops))")
        check(!entries.contains { $0.user == "matched" || $0.user == "nobody" }, "Match/pattern blocks don't leak options")
        check(GoviSSHConfig.split("  ") == (nil, []) || GoviSSHConfig.split("  ").0 == nil, "blank line")
    }

    static func tailnet() {
        let json = """
            {"Version":"1.76.0","BackendState":"Running","MagicDNSSuffix":"tail1234.ts.net",
             "CurrentTailnet":{"Name":"me@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
             "Self":{"ID":"n1","HostName":"My MacBook","DNSName":"macbook.tail1234.ts.net.","OS":"macOS","TailscaleIPs":["fd7a:115c::1","100.64.0.1"],"Online":true},
             "Peer":{
              "k1":{"ID":"n2","HostName":"build-box","DNSName":"build.tail1234.ts.net.","OS":"linux","TailscaleIPs":["100.64.0.2","fd7a:115c::2"],"Online":true,
                    "sshHostKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample","ecdsa-sha2-nistp256 AAAAE2Vj","bogus","ssh-rsa AAAA\\nInjected"],"Tags":["tag:server"]},
              "k2":{"ID":"n3","HostName":"old-pi","DNSName":"","OS":"linux","TailscaleIPs":["100.64.0.3"],"Online":false},
              "k3":{"ID":"n4","HostName":"se-sto-wg-001.mullvad.ts.net","DNSName":"se-sto.mullvad.ts.net.","OS":"linux","TailscaleIPs":["100.64.0.4"],"Online":true,"Location":{"Country":"Sweden"}},
              "k4":{"ID":"n5","HostName":"","DNSName":"","TailscaleIPs":[]}
             }}
            """
        guard let net = GoviTailnet.decode(Data(json.utf8)) else { return check(false, "decode") }
        check(net.isRunning && net.tailnetName == "me@example.com", "state and tailnet name")
        check(net.devices.map(\.name) == ["macbook", "build", "old-pi"], "devices \(net.devices.map(\.name))")
        let me = net.devices[0]
        let build = net.devices[1]
        let pi = net.devices[2]
        check(me.isSelf && me.addresses.first == "100.64.0.1", "self first, IPv4 first")
        check(
            build.dnsName == "build.tail1234.ts.net" && build.runsTailscaleSSH && build.sshHostKeys.count == 2,
            "dns trimmed, keys filtered \(build.sshHostKeys)")
        check(pi.sshHost == "100.64.0.3" && !pi.online && !pi.runsTailscaleSSH, "IP fallback and offline")
        check(build.target == GoviRemoteTarget(name: "build", host: "build.tail1234.ts.net", transport: .tailscale), "target")
        check(
            net.knownHosts
                == "build.tail1234.ts.net,100.64.0.2,fd7a:115c::2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample\nbuild.tail1234.ts.net,100.64.0.2,fd7a:115c::2 ecdsa-sha2-nistp256 AAAAE2Vj\n",
            "known hosts \(net.knownHosts)")
        let stopped = GoviTailnet.decode(Data(#"{"BackendState":"NeedsLogin","Self":null,"Peer":null}"#.utf8))
        check(stopped?.isRunning == false && stopped?.devices.isEmpty == true, "logged-out status")
        check(GoviTailnet.decode(Data("not json".utf8)) == nil, "garbage rejected")
    }

    static func validation() {
        func target(_ host: String, user: String? = nil, port: Int? = nil, jump: String? = nil, identity: String? = nil) -> GoviRemoteTarget
        {
            .init(name: "x", host: host, user: user, port: port, identityFile: identity, jumpHost: jump)
        }
        check(target("example.com").validationError == nil, "plain host")
        check(target("[fe80::1%en0]").validationError == nil && target("10.0.0.5", user: "me", port: 22).validationError == nil, "ip forms")
        for bad in [
            target("-oProxyCommand=touch /tmp/pwn"), target("a b"), target("host;rm"), target(""), target("h", user: "-l root"),
            target("h", user: "a b"), target("h", port: 0), target("h", port: 70000), target("h", jump: "-oProxyCommand=x"),
            target("h", identity: "relative/key"), target("h", identity: "-i"),
        ] {
            check(bad.validationError != nil, "rejected \(bad)")
            check(GoviRemoteCommand.arguments(bad) == nil, "no command for \(bad)")
        }
        var tailscale = target("box.ts.net", port: 2200, jump: "bastion", identity: "~/.ssh/id")
        tailscale.transport = .tailscale
        let normal = tailscale.normalized()
        check(normal.port == nil && normal.jumpHost == nil && normal.identityFile == nil, "tailscale ignores ssh-only fields")
        check(
            GoviRemoteTarget(name: " n ", host: " h ", user: "", directory: "~").normalized() == GoviRemoteTarget(name: "n", host: "h"),
            "normalization")
    }

    static func commands() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("govi-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let plain = GoviRemoteTarget(
            name: "Web", host: "web", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519", jumpHost: "me@bastion:22")
        let argv = GoviRemoteCommand.arguments(plain, knownHosts: nil)!
        check(
            argv == [
                "/usr/bin/ssh", "-p", "2222", "-i", home + "/.ssh/id_ed25519", "-J", "me@bastion:22",
                "-o", "SetEnv COLORTERM=truecolor", "-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION", "--", "deploy@web",
            ], "argv \(argv)")
        let tailnet = GoviRemoteTarget(name: "build", host: "build.ts.net", transport: .tailscale)
        let tsArgv = GoviRemoteCommand.arguments(tailnet, knownHosts: "/k/h")!
        check(
            tsArgv.contains("UserKnownHostsFile ~/.ssh/known_hosts /k/h") && tsArgv.suffix(2) == ["--", "build.ts.net"],
            "tailscale argv \(tsArgv)")
        check(
            !GoviRemoteCommand.arguments(plain, knownHosts: "/k/h")!.contains { $0.contains("UserKnownHostsFile") },
            "known hosts only for tailnet")
        check(GoviRemoteCommand.display(plain)?.hasPrefix("ssh -p 2222 -i ") == true, "display")

        // The pane program, run for real with a fake ssh that records its arguments.
        let log = scratch.appendingPathComponent("args").path
        let count = scratch.appendingPathComponent("count").path
        let fake = scratch.appendingPathComponent("fake ssh").path
        try """
        #!/bin/sh
        n=$(cat \(GoviShell.quote(count)) 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > \(GoviShell.quote(count))
        : > \(GoviShell.quote(log)); for a in "$@"; do printf '%s\\n' "$a" >> \(GoviShell.quote(log)); done
        echo "TERM=$TERM" >> \(GoviShell.quote(log))
        [ "$n" -ge "${GOVI_FAKE_SUCCEED_AT:-1}" ] && exit 0 || exit 255
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)

        let folder = "~/it's a \"folder\"; $(touch /tmp/govi-pwned)"
        let target = GoviRemoteTarget(name: "Web 'prod'", host: "web", directory: folder)
        let pane = GoviRemoteCommand.pane(target, shell: "/bin/sh", ssh: fake)!
        func run(_ command: String, stdin: String, env: [String: String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            try! process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }
        check(run(pane, stdin: "", env: ["TERM": "xterm-ghostty"]) == 0, "clean exit closes the pane")
        let recorded = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        let remote = GoviRemoteCommand.remoteStartup(folder)
        check(
            recorded.contains("-t") && recorded.contains("--") && recorded.contains("web") && recorded.contains(remote),
            "pane passes arguments intact \(recorded)")
        check(recorded.contains("TERM=xterm-256color"), "xterm-ghostty is downgraded for remote hosts")
        check(!FileManager.default.fileExists(atPath: "/tmp/govi-pwned"), "no local expansion")

        // A dropped connection offers to reconnect; Return reconnects.
        try "0".write(toFile: count, atomically: true, encoding: .utf8)
        check(run(pane, stdin: "\n", env: ["GOVI_FAKE_SUCCEED_AT": "2"]) == 0, "reconnect after Return")
        check(try String(contentsOfFile: count, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "2", "two attempts")
        // Control-D (end of input) closes with ssh's status.
        try "0".write(toFile: count, atomically: true, encoding: .utf8)
        check(run(pane, stdin: "", env: ["GOVI_FAKE_SUCCEED_AT": "9"]) == 255, "Control-D closes with ssh status")

        // The remote half, run locally: it must land in the folder (relative to
        // HOME) without expanding anything inside the name.
        let fakeHome = scratch.appendingPathComponent("home").path
        let inner = fakeHome + "/it's a \"folder\"; $(touch /tmp/govi-pwned)"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        let reporter = scratch.appendingPathComponent("report-pwd").path
        try "#!/bin/sh\npwd > \(GoviShell.quote(scratch.appendingPathComponent("pwd").path))\n".write(
            toFile: reporter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reporter)
        check(run(remote, stdin: "", env: ["HOME": fakeHome, "SHELL": reporter]) == 0, "remote startup runs")
        let landed = try String(contentsOfFile: scratch.appendingPathComponent("pwd").path, encoding: .utf8).trimmingCharacters(
            in: .newlines)
        check(
            landed == (inner as NSString).resolvingSymlinksInPath || landed.hasSuffix("/home/it's a \"folder\"; $(touch /tmp/govi-pwned)"),
            "landed in \(landed)")
        check(!FileManager.default.fileExists(atPath: "/tmp/govi-pwned"), "no remote expansion")
        check(
            run(GoviRemoteCommand.remoteStartup("/definitely/missing"), stdin: "", env: ["SHELL": reporter]) == 0,
            "missing folder still opens a shell")
    }
}
