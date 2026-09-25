#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROTO="$ROOT/prototype/harmony-muse"

if [[ -f "$PROTO/.env" ]]; then
  set -a
  source "$PROTO/.env"
  set +a
fi

mkdir -p "$PROTO/.run"

start_bg() {
  local name="$1"
  shift
  if [[ -f "$PROTO/.run/$name.pid" ]] && kill -0 "$(cat "$PROTO/.run/$name.pid")" 2>/dev/null; then
    echo "$name already running"
    return
  fi
  nohup "$@" >"$PROTO/.run/$name.log" 2>&1 &
  echo $! >"$PROTO/.run/$name.pid"
  echo "started $name pid=$(cat "$PROTO/.run/$name.pid")"
}

start_bg minimax node "$PROTO/minimax_proxy.js"
sleep 1
start_bg agent python3 "$PROTO/agent_runtime.py"
sleep 1
start_bg relay node "$PROTO/relay.js"

echo
echo "health:"
curl -fsS "http://${MINIMAX_PROXY_HOST:-127.0.0.1}:${MINIMAX_PROXY_PORT:-8790}/health" && echo
curl -fsS "http://${HARMONY_AGENT_HOST:-127.0.0.1}:${HARMONY_AGENT_PORT:-8791}/health" && echo
curl -fsS "http://${HARMONY_RELAY_HOST:-127.0.0.1}:${HARMONY_RELAY_PORT:-8787}/health" && echo
