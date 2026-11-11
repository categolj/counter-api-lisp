#!/usr/bin/env bash
# What the unit tests cannot check: target/counter-api.wasm on a sluice wasi wicket (local mode), over a
# store of the wicket's. Counting, listing over pages of keys, an import round trip, the log
# reaching the wicket; the contract's details are counter-test.lisp's.
#
#   test/e2e.sh                   the wicket's default store: a sqlite file in a temporary directory
#   STORE=store.yaml test/e2e.sh  the store `counter` of that file's `keyvalue:` section, in a
#                                 namespace of its own, purged at the end
#
# SLUICE_WICKET: the wicket (default sluice-wicket-runtime-wasi on the PATH); PORT: its port and,
# the one after it, its console's.
set -euo pipefail
cd "$(dirname "$0")/.."
wicket=${SLUICE_WICKET:-sluice-wicket-runtime-wasi}
port=${PORT:-18095}
namespace=e2e-$(date +%s)
dir=$(mktemp -d)
pid=
stop() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
  fi
}
trap 'stop; rm -rf "$dir"' EXIT

# serve CONFIG [ARGS...]: starts the wicket and waits for its listener
serve() {
  "$wicket" --listen "127.0.0.1:$port" --config "$1" --watch-interval 0 "${@:2}" \
    >> "$dir/wicket.log" 2>&1 &
  pid=$!
  curl -s -o /dev/null --retry 30 --retry-connrefused --retry-delay 1 \
    -H 'host: counter.test' "http://127.0.0.1:$port/actuator/health"
}

{
  if [ -n "${STORE:-}" ]; then cat "$STORE"; fi
  cat <<EOF
routes:
  - host: counter.test
    component: $PWD/target/counter-api.wasm
    sandbox:
      wasi: [keyvalue]
EOF
  if [ -n "${STORE:-}" ]; then echo "      keyvalue: {\"\": counter/$namespace}"; fi
} > "$dir/wicket.yaml"
serve "$dir/wicket.yaml"

# call METHOD PATH [BODY]: "<status> <body>"
call() {
  local args=(-s -X "$1" -H 'host: counter.test' -w ' %{http_code}' "http://127.0.0.1:$port$2")
  if [ $# -gt 2 ]; then args+=(-H 'content-type: application/json' --data-binary "$3"); fi
  local out
  out=$(curl "${args[@]}")
  echo "${out##* } ${out% *}"
}

failures=0
# expect DESCRIPTION GOT WANT
expect() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n     got:  %s\n     want: %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

expect 'read-only on a missing entry answers 0' \
  "$(call POST '/counter?readOnly=true' '{"entryId": 100}')" '200 {"counter":0}'
expect 'an increment' "$(call POST /counter '{"entryId": 100}')" '200 {"counter":1}'
expect 'another increment' "$(call POST /counter '{"entryId": 100}')" '200 {"counter":2}'
expect 'another entry' "$(call POST /counter '{"entryId": 101}')" '200 {"counter":1}'
expect 'the counters by count' "$(call GET /counter)" \
  '200 [{"entryId":100,"counter":2},{"entryId":101,"counter":1}]'

exported=$(call GET /counter)
expect 'zeros imported' \
  "$(call POST /import '[{"entryId":100,"counter":0},{"entryId":101,"counter":0}]')" '200 {"imported":2}'
expect 'the export imported back' "$(call POST /import "${exported#200 }")" '200 {"imported":2}'
expect 'the export listed again' "$(call GET /counter)" "$exported"
expect 'an increment over an import' "$(call POST /counter '{"entryId": 100}')" '200 {"counter":3}'

items=$(for i in $(seq 0 249); do printf '{"entryId":%d,"counter":%d},' $((1000 + i)) $((i + 1)); done)
expect '250 more imported' "$(call POST /import "[${items%,}]")" '200 {"imported":250}'
listing=$(call GET /counter)
expect '252 listed, 3 pages of keys' "$(printf '%s' "$listing" | grep -o '"entryId"' | wc -l | tr -d ' ')" 252
expect 'the largest first' "${listing%%,\{\"entryId\":1248*}" '200 [{"entryId":1249,"counter":250}'
expect 'the increments logged, to the millisecond' \
  "$(grep -cE '"@timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z".*"event.action":"counter-incremented"' "$dir/wicket.log" || true)" 4

if [ -n "${STORE:-}" ]; then
  stop
  { cat "$STORE"; echo 'routes: []'; } > "$dir/purge.yaml"
  console=127.0.0.1:$((port + 1))
  serve "$dir/purge.yaml" --console "$console" --console-token e2e
  expect 'the namespace purged' \
    "$(curl -s -X DELETE -H 'authorization: Bearer e2e' "http://$console/api/keyvalue/counter/$namespace")" \
    "{\"store\":\"counter\",\"namespace\":\"$namespace\",\"keys\":252}"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed; the wicket's log:"
  cat "$dir/wicket.log"
  exit 1
fi
echo 'all passed'
