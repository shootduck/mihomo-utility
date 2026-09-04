#!/usr/bin/env bash
set -euo pipefail

MIHOMO_HOME="${MIHOMO_HOME:-$HOME/mihomo}"
CONFIG="${MIHOMO_CONFIG:-$MIHOMO_HOME/config.yaml}"
API_BASE="${MIHOMO_API:-http://127.0.0.1:9090}"
GROUP="${MIHOMO_GROUP:-MANUAL}"
TEST_URL="${MIHOMO_TEST_URL:-https://www.gstatic.com/generate_204}"
TIMEOUT_MS="${MIHOMO_TEST_TIMEOUT:-5000}"

usage() {
  cat <<'EOF'
Usage:
  test-nodes.sh
  test-nodes.sh [--url URL] [--timeout MILLISECONDS] [--group GROUP]

Environment overrides:
  MIHOMO_HOME
  MIHOMO_CONFIG
  MIHOMO_API
  MIHOMO_GROUP
  MIHOMO_TEST_URL
  MIHOMO_TEST_TIMEOUT

Examples:
  ./test-nodes.sh
  ./test-nodes.sh --timeout 8000
  ./test-nodes.sh --url https://cp.cloudflare.com
EOF
}

while (($#)); do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || { echo "Missing value after --url" >&2; exit 2; }
      TEST_URL="$2"; shift 2 ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "Missing value after --timeout" >&2; exit 2; }
      TIMEOUT_MS="$2"; shift 2 ;;
    --group)
      [[ $# -ge 2 ]] || { echo "Missing value after --group" >&2; exit 2; }
      GROUP="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

for command in curl jq python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

[[ -r "$CONFIG" ]] || {
  echo "Cannot read Mihomo configuration: $CONFIG" >&2
  exit 1
}

SECRET="$(python3 - "$CONFIG" <<'PYSECRET'
import ast, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        m = re.match(r'^\s*secret\s*:\s*(.*?)\s*$', line)
        if not m:
            continue
        value = m.group(1)
        if not value:
            print('')
        elif value[0] in {'\'', '"'}:
            print(ast.literal_eval(value))
        else:
            print(value.split('#', 1)[0].strip())
        break
    else:
        raise SystemExit('No top-level secret field found in config.yaml')
PYSECRET
)"

ENCODED_GROUP="$(python3 - "$GROUP" <<'PYGROUP'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PYGROUP
)"

AUTH_HEADER="Authorization: Bearer $SECRET"
CURRENT="$(curl -fsS --connect-timeout 3 -H "$AUTH_HEADER" \
  "$API_BASE/proxies/$ENCODED_GROUP" | jq -r '.now // "unknown"')" || {
  echo "Cannot reach Mihomo API at $API_BASE." >&2
  echo "Make sure Mihomo is running with: $MIHOMO_HOME/mihomo -d $MIHOMO_HOME" >&2
  exit 1
}

echo "Group:        $GROUP"
echo "Current node: $CURRENT"
echo "Test URL:     $TEST_URL"
echo "Timeout:      ${TIMEOUT_MS} ms"
echo

MAX_TIME="$(( (TIMEOUT_MS + 999) / 1000 + 30 ))"
RESULT="$(curl -fsS --max-time "$MAX_TIME" -G \
  -H "$AUTH_HEADER" \
  --data-urlencode "url=$TEST_URL" \
  --data-urlencode "timeout=$TIMEOUT_MS" \
  --data-urlencode "expected=204" \
  "$API_BASE/group/$ENCODED_GROUP/delay")" || {
  echo "Latency test failed." >&2
  echo "Inspect Mihomo's terminal output or mihomo.log for details." >&2
  exit 1
}

ROWS="$(jq -r '
  to_entries
  | map(select(.value | type == "number"))
  | sort_by(.value)
  | .[]
  | [.value, .key]
  | @tsv
' <<<"$RESULT")"

if [[ -z "$ROWS" ]]; then
  echo "No node returned a successful latency result."
  exit 1
fi

printf "%-5s %-12s %s\n" "RANK" "DELAY(ms)" "NODE"
printf "%-5s %-12s %s\n" "----" "---------" "----"
awk -F '\t' '{ printf "%-5d %-12s %s\n", NR, $1, $2 }' <<<"$ROWS"

echo
echo "This measures latency, not sustained download bandwidth."
