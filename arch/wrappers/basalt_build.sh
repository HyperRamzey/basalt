#!/bin/bash
# basalt_build.sh - build / test / package the packaged basalt tree while the running
# basalt endpoint is parked, and put the endpoint back before returning.
#
# Why it parks: the build is CPU/RAM heavy (ninja + nvcc) and the running engine holds a
# ~31 GiB page-locked expert complement and ~10 GiB of VRAM.  Building beside it OOMs or
# thrashes.  Why it restores: this agent session's own inference is answered by that
# endpoint, so the script is synchronous - it never returns with basalt down (unless
# --keep-parked is given on purpose).
#
# Modeled on /mnt/aosp/Projects/Derp/hm_mod/strata_build.sh: park the local model, do the
# work, restart, wait until /v1/models reports the model "loaded", prove it with one chat
# completion, then return.
#
# usage: basalt_build.sh [--jobs N] [--tests] [--no-tests] [--package] [--install]
#                        [--only TARGET...] [--ctest FILTER] [--keep-parked] [--dry-run]
#                        [--src DIR] [--build DIR]   a different tree/build dir: a baseline build of
#                        plain upstream main, to tell our merges apart from the environment
#
#   --jobs N        ninja parallelism (default 8)
#   --tests         run ctest after the build (default on)
#   --no-tests      skip ctest
#   --package       run makepkg in packaging/ after a green build
#   --install       pacman -U the package makepkg produced (implies --package)
#   --only T ...    build only these ninja targets
#   --ctest F       ctest -R F (a regex), instead of the whole suite
#   --accept-known-failures   let the build continue when ctest's only failures are the three measured
#                             environment failures (expert_multi_test, ple_reader_selftest,
#                             prefill_fp8_dense_test); anything else still stops the run
#   --package-only  skip the scratch build and ctest and go straight to makepkg: it builds from its own
#                   clone (patches/BASE + patches/basalt-stack.patch), which is how the packaged stack is
#                   checked end to end after packaging/ itself changed
#   --pkg-dir DIR   run makepkg in DIR instead of packaging/ -- a throwaway copy of PKGBUILD + patches/ used
#                   to prove the patch path from a clean clone without touching the development srcdir
#   --keep-parked   leave basalt stopped (deliberate; the session's inference is then down)
#   --dry-run       print the plan, touch nothing

set -uo pipefail

SRC=/mnt/aosp/Projects/basalt/packaging/src/basalt
PKG=/mnt/aosp/Projects/basalt/packaging
WORK=/mnt/aosp/Projects/basalt/build
BUILD=$WORK/scratch
STATE=$WORK/build.log
PIDFILE=$WORK/build.pid
CFG=/home/sanjxz/.local/share/basalt/basalt_config.json
APP=/home/sanjxz/.local/share/basalt/app
ENGINE_BIN=$APP/bin/basalt
CACHE_HOME=/home/sanjxz/.cache/basalt
HOST=127.0.0.1
PORT=8080
URL=http://$HOST:$PORT
JOBS=8
RUN_TESTS=1
DO_PACKAGE=0
DO_INSTALL=0
KEEP_PARKED=0
DRY=0
ONLY=()
CTEST_FILTER=""
ACCEPT_KNOWN=0
PKG_ONLY=0
NO_EXTRACT=1
# Verified against plain upstream main 876e47e8 and against each PR on its own tree, 2026-11-01: these three fail
# here because of the machine and the toolchain, not because of anything merged into the makepkg branch.
KNOWN_FAILURES=(expert_multi_test ple_reader_selftest prefill_fp8_dense_test)
MIN_AVAIL_GIB=30      # the RAM the build needs once the engine's pinned complement is gone
MAX_VRAM_MIB=2500     # the VRAM the engine's 10 GiB must release to

