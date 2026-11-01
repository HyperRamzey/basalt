#!/bin/bash
# basalt_gpucmp.sh - compare GPU test results between the packaged stack, plain upstream main, and a
# single upstream PR on its own, with the running basalt endpoint parked for the duration and put back
# (proven loaded) before returning.  Synchronous for the same reason as basalt_build.sh: this session's
# own inference is answered by that endpoint.
#
# usage: basalt_gpucmp.sh [matrix|fp8-hc8|store]
#        matrix    the isolation matrix for the failures the stack showed
#        fp8-hc8   hc8_parity in the PR #129 tree: does #129's per-shape cuBLASLt plan selection by
#                  itself move the row-sliced product past the 1e-5 margin?
#        store     conversation_store_test only, in the three trees, parked
#
# Logs land in build/gpu_cmp/.

set -uo pipefail

SRC=/mnt/aosp/Projects/basalt/packaging/src/basalt
WORK=/mnt/aosp/Projects/basalt/build
CMP=$WORK/gpu_cmp
CFG=/home/sanjxz/.local/share/basalt/basalt_config.json
APP=/home/sanjxz/.local/share/basalt/app
HOST=127.0.0.1
PORT=8080
URL=http://$HOST:$PORT
MIN_AVAIL_GIB=30
MAX_VRAM_MIB=2500

mkdir -p "$CMP"
st() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$CMP/compare.log"; }

server_pids() { pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
engine_pids() { pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
avail_gib() { free -g | awk '/^Mem:/{print $7}'; }
vram_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

RESTORED=0
start_basalt() {
  [ "$RESTORED" = 1 ] && return 0
  if [ -n "$(server_pids)$(engine_pids)" ]; then RESTORED=1; st "basalt: already running"; return 0; fi
  setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$CMP/basalt_runtime.log" 2>&1 < /dev/null &
  st "basalt: starting (session pid $!); waiting for the model to load"
  RESTORED=1
}
wait_ready() {
  local limit=$1 _
  for _ in $(seq 1 "$limit"); do
    if [ -n "$(engine_pids)" ] && curl -s --max-time 5 "$URL/v1/models" 2>/dev/null | grep -q '"value": *"loaded"'; then
      st "basalt: model loaded on $URL ($(free -h | awk '/^Mem:/{print "mem used="$3" available="$7}'), vram $(vram_used_mib) MiB)"
      local model proof
      model=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["alias"])' "$CFG" 2>/dev/null)
      proof=$(curl -s --max-time 120 "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
        -d "{\"model\":\"${model:-qwen3.8-flash-next-iq3_xxs}\",\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}],\"max_tokens\":8}")
      [ -n "$proof" ] && { printf '%s\n' "$proof" > "$CMP/handoff.json"; st "basalt: handoff proof in $CMP/handoff.json"; return 0; }
      st "WARN: loaded but the proof request failed"; return 1
    fi
    sleep 5
  done
  return 1
}
park_basalt() {
  local s e p
  s=$(server_pids); e=$(engine_pids)
  [ -z "$s$e" ] && { st "basalt: not running"; return 0; }
  st "basalt: parking (server=[$s] engine=[$e])"
  for p in $s; do kill -INT "$p" 2>/dev/null || true; done
  for _ in $(seq 1 60); do e=$(engine_pids); [ -n "$e" ] || { st "basalt: engine gone"; break; }; sleep 2; done
  e=$(engine_pids)
  if [ -n "$e" ]; then
    for p in $e; do kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 30); do e=$(engine_pids); [ -n "$e" ] || break; sleep 2; done
  fi
  e=$(engine_pids)
  if [ -n "$e" ]; then for p in $e; do kill -KILL "$p" 2>/dev/null || true; done; sleep 3; fi
  for p in $(server_pids); do kill -KILL "$p" 2>/dev/null || true; done
  for _ in $(seq 1 90); do
    [ "$(avail_gib)" -ge "$MIN_AVAIL_GIB" ] && [ "$(vram_used_mib)" -le "$MAX_VRAM_MIB" ] && break
    sleep 2
  done
  st "basalt: parked. mem $(free -h | awk '/^Mem:/{print "used="$3" available="$7}'), vram $(vram_used_mib) MiB"
  [ "$(avail_gib)" -lt "$MIN_AVAIL_GIB" ] && { st "ERROR: only $(avail_gib) GiB free"; return 1; }
  return 0
}
on_exit() {
  local rc=$?
  if [ "$RESTORED" = 0 ]; then
    st "exiting (rc=$rc) without a finished restore: making sure basalt is back"
    start_basalt || true
    wait_ready 600 || st "WARN: basalt did not report a loaded model"
  fi
}
trap on_exit EXIT

