#!/bin/sh
# Smoke test: run Dockerfile.railway's CMD locally and check it refuses to start
# without an API key and the public endpoint rejects requests without the key.
# Needs node and the server's Python deps on PATH. Usage: scripts/test_railway_auth.sh
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*npm install -g supergateway@\([0-9.]*\).*/\1/p' Dockerfile.railway)
CMD=$(python3 -c 'import json,re; s=open("Dockerfile.railway").read(); print(json.loads(re.search(r"^CMD (\[.*?\])\s*$", s, re.S|re.M).group(1).replace("\\\n", " "))[2])')

SHIM=$(mktemp -d)
printf '#!/bin/sh\nexec npx -y supergateway@%s "$@"\n' "$VERSION" > "$SHIM/supergateway"
chmod +x "$SHIM/supergateway"

PORT=18080
KEY=test-key-123

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got $2, want $3)"; fail=1; fi; }

# Missing key: CMD must exit non-zero before ever launching supergateway (stub records a launch).
STUB=$(mktemp -d)
printf '#!/bin/sh\ntouch "%s/launched"\n' "$STUB" > "$STUB/supergateway"
chmod +x "$STUB/supergateway"
for k in unset empty blank; do
  case $k in
    unset) rc=0; err=$(env -u SUPERGATEWAY_API_KEY PATH="$STUB:$PATH" sh -c "$CMD" 2>&1) || rc=$? ;;
    empty) rc=0; err=$(SUPERGATEWAY_API_KEY= PATH="$STUB:$PATH" sh -c "$CMD" 2>&1) || rc=$? ;;
    blank) rc=0; err=$(SUPERGATEWAY_API_KEY=' 	 ' PATH="$STUB:$PATH" sh -c "$CMD" 2>&1) || rc=$? ;;
  esac
  check "$k key exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" yes
  check "$k key explains on stderr" "$(echo "$err" | grep -c 'FATAL: SUPERGATEWAY_API_KEY' || true)" 1
  check "$k key never launches gateway" "$([ -e "$STUB/launched" ] && echo yes || echo no)" no
done
rm -rf "$STUB"
PATH="$SHIM:$PATH" PORT=$PORT SUPERGATEWAY_API_KEY=$KEY sh -c "$CMD" > "$SHIM/log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; pkill -f "supergateway.*--port $PORT" 2>/dev/null; rm -rf "$SHIM"' EXIT

for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' "$@" -d "$INIT"; }

check "health without key" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")" 200
check "health leaks no Authorization header" "$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/health" | grep -ci '^authorization' || true)" 0
check "initialize without key" "$(post)" 401
check "initialize with wrong key" "$(post -H 'authorization: Bearer nope')" 401
check "initialize with key" "$(post -H "authorization: Bearer $KEY")" 200
check "initialize with X-API-Key" "$(post -H "x-api-key: $KEY")" 200
body=$(curl -s -X POST "http://127.0.0.1:$PORT/mcp" -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' -H "authorization: Bearer $KEY" -d "$INIT")
check "initialize with key returns serverInfo" "$(echo "$body" | grep -c '"serverInfo"' || true)" 1
check "gateway log never prints the key" "$(grep -c "$KEY" "$SHIM/log" || true)" 0
[ $fail -eq 0 ] || { echo '--- gateway log ---'; cat "$SHIM/log"; }
exit $fail
