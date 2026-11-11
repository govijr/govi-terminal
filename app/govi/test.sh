#!/bin/zsh
# Runs Govi's unit tests: the same set CI runs on every pull request.
# None of them need a built app, a running Govi, network access or accounts.
#
#   ./govi/test.sh            run everything
#   ./govi/test.sh layout cli run only the named tests
set -uo pipefail
cd "${0:A:h}/.."

typeset -A tests=(
  workflows    'zsh govi/test-workflows.sh'
  layout       'zsh govi/test-layout.sh'
  remote       'zsh govi/test-remote.sh'
  integrations 'zsh govi/test-integrations.sh'
  cli          'zsh govi/test-cli.sh'
  hooks        'python3 govi/test-hooks.py'
  agent-usage  'python3 govi/test-agent-usage.py'
)
order=(workflows layout remote integrations cli hooks agent-usage)
selected=(${@:-$order})

failed=()
for name in $selected; do
  if [[ -z ${tests[$name]:-} ]]; then
    print -u2 "Unknown test '$name'. Available: $order"
    exit 2
  fi
  print "▶ $name"
  if eval "${tests[$name]}"; then
    print "✓ $name"
  else
    print -u2 "✗ $name failed"
    failed+=($name)
  fi
done

if (( ${#failed} )); then
  print -u2 "\n${#failed} of ${#selected} failed: $failed"
  exit 1
fi
print "\nAll ${#selected} tests passed."
