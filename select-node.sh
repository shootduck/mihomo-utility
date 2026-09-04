#!/usr/bin/env bash
set -euo pipefail

MIHOMO_HOME="${MIHOMO_HOME:-$HOME/mihomo}"
CONFIG="${MIHOMO_CONFIG:-$MIHOMO_HOME/config.yaml}"
API_BASE="${MIHOMO_API:-http://127.0.0.1:9090}"
GROUP="${MIHOMO_GROUP:-MANUAL}"

usage() {
  cat <<'EOF'
Usage:
  select-node.sh
  select-node.sh "EXACT NODE NAME"
  select-node.sh --list
  select-node.sh --group GROUP ["EXACT NODE NAME"]

With no node name, the script shows a numbered interactive menu.

Environment overrides:
  MIHOMO_HOME
  MIHOMO_CONFIG
  MIHOMO_API
  MIHOMO_GROUP

Examples:
  ./select-node.sh
  ./select-node.sh --list
  ./select-node.sh "Japan 01"
EOF
}

NODE=""
LIST_ONLY=false

while (($#)); do
  case "$1" in
    --group)
      [[ $# -ge 2 ]] || { echo "Missing value after --group" >&2; exit 2; }
      GROUP="$2"; shift 2 ;;
    --list)
      LIST_ONLY=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      NODE="${1:-}"
      [[ $# -le 1 ]] || { echo "Too many arguments after --" >&2; exit 2; }
      shift $# ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
    *)
      [[ -z "$NODE" ]] || { echo "Provide the node name as one quoted argument." >&2; exit 2; }
      NODE="$1"; shift ;;
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
GROUP_JSON="$(curl -fsS --connect-timeout 3 -H "$AUTH_HEADER" \
  "$API_BASE/proxies/$ENCODED_GROUP")" || {
  echo "Cannot reach Mihomo API at $API_BASE." >&2
  echo "Make sure Mihomo is running with: $MIHOMO_HOME/mihomo -d $MIHOMO_HOME" >&2
  exit 1
}

CURRENT="$(jq -r '.now // "unknown"' <<<"$GROUP_JSON")"
mapfile -t NODES < <(jq -r '.all[]?' <<<"$GROUP_JSON")

if ((${#NODES[@]} == 0)); then
  echo "The group '$GROUP' contains no nodes." >&2
  exit 1
fi

print_nodes() {
  echo "Group:        $GROUP"
  echo "Current node: $CURRENT"
  echo
  for index in "${!NODES[@]}"; do
    marker=" "
    [[ "${NODES[$index]}" == "$CURRENT" ]] && marker="*"
    printf "%s %3d) %s\n" "$marker" "$((index + 1))" "${NODES[$index]}"
  done
}

if [[ "$LIST_ONLY" == true ]]; then
  print_nodes
  exit 0
fi

if [[ -z "$NODE" ]]; then
  print_nodes
  echo
  read -r -p "Select node number: " SELECTION
  [[ "$SELECTION" =~ ^[0-9]+$ ]] || { echo "Selection must be a number." >&2; exit 2; }
  ((SELECTION >= 1 && SELECTION <= ${#NODES[@]})) || {
    echo "Selection is outside the valid range." >&2
    exit 2
  }
  NODE="${NODES[$((SELECTION - 1))]}"
fi

if ! jq -e --arg node "$NODE" '.all | index($node) != null' \
  <<<"$GROUP_JSON" >/dev/null; then
  echo "Node not found in group '$GROUP': $NODE" >&2
  echo "Run '$0 --list' to see exact node names." >&2
  exit 1
fi

PAYLOAD="$(jq -nc --arg name "$NODE" '{name: $name}')"
curl -fsS -o /dev/null \
  -X PUT \
  -H "$AUTH_HEADER" \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD" \
  "$API_BASE/proxies/$ENCODED_GROUP"

CONFIRMED="$(curl -fsS -H "$AUTH_HEADER" \
  "$API_BASE/proxies/$ENCODED_GROUP" | jq -r '.now')"

echo "Selected node: $CONFIRMED"
echo "New proxy connections will use this node."
