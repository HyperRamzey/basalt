#!/bin/bash
# Run the upstream community benchmark preset (--community) on this rig, and hand the endpoint back.
#
# The community preset is the only basalt measurement that is comparable with the public table in
# docs/community/benchmarks.json: three decode fixtures, a 16 384-token prefill and a 65 536-token prefill,
# each in a fresh engine process, int8 KV, the engine's own defaults otherwise, no warm-up, no repetition.
# It refuses any other flag (--engine, --spec, --kv-resident, ...) for exactly that reason, so this wrapper
# measures the stock behaviour of the installed stack and nothing else.
#
# usage: basalt_bench.sh [--probe] [--keep-parked] [--dry-run] [--row FILE]
#
#   --probe  run basalt-probe instead of the community preset: this machine's expert throughput rates, cold
#            decode on conv/struct/prose, and the settings the probe would suggest (docs/probe.md)
#
#   --row FILE   the benchmarks.json the row is written to (default bench/benchmarks-local.json; the repo's
#                own docs/community/benchmarks.json in the packaging tree is never touched)
#   --keep-parked  leave basalt stopped (deliberate; the session's inference is then down)
#   --dry-run    print the plan, touch nothing
#
set -uo pipefail

HERE=/mnt/aosp/Projects/basalt
WORK=$HERE/bench
STATE=$WORK/bench.log
PIDFILE=$WORK/bench.pid
CFG=/home/sanjxz/.local/share/basalt/basalt_config.json
APP=/home/sanjxz/.local/share/basalt/app
MODEL_PACK=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["model"])' "$CFG")
# The bench refuses --engine, so it must run with the engine path compiled into it.  The build in the
# packaging tree puts both programs in <tree>/bin, which is where its compiled-in default points; that is the
# same source tip (branch makepkg) the installed package was built from.
BENCH_BIN=/mnt/aosp/Projects/basalt/packaging/src/basalt/bin/basalt-bench
ENGINE_BIN=/mnt/aosp/Projects/basalt/packaging/src/basalt/bin/basalt
FIXTURES=/usr/share/basalt/data/bench
ROW=$WORK/benchmarks-local.json
SUBMITTER=sanjxz
HOST=127.0.0.1
PORT=8080
URL=http://$HOST:$PORT
KEEP_PARKED=0
DRY=0
MODE=community

while [ $# -gt 0 ]; do
  case "$1" in
    --row) ROW=$2; shift 2 ;;
    --probe) MODE=probe; shift ;;
    --keep-parked) KEEP_PARKED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "basalt_bench: unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
st() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATE"; }
proof_summary(){ jq -r '"end=" + (.choices[0].finish_reason // "?") + " content=" + ((.choices[0].message.content // "") | length | tostring) + " chars"' 2>/dev/null; }

