#!/usr/bin/env bash
# One-command local demo: fresh anvil chain -> deploy -> seed demo state -> frontend config -> static web server.
#
#   ./run.sh                      # anvil on :8554, web on :5554
#   ANVIL_PORT=9545 WEB_PORT=8080 ./run.sh
#   SEED=0 ./run.sh               # deploy only, no demo data
#
# Ctrl-C (or SIGTERM) stops every process this script started.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANVIL_PORT="${ANVIL_PORT:-8554}"
WEB_PORT="${WEB_PORT:-5554}"
SEED="${SEED:-1}"
HISTORY_DAYS="${HISTORY_DAYS:-10}"
RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
RUN_DIR="$ROOT/.run"
# anvil's well-known account #0 (mnemonic "test test ... junk") -- local development only
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

mkdir -p "$RUN_DIR"
PIDS=()

log() { printf '\033[1;36m[run]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[run] %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  trap - EXIT INT TERM
  if ((${#PIDS[@]})); then
    log "stopping ${PIDS[*]}"
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/pids"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in anvil forge cast python3; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found on PATH (install Foundry / Python 3)"
done

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
port_busy "$ANVIL_PORT" && die "port $ANVIL_PORT is in use (another anvil?). Stop it or set ANVIL_PORT=..."
port_busy "$WEB_PORT" && die "port $WEB_PORT is in use. Stop it or set WEB_PORT=..."

# ---------------------------------------------------------------------------------------------- chain
NOW=$(date +%s)
START=$((NOW - HISTORY_DAYS * 86400))
log "starting anvil on :$ANVIL_PORT (genesis time $(date -d "@$START" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$START"))"
anvil --port "$ANVIL_PORT" --host 127.0.0.1 --chain-id 31337 --accounts 10 --balance 10000 \
  --timestamp "$START" >"$RUN_DIR/anvil.log" 2>&1 &
PIDS+=($!)
echo "${PIDS[*]}" >"$RUN_DIR/pids"
for _ in $(seq 1 100); do
  cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
  kill -0 "${PIDS[0]}" 2>/dev/null || die "anvil exited, see $RUN_DIR/anvil.log"
  sleep 0.1
done
cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 || die "anvil did not start, see $RUN_DIR/anvil.log"

# ---------------------------------------------------------------------------------------------- deploy
log "building contracts"
# (via-IR: a cold build takes a minute or two; the committed out/ + cache/ make it instant)
(cd "$ROOT/contracts" && forge build --skip test >"$RUN_DIR/build.log" 2>&1) || die "forge build failed, see $RUN_DIR/build.log"
log "deploying (script/Deploy.s.sol)"
rm -f "$ROOT/contracts/deployments/31337.json"
(cd "$ROOT/contracts" && forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast >"$RUN_DIR/deploy.log" 2>&1) || die "deployment failed, see $RUN_DIR/deploy.log"
DEPLOYMENT="$ROOT/contracts/deployments/31337.json"
[[ -f "$DEPLOYMENT" ]] || die "deployment file missing: $DEPLOYMENT"
grep -E "PredictionMarket|OrderBook|ReputationOracle|USDT|DAI |WETH" "$RUN_DIR/deploy.log" | sed 's/^ */      /' || true

# ---------------------------------------------------------------------------------------------- seed
if [[ "$SEED" == "1" ]]; then
  log "seeding ${HISTORY_DAYS} days of demo history (markets, trades, LPs, P2P orders, votes, resolutions)"
  python3 "$ROOT/scripts/seed.py" --rpc "$RPC_URL" --deployment "$DEPLOYMENT" --end "$NOW" --days "$HISTORY_DAYS" \
    2>&1 | tee "$RUN_DIR/seed.log" | sed 's/^/      /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "seeding failed, see $RUN_DIR/seed.log"
else
  cast rpc evm_setNextBlockTimestamp "$(date +%s)" --rpc-url "$RPC_URL" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
fi

# a block every second so the chain clock follows wall-clock time (the UI reasons about chain time)
cast rpc evm_setIntervalMining 1 --rpc-url "$RPC_URL" >/dev/null

# ---------------------------------------------------------------------------------------------- frontend
python3 "$ROOT/scripts/gen_config.py" --deployment "$DEPLOYMENT" --rpc-url "$RPC_URL" | sed 's/^/      /'
python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 --directory "$ROOT/frontend" >"$RUN_DIR/web.log" 2>&1 &
PIDS+=($!)
echo "${PIDS[*]}" >"$RUN_DIR/pids"
for _ in $(seq 1 50); do port_busy "$WEB_PORT" && break; sleep 0.1; done

cat <<EOF

  ┌──────────────────────────────────────────────────────────────────────┐
    Prediction market demo is running
      Frontend : http://127.0.0.1:${WEB_PORT}
      RPC      : ${RPC_URL}   (chainId 31337)
      Wallet   : pick "Local demo wallet" (Alice..Judy) or MetaMask
      Logs     : ${RUN_DIR}/
    Press Ctrl-C to stop anvil and the web server.
  └──────────────────────────────────────────────────────────────────────┘
EOF
echo "READY http://127.0.0.1:${WEB_PORT}"

# stay in the foreground until Ctrl-C / SIGTERM (handled by the traps) or until a child dies
while true; do
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || die "a child process ($pid) exited unexpectedly (see $RUN_DIR/*.log)"
  done
  sleep 1 &
  wait $! || true
done
