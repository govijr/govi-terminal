#!/usr/bin/env python3
"""Compile production quota parsers; fixtures never read real credentials or call providers."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
source = (root/'macos/Sources/Features/Terminal/GoviAgents.swift').read_text()
agent = source[source.index('enum GoviAgent:'):source.index('/// Terminal tools')]
usage = source[source.index('struct GoviUsageWindow:'):source.index('struct GoviUsageRings:')]
tests = r'''
func parse(_ agent: GoviAgent, _ text: String) -> [GoviUsageWindow] {
    GoviUsageParser.parse(agent, try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any], now: Date(timeIntervalSince1970: 1800000000))
}
let claude = parse(.claude, #"{"five_hour":{"utilization":32.5,"resets_at":"2026-11-05T18:00:00Z"},"seven_day":{"utilization":0,"resets_at":null}}"#)
precondition(claude.count == 2 && claude[0].usedPercent == 32.5 && claude[0].remainingPercent == 67.5 && claude[0].reset != nil && claude[1].remainingPercent == 100 && claude[1].reset == nil)
let codex = parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":51,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1800007000}},"additional_rate_limits":[{"limit_name":"Extra","rate_limit":{"primary_window":{"used_percent":3}}}]}"#)
precondition(codex.count == 3 && codex[0].reset!.timeIntervalSince1970 == 1800003600 && codex[1].label == "Secondary · Weekly limit")
// The user's exact report: 9% used means 91% remaining; the second window is full.
let reported = parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":9},"secondary_window":{"used_percent":0}}}"#)
precondition(reported[0].remainingText == "91%" && reported[1].remainingText == "100%")
precondition(reported[0].remainingFraction == 0.91 && reported[1].remainingFraction == 1)
// Weekly/additional usage must never replace the primary window on hover.
let ordered = parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":4},"secondary_window":{"used_percent":9}},"additional_rate_limits":[{"limit_name":"Extra","rate_limit":{"primary_window":{"used_percent":100}}}]}"#)
let reading = GoviUsageStore.Reading(windows: ordered)
precondition(reading.headline?.remainingText == "96%" && reading.ringWindows.count == 2 && reading.ringWindows[1].remainingText == "91%")
precondition(GoviUsageWindow(label: "Exceeded", usedPercent: 105, reset: nil).remainingFraction == 0)
let cursor = parse(.cursor, #"{"billingCycleEnd":"2026-12-01T00:00:00.000Z","individualUsage":{"plan":{"autoPercentUsed":15,"apiPercentUsed":0},"onDemand":{"enabled":true,"used":50,"limit":200}}}"#)
precondition(cursor.count == 3 && cursor[2].usedPercent == 25 && cursor[0].reset != nil)
let grok = parse(.grok, #"{"config":{"creditUsagePercent":61,"currentPeriod":{"end":"2026-11-12T18:00:00+00:00"}}}"#)
precondition(grok.count == 1 && grok[0].remainingText == "39%" && grok[0].reset != nil)
let grokWeekly = parse(.grok, #"{"config":{"creditUsagePercent":52,"isUnifiedBillingUser":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-12T18:00:00+00:00"}}}"#)
precondition(grokWeekly[0].remainingText == "48%" && grokWeekly[0].label == "Weekly limit")
let open = parse(.opencode, #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-11-05T18:00:00Z"},"weekly":{"percent":55}}}"#)
precondition(open.count == 2 && open[0].usedPercent == 12 && open[1].reset == nil)
let now = GoviUsageParser.date("2026-11-07T01:00:00Z")!
let cli = GoviUsageParser.claudeCLI("""
Session cost: $0.00
Current week (Opus): 12% used · resets Nov 10 at 3pm (America/New_York)
Current week (all models): 39% used · resets Nov 10 at 3:59pm (America/New_York)
Current session: 0% used
Some unrelated estimate: 99% used
""", now: now)
precondition(cli.count == 3 && cli[0].remainingText == "100%" && cli[1].remainingText == "61%" && cli[2].remainingText == "88%")
precondition(cli[0].reset == nil && cli[1].reset == GoviUsageParser.date("2026-11-10T20:59:00Z") && cli[2].reset == GoviUsageParser.date("2026-11-10T20:00:00Z"))
precondition(GoviUsageParser.claudeCLI("Current week (all models): 39% used", now: now).isEmpty)
precondition(GoviUsageParser.claudeCLI("Current session: ??% used", now: now).isEmpty)
precondition(GoviUsageParser.claudeResetDate("Jan 2 at 3pm (UTC)", now: GoviUsageParser.date("2026-12-31T23:00:00Z")!) == GoviUsageParser.date("2027-01-02T15:00:00Z"))
precondition(GoviUsageParser.claudeResetDate("unknown", now: now) == nil)
// An account without its first successful reading must stay visible on errors.
for error in [GoviUsageFailure.rateLimited(300), .unauthorized, .empty, .keychain, .expired, .response(503)] {
    var failed = GoviUsageStore.Reading(); failed.failed(error, agent: .claude, now: now)
    precondition(failed.isVisible && !failed.busy && !failed.message.isEmpty)
}
var missing = GoviUsageStore.Reading(); missing.failed(GoviUsageFailure.signIn, agent: .claude, now: now)
precondition(!missing.isVisible)
var stale = GoviUsageStore.Reading(windows: reported, date: now, hasAccount: true)
stale.failed(GoviUsageFailure.rateLimited(300), agent: .codex, now: now)
precondition(stale.windows.count == 2 && stale.date == now && stale.retry == now.addingTimeInterval(300))
let store = GoviUsageStore()
store.readings[.claude] = .init(retry: Date().addingTimeInterval(300), hasAccount: true)
store.refresh(.claude, force: true)
precondition(store.readings[.claude]?.busy == false && store.visibleAgents == [.claude])
for agent in GoviAgent.allCases {
    precondition(parse(agent, "{}").isEmpty)
    precondition(parse(agent, #"{"usage":null,"rate_limit":{"primary_window":{"used_percent":null}},"five_hour":{"utilization":-2},"config":{},"individualUsage":{"overall":{"used":5,"limit":0}}}"#).isEmpty)
}
precondition(GoviUsageParser.number(Double.nan) == nil)
precondition(GoviUsageParser.number(Double.infinity) == nil)
precondition(GoviUsageParser.number(-1) == nil)
precondition(GoviUsageParser.date("invalid") == nil)
// Round-trip paths containing shell metacharacters as one literal argument.
for path in ["/tmp/tool with spaces", "/tmp/it's-a-tool", "/tmp/$(echo SHOULD_NOT_RUN)", "/tmp/tool;printf BAD"] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf '%s' " + GoviAgent.quote(path)]
    let pipe = Pipe(); p.standardOutput = pipe; try! p.run()
    let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit(); precondition(result == path && p.terminationStatus == 0)
}
// A fake CLI verifies the actual launch flags and positional /usage argument.
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let binary = scratch.appendingPathComponent("fake-claude")
let cliReading = try! GoviUsageSource.claudeCLI(binary: binary, directory: scratch)
precondition(cliReading?.count == 2 && cliReading?.first?.remainingText == "100%" && cliReading?[1].remainingText == "61%")
precondition(try! GoviUsageSource.claudeCLI(binary: scratch.appendingPathComponent("missing-claude"), directory: scratch) == nil)
print("Passed provider fixtures, remaining percentages, primary/secondary ordering, Claude CLI and reset parsing, unavailable/stale states, server backoff, and shell quoting.")
'''
out=root/'.build/usage-tests'; out.mkdir(parents=True, exist_ok=True)
fake = out/'fake-claude'
fake.write_text('''#!/usr/bin/python3
import sys
expected=['--print','--no-session-persistence','--strict-mcp-config','--setting-sources','','--settings','{"disableAllHooks":true}','--tools','','--','/usage']
assert sys.argv[1:]==expected
print('Current session: 0% used')
print('Current week (all models): 39% used · resets Nov 10 at 3:59pm (America/New_York)')
''')
fake.chmod(0o755)
(out/'main.swift').write_text('import Foundation\nimport SwiftUI\nimport Security\nimport SQLite3\nimport CryptoKit\nimport LocalAuthentication\nimport Darwin\n'+agent+'\n'+usage+'\n@main struct UsageChecks { @MainActor static func main() {\n'+tests+'\n} }\n')
subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(out/'modules'),str(out/'main.swift'),str(root/'macos/Sources/Features/Terminal/GoviWorkspaceModels.swift'),str(root/'macos/Sources/Features/Terminal/GoviProcess.swift'),str(root/'macos/Sources/Features/Terminal/GoviRemoteModels.swift'),'-o',str(out/'check')],check=True)
subprocess.run([str(out/'check'),str(out)],check=True)