# --- trees under test --------------------------------------------------------
wt() {   # wt <pr> <dir>: a worktree of upstream PR <pr>
  local n=$1 d=$2
  git -C "$SRC" rev-parse --verify -q "refs/pr/$n" >/dev/null || \
    git -C "$SRC" fetch -q --force https://github.com/jesdga95/basalt "refs/pull/$n/head:refs/pr/$n"
  if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then st "worktree $d already there"; return 0; fi
  git -C "$SRC" worktree add -f "$d" "refs/pr/$n" >/dev/null 2>&1 || { st "worktree $d failed"; return 1; }
  return 0
}
build_test() {   # build_test <src> <build dir> <target...>
  local s=$1 b=$2; shift 2
  st "configure+build $b ($*)"
  cmake -S "$s" -B "$b" -G Ninja -Wno-dev -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
    -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DBUILD_TESTING=ON >"$CMP/$(basename "$b").cmake.log" 2>&1 || { st "cmake failed for $b"; return 1; }
  ninja -C "$b" -j 10 "$@" >"$CMP/$(basename "$b").ninja.log" 2>&1 || { st "ninja failed for $b ($*)"; return 1; }
  return 0
}
run_n() {   # run_n <build dir> <binary> <label> <runs> [grep pattern]
  local b=$1 bin=$2 lab=$3 n=$4 pat=${5:-}
  local i out t0 t1
  for i in $(seq 1 "$n"); do
    out="$CMP/${lab}.run${i}.log"
    t0=$(date +%s)
    ( cd "$b" && timeout 900 "./$bin" ) >"$out" 2>&1
    local rc=$?
    t1=$(date +%s)
    if [ -n "$pat" ]; then
      grep -E "$pat" "$out" | sed "s/^/    [$lab run $i] /" | tee -a "$CMP/compare.log"
    fi
    st "$lab run $i rc=$rc wall=$((t1 - t0))s ($(wc -l < "$out") lines, $(grep -c 'FAIL' "$out") FAIL lines)"
  done
}

MODE=${1:-matrix}
st "=== gpu comparison start mode=$MODE ==="
park_basalt || { st "parking failed"; exit 1; }

if [ "$MODE" = fp8-hc8 ]; then
  wt 129 /tmp/pr129tree || exit 2
  build_test /tmp/pr129tree "$CMP/b129" hc8_parity prefill_fp8_dense_test || exit 3
  st "--- hc8_parity in the PR #129 tree (its per-shape cuBLASLt plans, no #174) ---"
  run_n "$CMP/b129" hc8_parity hc8-pr129 3 'sliced vs whole|FAIL|hc8_parity:'
  st "--- and in the stack, for the same session ---"
  run_n "$WORK/scratch" hc8_parity hc8-stack 2 'sliced vs whole|FAIL|hc8_parity:'
  st "=== comparison done ==="
  start_basalt; wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
  st "=== gpu comparison finished: endpoint restored ==="
  exit 0
fi
if [ "$MODE" = pinned-off ]; then
  # Is the pinned per-shape cuBLASLt algorithm (#157's gemm_plans) what moves the row-sliced hc product past
  # upstream's 1e-5 margin?  Take the two `pinned()` early returns out of the stack, rebuild, run, put them back.
  st "--- the stack with Gemm's pinned algorithms disabled ---"
  python3 - <<'PY'
import re
p = "/mnt/aosp/Projects/basalt/packaging/src/basalt/src/prefill/gemm.cu"
s = open(p).read()
n = 0
for t in ("if (pinned(CUDA_R_16BF, X, W, Y, T, N, K, ldy, beta)) return;",
          "if (pinned(CUDA_R_16F, X, W, Y, T, N, K, ldy, beta)) return;"):
    if s.count(t) == 1:
        s = s.replace(t, "// TEMP off: " + t); n += 1
open(p, "w").write(s)
print("pinned calls disabled:", n)
PY
  build_test "$SRC" "$WORK/scratch" hc8_parity || { git -C "$SRC" checkout -- src/prefill/gemm.cu; exit 3; }
  run_n "$WORK/scratch" hc8_parity hc8-nopinned 3 'sliced vs whole|FAIL|hc8_parity:'
  git -C "$SRC" checkout -- src/prefill/gemm.cu && st "gemm.cu back as committed"
  build_test "$SRC" "$WORK/scratch" hc8_parity || exit 3
  run_n "$WORK/scratch" hc8_parity hc8-stack-again 1 'sliced vs whole|FAIL|hc8_parity:'
  st "=== comparison done ==="
  start_basalt; wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
  st "=== gpu comparison finished: endpoint restored ==="
  exit 0
