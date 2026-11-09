#!/bin/zsh
# Checks the `govi` command and its MCP server against a fake control socket:
# request shape, argument parsing, output and error handling. It doesn't need
# Govi running; see VALIDATION.md for the live check against the app.
set -euo pipefail
cd "${0:A:h}/.."

work=$(mktemp -d /tmp/govi-cli.XXXXXX)
trap 'kill ${server:-} 2>/dev/null || true; rm -rf "$work"' EXIT
swiftc -O -o "$work/govi" govi/cli/main.swift

# The fake server records each request and answers from a small script.
cat > "$work/server.py" <<'EOF'
import json, os, socket, sys
path, log = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
panes = [{"id": "3FA2C0DE-0000-4000-8000-000000000001", "kind": "terminal", "title": "zsh", "directory": "/tmp",
          "focused": True, "self": True, "workspace": "demo", "window": 1},
         {"id": "77B0C0DE-0000-4000-8000-000000000002", "kind": "browser", "title": "Example", "url": "http://localhost:3000/",
          "focused": False, "self": False, "workspace": "demo", "window": 1}]
while True:
    c, _ = s.accept(); data = b""
    while not data.endswith(b"\n"):
        chunk = c.recv(65536)
        if not chunk: break
        data += chunk
    req = json.loads(data); open(log, "a").write(json.dumps(req, sort_keys=True) + "\n")
    m, p = req["method"], req.get("params", {})
    if m == "panes.list": res = {"ok": True, "result": panes}
    elif m == "terminal.read": res = {"ok": True, "result": {"text": "line1\nline2"}}
    elif m == "browser.snapshot": res = {"ok": True, "result": {"title": "Example", "url": "http://localhost:3000/", "text": "Hello",
        "truncated": False, "elements": [{"ref": "e1", "tag": "button", "name": "Sign in"}]}}
    elif m == "browser.eval": res = {"ok": True, "result": {"result": {"n": 2}}}
    elif m == "browser.screenshot": res = {"ok": True, "result": {"base64": "iVBORw0KGgo=", "format": "png"}}
    elif m == "pane.focus": res = {"ok": False, "error": "No pane has the ID zzzz. Run `govi panes`."}
    else: res = {"ok": True, "result": {"pane": "x"}}
    c.sendall((json.dumps(res) + "\n").encode()); c.close()
EOF
python3 "$work/server.py" "$work/s" "$work/log" &
server=$!
for _ in {1..50}; do [[ -S $work/s ]] && break; sleep 0.1; done

export GOVI_CONTROL_SOCKET=$work/s GOVI_SESSION_ID=3FA2C0DE-0000-4000-8000-000000000001
govi=$work/govi
failures=0
check() { # name, condition
  if eval "$2"; then print "ok   $1"; else print "FAIL $1"; failures=$((failures + 1)); fi
}
last() { tail -1 "$work/log"; }

out=$($govi panes)
check "panes lists both kinds" '[[ $out == *"3fa2c0de  terminal"* && $out == *"77b0c0de  browser"* && $out == *"localhost:3000"* ]]'
check "panes marks this pane" '[[ $out == *"*>3fa2c0de"* ]]'
check "caller is sent" '[[ $(last) == *"\"caller\": \"3FA2C0DE"* ]]'

$govi send --enter echo hi >/dev/null
check "send joins words and passes enter" '[[ $(last) == *"\"enter\": true"* && $(last) == *"\"text\": \"echo hi\""* ]]'
print -n "from stdin" | $govi send - >/dev/null
check "send - reads stdin" '[[ $(last) == *"\"text\": \"from stdin\""* ]]'

out=$($govi read --scrollback -n 5)
check "read prints text" '[[ $out == $'"'"'line1\nline2'"'"' ]]'
check "read passes scope and lines" '[[ $(last) == *"\"lines\": 5"* && $(last) == *"\"scope\": \"scrollback\""* ]]'

$govi split --down --cwd /tmp -- npm run dev >/dev/null
check "split passes command, cwd, direction" '[[ $(last) == *"\"command\": \"npm run dev\""* && $(last) == *"\"direction\": \"down\""* && $(last) == *"\"cwd\": \"/tmp\""* ]]'

$govi browser open localhost:3000 >/dev/null
check "browser open" '[[ $(last) == *"\"method\": \"browser.open\""* && $(last) == *"\"url\": \"localhost:3000\""* ]]'
$govi browser click e1 >/dev/null
check "click by ref" '[[ $(last) == *"\"ref\": \"e1\""* ]]'
$govi browser click "button.primary" >/dev/null
check "click by selector" '[[ $(last) == *"\"selector\": \"button.primary\""* ]]'
$govi browser type e2 hello world --submit >/dev/null
check "type with submit" '[[ $(last) == *"\"text\": \"hello world\""* && $(last) == *"\"submit\": true"* ]]'
$govi browser go example.com --pane 77b0 --timeout 5 >/dev/null
check "navigate with pane and timeout" '[[ $(last) == *"\"pane\": \"77b0\""* && $(last) == *"\"timeout\": 5"* ]]'

out=$($govi browser snapshot)
check "snapshot shows refs" '[[ $out == *"[e1] button \"Sign in\""* && $out == *"Hello"* ]]'
out=$($govi browser eval '1 + 1')
check "eval prints JSON" '[[ $out == *"\"n\" : 2"* || $out == *"\"n\": 2"* ]]'
(cd "$work" && $govi browser screenshot --out shot.png >/dev/null)
check "screenshot writes PNG bytes" '[[ $(head -c 4 "$work/shot.png" | xxd -p) == 89504e47 ]]'

set +e
err=$($govi focus zzzz 2>&1); code=$?
check "Govi errors exit 1 with message" '[[ $code == 1 && $err == *"No pane has the ID zzzz"* ]]'
$govi frobnicate 2>/dev/null; code=$?
check "unknown command exits 2" '[[ $code == 2 ]]'
GOVI_CONTROL_SOCKET=$work/missing $govi panes 2>/dev/null; code=$?
check "no app exits 3" '[[ $code == 3 ]]'
set -e

mcp=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"govi_browser_history","arguments":{"action":"back"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"govi_browser_screenshot","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"govi_focus","arguments":{"pane":"zzzz"}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}' | $govi mcp)
check "mcp answers each request, not notifications" '[[ $(print -r -- $mcp | wc -l | tr -d " ") == 6 ]]'
check "mcp echoes a supported protocol" '[[ $mcp == *"\"protocolVersion\":\"2025-03-26\""* ]]'
check "mcp lists 15 tools" '[[ $(print -r -- $mcp | sed -n 2p | grep -o "\"inputSchema\"" | wc -l | tr -d " ") == 15 ]]'
check "mcp history maps to browser.back" '[[ $(grep -c "browser.back" "$work/log") == 1 ]]'
check "mcp screenshot is image content" '[[ $(print -r -- $mcp | sed -n 4p) == *"\"type\":\"image\""* ]]'
check "mcp Govi errors are tool errors" '[[ $(print -r -- $mcp | sed -n 5p) == *"\"isError\":true"* ]]'
check "mcp unknown tool is a JSON-RPC error" '[[ $(print -r -- $mcp | sed -n 6p) == *"\"error\""* ]]'

if (( failures )); then print "$failures CLI check(s) failed"; exit 1; fi
print "All CLI checks passed"