[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && {
  echo "basalt_bench: another bench is already going (pid $(cat "$PIDFILE")). Refusing." >&2; exit 1; }

server_pids() { pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
engine_pids() { pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
basalt_running() { [ -n "$(server_pids)$(engine_pids)" ]; }
avail_gib() { free -g | awk '/^Mem:/{print $7}'; }
vram_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

MIN_AVAIL_GIB=42      # the IQ3_XXS pack keeps 40.0 GiB of experts resident, plus the engine's own working set.
                      # The bench has its own gate: it refuses a row if any expert is read from the SSD.
MAX_VRAM_MIB=2500

RESTORED=0
start_basalt() {
  if [ "$RESTORED" = 1 ]; then return 0; fi
  if basalt_running; then RESTORED=1; st "basalt: already running, nothing to start"; return 0; fi
  setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$WORK/basalt_runtime.log" 2>&1 < /dev/null &
  st "basalt: starting (session pid $!); waiting for the model to load"
  RESTORED=1
  return 0
}

wait_ready() {
  local limit=$1 _
  for _ in $(seq 1 "$limit"); do
    if [ -n "$(engine_pids)" ] && curl -s --max-time 5 "$URL/v1/models" 2>/dev/null | grep -q '"value": *"loaded"'; then
      st "basalt: model loaded on $URL ($(free -h | awk '/^Mem:/{print "mem used="$3" available="$7}'), vram $(vram_used_mib) MiB)"
      local model proof
      model=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["alias"])' "$CFG" 2>/dev/null)
      model=${model:-qwen3.8-flash-next-iq3_xxs}
      proof=$(curl -s --max-time 120 "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}],\"max_tokens\":1200}")
      if [ -n "$proof" ]; then
        printf '%s\n' "$proof" > "$WORK/handoff.json"
        st "basalt: handoff proof stored in $WORK/handoff.json ($(printf '%s' "$proof" | proof_summary))"
        return 0
      fi
      st "WARN: basalt lists the model as loaded but the proof request failed"
      return 1
    fi
    sleep 5
  done
  return 1
}

park_basalt() {
  local s e p
  s=$(server_pids); e=$(engine_pids)
  if [ -z "$s$e" ]; then st "basalt: not running; nothing to park"; return 0; fi
  st "basalt: parking (server=[$s] engine=[$e])"
  for p in $s; do kill -INT "$p" 2>/dev/null || true; done
  for _ in $(seq 1 60); do e=$(engine_pids); [ -n "$e" ] || { st "basalt: engine gone"; break; }; sleep 2; done
  e=$(engine_pids)
  if [ -n "$e" ]; then
    st "basalt: engine still up after SIGINT ([$e]); sending TERM"
    for p in $e; do kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 30); do e=$(engine_pids); [ -n "$e" ] || break; sleep 2; done
  fi
  e=$(engine_pids)
  if [ -n "$e" ]; then
    st "basalt: engine ignored TERM; sending KILL ([$e])"
    for p in $e; do kill -KILL "$p" 2>/dev/null || true; done
    sleep 3
  fi
  for p in $(server_pids); do kill -KILL "$p" 2>/dev/null || true; done
  for _ in $(seq 1 90); do
    [ "$(avail_gib)" -ge "$MIN_AVAIL_GIB" ] && [ "$(vram_used_mib)" -le "$MAX_VRAM_MIB" ] && break
    sleep 2
  done
  st "basalt: parked. mem $(free -h | awk '/^Mem:/{print "used="$3" available="$7}'), vram $(vram_used_mib) MiB"
  if [ "$(avail_gib)" -lt "$MIN_AVAIL_GIB" ]; then
    st "ERROR: only $(avail_gib) GiB free after parking (need $MIN_AVAIL_GIB: the pack keeps 40.0 GiB of experts resident)"
    return 1
  fi
  return 0
}

on_exit() {
  local rc=$?
  rm -f "$PIDFILE"
  if [ "$KEEP_PARKED" = 0 ] && [ "$RESTORED" = 0 ]; then
    st "exiting (rc=$rc) without a finished restore: making sure basalt is back"
    start_basalt || true
    wait_ready 600 || st "WARN: basalt did not report a loaded model -- check $WORK/basalt_runtime.log and start it by hand: basalt"
  fi
}
trap on_exit EXIT

st "=== basalt_bench start pid=$$ mode=$MODE submitter=$SUBMITTER row=$ROW pack=$MODEL_PACK"

if [ "$DRY" = 1 ]; then
  st "dry run: park basalt, then $BENCH_BIN --model $MODEL_PACK --fixtures $FIXTURES --community --submitter $SUBMITTER --community-file $ROW"
  st "dry run: compiled-in engine default of that bench:"
  "$BENCH_BIN" --model "$MODEL_PACK" --fixtures "$FIXTURES" --community --submitter "$SUBMITTER" --community-file "$ROW" --print-command 2>&1 | sed 's/^/    /' | tee -a "$STATE"
  st "dry run: basalt was not touched"
  exit 0
fi

[ -x "$BENCH_BIN" ] || { st "ERROR: no bench binary at $BENCH_BIN"; exit 2; }
[ -f "$MODEL_PACK" ] || { st "ERROR: no pack at $MODEL_PACK"; exit 2; }

# the hardware line the community row records (CPU, RAM read speed, PCIe link, pinned H2D copy)
st "hardware probe"
"$BENCH_BIN" --hardware 2>&1 | tee -a "$STATE"

park_basalt || { st "parking failed; refusing to bench"; exit 1; }
echo $$ > "$PIDFILE"

if [ "$MODE" = probe ]; then
  st "basalt-probe (cold decode on conv/struct/prose + the adaptive tier's settings, defaults)"
  PROBE_BIN="${BENCH_BIN%-bench}-probe"
  "$PROBE_BIN" --model "$MODEL_PACK" --fixtures "$FIXTURES" --logs "$WORK/probe-logs" >"$WORK/probe.log" 2>&1
  rc=$?
  tail -30 "$WORK/probe.log" | sed 's/^/    /' | tee -a "$STATE"
  if [ $rc -ne 0 ]; then st "basalt-probe FAILED rc=$rc (see $WORK/probe.log)"; exit 1; fi
  st "=== probe done; returning the endpoint ==="
  start_basalt
  wait_ready 600 || { st "WARN: endpoint not proven"; exit 1; }
  st "=== basalt_bench done: endpoint restored and proven ==="
  exit 0
fi

st "community preset (three decode fixtures + 16k and 64k prefill, each in its own engine process)"
"$BENCH_BIN" --model "$MODEL_PACK" --fixtures "$FIXTURES" --community \
  --submitter "$SUBMITTER" --community-file "$ROW" >"$WORK/community.log" 2>&1
rc=$?
tail -40 "$WORK/community.log" | sed 's/^/    /' | tee -a "$STATE"
if [ $rc -ne 0 ]; then st "basalt-bench FAILED rc=$rc (see $WORK/community.log)"; exit 1; fi
st "row written to $ROW"
[ -f "$ROW" ] && python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=d['runs'][-1]
print('    ', r['submitter'], r['date'], r['commit'], r['quant'],
      'pp16k=%s pp64k=%s decode=%s' % (r.get('prefill_16k_tps'), r.get('prefill_64k_tps'), r.get('decode_tps')))
" "$ROW" 2>&1 | tee -a "$STATE"

st "=== bench done; returning the endpoint ==="
start_basalt
wait_ready 600 || { st "WARN: endpoint not proven"; exit 1; }
st "=== basalt_bench done: endpoint restored and proven ==="