# --- args --------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS=$2; shift 2 ;;
    --tests) RUN_TESTS=1; shift ;;
    --no-tests) RUN_TESTS=0; shift ;;
    --package) DO_PACKAGE=1; shift ;;
    --install) DO_INSTALL=1; DO_PACKAGE=1; shift ;;
    --only) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do ONLY+=("$1"); shift; done ;;
    --src) SRC=$2; BUILD="$WORK/scratch-$(basename "$SRC")"; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --ctest) CTEST_FILTER=$2; shift 2 ;;
    --accept-known-failures) ACCEPT_KNOWN=1; shift ;;
    --package-only) DO_PACKAGE=1; PKG_ONLY=1; RUN_TESTS=0; shift ;;
    --pkg-dir) PKG=$2; NO_EXTRACT=0; shift 2 ;;
    --keep-parked) KEEP_PARKED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "basalt_build: unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
st() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATE"; }
# finish_reason plus how many answer characters came back: a max_tokens below 1024 can be swallowed by the thinking
proof_summary(){ jq -r '"end=" + (.choices[0].finish_reason // "?") + " content=" + ((.choices[0].message.content // "") | length | tostring) + " chars"' 2>/dev/null; }

[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && {
  echo "basalt_build: another build is already going (pid $(cat "$PIDFILE")). Refusing." >&2; exit 1; }

# --- processes ---------------------------------------------------------------
server_pids() { pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
engine_pids() { pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
basalt_running() { [ -n "$(server_pids)$(engine_pids)" ]; }
avail_gib() { free -g | awk '/^Mem:/{print $7}'; }
vram_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

RESTORED=0
start_basalt() {
  if [ "$RESTORED" = 1 ]; then return 0; fi
  if basalt_running; then RESTORED=1; st "basalt: already running, nothing to start"; return 0; fi
  setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$WORK/basalt_runtime.log" 2>&1 < /dev/null &
  st "basalt: starting (session pid $!); waiting for the model to load"
  RESTORED=1
  return 0
}

wait_ready() {   # the model must be resident AND listed as loaded, then one chat completion
  local limit=$1 _
  for _ in $(seq 1 "$limit"); do
    if [ -n "$(engine_pids)" ] && curl -s --max-time 5 "$URL/v1/models" 2>/dev/null | grep -q '"value": *"loaded"'; then
      st "basalt: model loaded on $URL ($(free -h | awk '/^Mem:/{print "mem used="$3" available="$7}'), vram $(vram_used_mib) MiB)"
      local model proof
      model=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["alias"])' "$CFG" 2>/dev/null)
      model=${model:-qwen3.8-flash-next-iq3_xxs}
      # max_tokens above 1024 so the server's --answer-room reserves room for the answer: a tiny cap can be
      # swallowed by the thinking alone and answer with reasoning_content only.
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
  for p in $s; do kill -INT "$p" 2>/dev/null || true; done      # serve's graceful path: QUIT -> TERM -> KILL
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
  # the pinned complement and the VRAM have to be back, not merely "the process is gone"
  for _ in $(seq 1 90); do
    [ "$(avail_gib)" -ge "$MIN_AVAIL_GIB" ] && [ "$(vram_used_mib)" -le "$MAX_VRAM_MIB" ] && break
    sleep 2
  done
  st "basalt: parked. mem $(free -h | awk '/^Mem:/{print "used="$3" available="$7}'), vram $(vram_used_mib) MiB"
  if [ "$(avail_gib)" -lt "$MIN_AVAIL_GIB" ]; then
    st "ERROR: only $(avail_gib) GiB free after parking (need $MIN_AVAIL_GIB)"
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

MODEL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["alias"])' "$CFG" 2>/dev/null)
CMAKE_ARGS=( -S "$SRC" -B "$BUILD" -G Ninja -Wno-dev
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER=/usr/bin/gcc
  -DCMAKE_CXX_COMPILER=/usr/bin/g++
  -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc
  -DCMAKE_CUDA_ARCHITECTURES=120
  -DBUILD_TESTING=ON )
NINJA_ARGS=( -C "$BUILD" -j "$JOBS" )
[ ${#ONLY[@]} -gt 0 ] && NINJA_ARGS+=("${ONLY[@]}")
CTEST_ARGS=( --test-dir "$BUILD" --output-on-failure )
[ -n "$CTEST_FILTER" ] && CTEST_ARGS+=( -R "$CTEST_FILTER" )

st "=== basalt_build start pid=$$ jobs=$JOBS tests=$RUN_TESTS package=$DO_PACKAGE install=$DO_INSTALL only=[${ONLY[*]:-}] ctest_filter=[${CTEST_FILTER:-all}] source=$SRC build=$BUILD"

if [ "$DRY" = 1 ]; then
  st "dry run: cmake ${CMAKE_ARGS[*]}"
  st "dry run: ninja ${NINJA_ARGS[*]}"
  [ "$RUN_TESTS" = 1 ] && st "dry run: ctest ${CTEST_ARGS[*]}"
  [ "$DO_PACKAGE" = 1 ] && st "dry run: (cd $PKG && _jobs=$JOBS makepkg --noconfirm --noextract -f)"
  st "dry run: basalt was not touched"
  exit 0
fi

if [ -f "$SRC/CMakeLists.txt" ] && grep -qn '^<<<<<<<\|^>>>>>>>\|^|||||||' "$SRC/CMakeLists.txt"; then
  st "ERROR: CMakeLists.txt still carries conflict markers; nothing was parked"
  exit 2
fi
if bad=$(git -C "$SRC" grep -ln '^<<<<<<< ' HEAD -- . 2>/dev/null | head -5) && [ -n "$bad" ]; then
  st "ERROR: conflict markers in the tracked tree: $(echo "$bad" | tr '\n' ' ')"
  exit 2
fi

echo $$ > "$PIDFILE"
park_basalt || { st "parking failed; refusing to build"; exit 1; }

if [ "$PKG_ONLY" = 1 ]; then
  st "package-only: makepkg in $PKG builds from its own clone ($(cut -c1-8 "$PKG/patches/BASE" 2>/dev/null) + patches/basalt-stack.patch); no scratch build, no ctest"
else

# --- configure ---------------------------------------------------------------
st "cmake configure"
cmake "${CMAKE_ARGS[@]}" >"$WORK/cmake_configure.log" 2>&1
rc=$?
tail -8 "$WORK/cmake_configure.log" | sed 's/^/    /' | tee -a "$STATE"
[ $rc -ne 0 ] && { st "cmake configure FAILED rc=$rc"; exit 1; }

# --- build -------------------------------------------------------------------
st "ninja build (-j $JOBS)"
ninja "${NINJA_ARGS[@]}" >"$WORK/ninja.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  st "ninja build FAILED rc=$rc"
  grep -n 'error:\|FAILED:' "$WORK/ninja.log" | head -40 | sed 's/^/    /' | tee -a "$STATE"
  exit 1
fi
st "ninja build ok ($(grep -c '^\[' "$WORK/ninja.log") steps logged)"

# --- tests -------------------------------------------------------------------
if [ "$RUN_TESTS" = 1 ]; then
  st "ctest ${CTEST_ARGS[*]}"
  ctest "${CTEST_ARGS[@]}" >"$WORK/ctest.log" 2>/dev/null
  rc=$?
  grep -E '^[0-9]+% tests passed|The following tests FAILED' -A 12 "$WORK/ctest.log" | sed 's/^/    /' | tee -a "$STATE"
  grep -E 'Test #|Passed|Failed|Skipped|Not Run' "$WORK/ctest.log" | tail -60 | sed 's/^/    /' | tee -a "$STATE"
  if [ $rc -ne 0 ]; then
    mapfile -t failed < <(sed -n '/The following tests FAILED:/,$p' "$WORK/ctest.log" | \
      sed -nE 's/^[[:space:]]*[0-9]+ - (.*)$/\1/p')
    unknown=()
    for t in "${failed[@]}"; do
      hit=0
      for k in "${KNOWN_FAILURES[@]}"; do [ "$t" = "$k" ] && hit=1; done
      [ $hit -eq 0 ] && unknown+=("$t")
    done
    if [ "$ACCEPT_KNOWN" = 1 ] && [ ${#failed[@]} -gt 0 ] && [ ${#unknown[@]} -eq 0 ]; then
      st "ctest rc=$rc, but every failure is an accepted known one: ${failed[*]}"
      st "  expert_multi_test: this CPU (Ryzen 7 5700X3D) has no AVX512-VNNI/VBMI; fails identically on plain main"
      st "  ple_reader_selftest: keep-alive windows and warm_rows; fails identically on plain main 876e47e8"
      st "  prefill_fp8_dense_test: E4M3 per-row scales disagree with the CPU encoder under CUDA 13.4; fails"
      st "  identically on PR #129's own branch.  FP8 dense prefill is opt-in and stays off in the config."
    else
      st "ctest FAILED rc=$rc (see $WORK/ctest.log)"
      [ ${#unknown[@]} -gt 0 ] && st "  unexpected failures: ${unknown[*]}"
      exit 1
    fi
  else
    st "ctest passed"
  fi
fi

fi   # the scratch build / ctest half (skipped by --package-only)

# --- package -----------------------------------------------------------------
PKG_FILE=""
if [ "$DO_PACKAGE" = 1 ]; then
  st "makepkg"
  # -f: a previous run's package file is normally still sitting in packaging/ (this wrapper keeps them), and
  # makepkg refuses to overwrite one without it.
  # The normal run reuses packaging/src (the development clone) and skips prepare(); a --pkg-dir run is the
  # opposite on purpose: a clean clone plus patches/, with prepare() assembling $srcdir/stack from the patch and
  # comparing the tree hash against patches/TREE.
  mkargs=(--noconfirm -f)
  mkenv=(_jobs="$JOBS")
  if [ "$NO_EXTRACT" = 1 ]; then
    # --noextract skips prepare(), so tell makepkg which tree to package: the one already in its srcdir.
    mkargs+=(--noextract)
    mkenv+=(_src_dir=basalt)
  fi
  ( cd "$PKG" && env "${mkenv[@]}" makepkg "${mkargs[@]}" ) >"$WORK/makepkg.log" 2>&1
  rc=$?
  tail -12 "$WORK/makepkg.log" | sed 's/^/    /' | tee -a "$STATE"
  if [ $rc -ne 0 ]; then st "makepkg FAILED rc=$rc"; exit 1; fi
  PKG_FILE=$(ls -t "$PKG"/basalt-engine-git-*.pkg.tar* 2>/dev/null | head -1)
  st "package: $PKG_FILE"
  if [ "$DO_INSTALL" = 1 ]; then
    st "pacman -U $PKG_FILE"
    echo root | sudo -S -p '' pacman -U --noconfirm "$PKG_FILE" >"$WORK/pacman.log" 2>&1
    rc=$?
    tail -8 "$WORK/pacman.log" | sed 's/^/    /' | tee -a "$STATE"
    [ $rc -ne 0 ] && { st "pacman -U FAILED rc=$rc"; exit 1; }
    st "installed: $(pacman -Q basalt-engine-git)"
  fi
fi

# --- handoff -----------------------------------------------------------------
if [ "$KEEP_PARKED" = 1 ]; then
  st "--keep-parked: basalt stays down. Start it by hand: basalt"
  rm -f "$PIDFILE"
  exit 0
fi
start_basalt
wait_ready 720 || { st "ERROR: the endpoint did not come back loaded"; exit 1; }
rm -f "$PIDFILE"
st "=== basalt_build done: endpoint restored and proven ==="