fi
if [ "$MODE" = pair ]; then
  # Which pair of merged PRs moves the row-sliced hc product past the 1e-5 margin?  #129 and #174 each pass
  # on their own; the stack fails.  Merge one onto the other's tree and build in the tree's own build dir.
  for n in 129 174 157; do git -C "$SRC" rev-parse --verify -q "refs/pr/$n" >/dev/null || \
    git -C "$SRC" fetch -q --force https://github.com/jesdga95/basalt "refs/pull/$n/head:refs/pr/$n"; done
  st "--- main + #129 + #174 ---"
  if git -C /tmp/pr129tree merge --no-edit -q refs/pr/174; then st "merged #174 onto the #129 tree"; else
    st "#174 conflicts with #129: $(git -C /tmp/pr129tree diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C /tmp/pr129tree merge --abort 2>/dev/null
  fi
  build_test /tmp/pr129tree "$CMP/b129" hc8_parity || exit 3
  run_n "$CMP/b129" hc8_parity hc8-pr129-pr174 2 'sliced vs whole|FAIL|hc8_parity:'

  st "--- main + #157 alone ---"
  if git -C /tmp/basetree merge --no-edit -q refs/pr/157; then st "merged #157 onto plain main"; else
    st "#157 conflicts with main: $(git -C /tmp/basetree diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C /tmp/basetree merge --abort 2>/dev/null
  fi
  build_test /tmp/basetree "$WORK/baseline" hc8_parity || exit 3
  run_n "$WORK/baseline" hc8_parity hc8-plainmain-pr157 2 'sliced vs whole|FAIL|hc8_parity:'
  git -C /tmp/basetree reset --hard -q 876e47e8 && st "basetree back at 876e47e8"

  st "=== comparison done ==="
  start_basalt; wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
  st "=== gpu comparison finished: endpoint restored ==="
  exit 0
fi
if [ "$MODE" = store ]; then
  st "--- conversation_store_test parked: plain main vs the stack vs PR #149 alone ---"
  run_n "$WORK/baseline" conversation_store_test store-plainmain 1 'cannot write|ok'
  run_n "$WORK/scratch"  conversation_store_test store-stack     1 'cannot write|ok'
  [ -x "$WORK/pr149/conversation_store_test" ] && run_n "$WORK/pr149" conversation_store_test store-pr149 1 'cannot write|ok'
  st "=== comparison done ==="
  start_basalt; wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
  st "=== gpu comparison finished: endpoint restored ==="
  exit 0
fi

wt 174 /tmp/pr174tree || exit 2
wt 129 /tmp/pr129tree || exit 2
build_test /tmp/pr174tree "$CMP/b174" hc8_parity || exit 3
build_test /tmp/pr129tree "$CMP/b129" prefill_fp8_dense_test || exit 3

st "--- hc8_parity: plain main (876e47e8) vs the stack vs PR #174 alone ---"
run_n "$WORK/baseline" hc8_parity hc8-plainmain 3 'sliced vs whole|FAIL|hc8_parity:'
run_n "$WORK/scratch"  hc8_parity hc8-stack     3 'sliced vs whole|FAIL|hc8_parity:'
run_n "$CMP/b174"      hc8_parity hc8-pr174     3 'sliced vs whole|FAIL|hc8_parity:'

st "--- prefill_fp8_dense_test: the stack vs PR #129 alone ---"
run_n "$CMP/b129"   prefill_fp8_dense_test fp8-pr129 1 'FAIL|failure'
run_n "$WORK/scratch" prefill_fp8_dense_test fp8-stack 1 'FAIL|failure'

st "--- conversation_store_test parked: plain main vs the stack vs PR #149 alone ---"
run_n "$WORK/baseline" conversation_store_test store-plainmain 1 'cannot write|ok'
run_n "$WORK/scratch"  conversation_store_test store-stack     1 'cannot write|ok'
if [ -x "$WORK/pr149/conversation_store_test" ]; then
  run_n "$WORK/pr149" conversation_store_test store-pr149 1 'cannot write|ok'
else
  st "no pr149 build yet"
fi

st "=== comparison done ==="
start_basalt
wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
st "=== gpu comparison finished: endpoint restored ==="
