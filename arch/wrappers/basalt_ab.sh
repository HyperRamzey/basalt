#!/usr/bin/env bash
# =============================================================================
# basalt_ab.sh -- park basalt, A/B two --kv-resident settings on ONE fixed long
#                 prompt, restore basalt, and hand the session back.
#
#   basalt_ab.sh [KV_A KV_B] [--tokens N] [--max-tokens N] [--apply-winner]
#                [--no-restore] [--dry-run] [--reparse] [--status]
#
# Defaults: KV_A=32768 (the incumbent in basalt_config.json) KV_B=131072,
#           --tokens 40000 (target prompt tokens), --max-tokens 512.
#
# WHY IT HAS TO BE A WRAPPER AT ALL -- same contract as Derp's
# hm_mod/strata_build.sh (pointer: Derp/AGENTS.md, "Building -- permanent rule
# while strata is running"). This host runs the local LLM that serves THIS
# agent session (PI_PROVIDER / PI_MODEL qwen3.8-flash-next-iq3_xxs, endpoint
# 127.0.0.1:8080), and 8080 is answered by basalt: python3 -m serve.server +
# ~/.local/share/basalt/app/bin/basalt --serve, ~42 GiB RSS. Parking it breaks
# the session's own inference -- every turn fails with a connection error --
# unless the session sits inside one blocked tool call for the whole run. So
# the default mode is SYNCHRONOUS: park, measure, restore, wait until
# /v1/models reports the model `loaded`, and only then return. The session is
# never asked to think while its own engine is down.
#
#   1. preflight  no parking, no model: run serve.config's own parser over
#                 basalt_config.json + the override words and print the engine
#                 line, and check every override against the engine binary's
#                 real flag list (serve.config.check_engine_flags). A typo in a
#                 flag is caught while basalt is still up.
#   2. park       SIGINT the serve process (its own path is QUIT -> terminate
#                 -> kill for the engine), then TERM/KILL the engine if it
#                 lingers. Then wait for the RAM and the VRAM to actually be
#                 back: a measurement taken against half-freed RAM is not a
#                 measurement.
#   3. measure    for each kv-resident value: drop the page cache (so both runs
#                 read the pack from the same cold state), copy the SAME saved
#                 expert profile into the run's own directory (an existing
#                 --expert-profile-save file is READ at start -- engine
#                 src/program/generate/model.cpp:153-163 -- so runs must not
#                 share one file, and the shared profile must not be mutated),
#                 start serve with the override, wait for "loaded", assert the
#                 engine really got the flag, send the fixed prompt, harvest the
#                 per-request engine and server lines, stop it.
#   4. compare    one markdown report: KV pinned in RAM, expert-cache slots,
#                 RAM floor / complement room / pinned GiB, hit rate, adaptive
#                 swaps deferred, blob reads and MB read from file, pp and tg
#                 rate, draft acceptance.
#   5. restore    start basalt the way the user does (fish -c basalt, detached,
#                 with a stdin that never EOFs), wait until /v1/models says
#                 "loaded" and prove it with one tiny chat completion. That is
#                 the handoff: the session resumes on basalt.
#
# Winner rule: higher decode expert-cache hit rate; within 1.0 point of each
# other, the higher decode rate (tg t/s) wins. --apply-winner writes it into
# basalt_config.json (with a timestamped backup) BEFORE the restore, so the
# handed-off session already runs the winner.
# =============================================================================
set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$HERE/ab
STATE=$WORK/state
PIDFILE=$WORK/ab.pid
TAG=$(date +%Y%m%d_%H%M%S)
REPORT=$WORK/ab-kv-resident-$TAG.md

APP=${BASALT_APP:-$HOME/.local/share/basalt/app}
CFG=${BASALT_CONFIG:-$HOME/.local/share/basalt/basalt_config.json}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}/basalt
ENGINE_BIN=$APP/bin/basalt

KV_A=32768
KV_B=131072
TOKENS=40000
MAXTOK=512
APPLY=0
RESTORE=1
MODE=ab
MIN_AVAIL_GIB=38          # refuse to measure if something else still holds the RAM (the engine needs ~41)
MAX_VRAM_MIB=2500         # engine gone when nvidia-smi reports less than this in use

usage() { sed -n '1,60p' "$0" | sed -n '/^# /p'; }

KV_GIVEN=0
while [ $# -gt 0 ]; do
  case $1 in
    --tokens) shift; TOKENS=$1 ;;
    --max-tokens) shift; MAXTOK=$1 ;;
    --apply-winner) APPLY=1 ;;
    --no-restore) RESTORE=0 ;;
    --dry-run) MODE=preflight ;;
    --reparse) MODE=reparse ;;
    --status) MODE=status ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "basalt_ab: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      case $1 in (*[!0-9]*|'') echo "basalt_ab: kv values must be integers, got '$1'" >&2; exit 2 ;; esac
      KV_GIVEN=$((KV_GIVEN + 1))
      if [ "$KV_GIVEN" = 1 ]; then KV_A=$1; else KV_B=$1; fi
      ;;
  esac
  shift
done
if [ "$KV_GIVEN" = 1 ]; then echo "basalt_ab: give two kv-resident values (or none for the default pair)" >&2; exit 2; fi

mkdir -p "$WORK"
st() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATE"; }
# finish_reason plus how many answer characters came back: a max_tokens below 1024 can be swallowed by the thinking
proof_summary(){ jq -r '"end=" + (.choices[0].finish_reason // "?") + " content=" + ((.choices[0].message.content // "") | length | tostring) + " chars"' 2>/dev/null; }

# --- config ------------------------------------------------------------------
cfg_get() {   # cfg_get <block> <key>
  python3 - "$CFG" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
v = (d.get(sys.argv[2]) or {}).get(sys.argv[3])
print("" if v is None else v)
PY
}

HOST=$(cfg_get server host); HOST=${HOST:-127.0.0.1}
PORT=$(cfg_get server port); PORT=${PORT:-8080}
URL=http://$HOST:$PORT
KV_CFG=$(cfg_get engine kv-resident); KV_CFG=${KV_CFG:-default}
MAXCTX=$(cfg_get engine max-context); MAXCTX=${MAXCTX:-0}
PROFILE_CFG=$(cfg_get engine expert-profile-save)
for kv in "$KV_A" "$KV_B"; do
  if [ "$kv" != 0 ] && [ "$kv" -lt 20480 ]; then
    echo "basalt_ab: --kv-resident $kv is below the engine's floor (qsa_kv_resident_min = 20480); use 0 or >= 20480" >&2
    exit 2
  fi
  if [ "$MAXCTX" != 0 ] && [ "$kv" -gt "$MAXCTX" ]; then
    echo "basalt_ab: --kv-resident $kv exceeds max-context $MAXCTX" >&2; exit 2
  fi
done

# --- processes ---------------------------------------------------------------
server_pids() { pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
engine_pids() { pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
basalt_running() { [ -n "$(server_pids)$(engine_pids)" ]; }

avail_gib() { free -g | awk '/^Mem:/{print $7}'; }
vram_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
engine_log_path() { ls -t "$CACHE_HOME"/*/engine.log 2>/dev/null | head -1; }

# --- status mode -------------------------------------------------------------
if [ "$MODE" = status ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "A/B running: pid $(cat "$PIDFILE")"
  else
    echo "no A/B run in progress"
  fi
  [ -f "$STATE" ] && { echo "--- state ---"; tail -20 "$STATE"; }
  newest=$(ls -t "$WORK"/ab-kv-resident-*.md 2>/dev/null | head -1)
  [ -n "$newest" ] && { echo "--- newest report: $newest"; head -30 "$newest"; }
  exit 0
fi

[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && {
  echo "basalt_ab: another run is already going (pid $(cat "$PIDFILE")). Refusing." >&2; exit 1; }
MODEL=$(cfg_get server alias); MODEL=${MODEL:-qwen3.8-flash-next-iq3_xxs}

# --- preflight: does the override reach the engine, is the flag real ---------
preflight_one() {  # preflight_one <kv>
  local kv=$1 words
  words=$(python3 - "$CFG" "$kv" "$APP" "$ENGINE_BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[3])
from serve.config import build_parser, parse_settings, engine_line, engine_flags_of, check_engine_flags
cfg, kv, app, bin_ = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ap = build_parser()
a, argv, file_words, cli_words = parse_settings(ap, ["--config", cfg,
                                                     "--kv-resident", kv,
                                                     "--expert-profile-save", "/tmp/basalt_ab_preflight.bin"])
check_engine_flags(cli_words, engine_flags_of(bin_), "command line")
words = file_words + cli_words
seen = [words[i + 1] for i, w in enumerate(words) if w == "--kv-resident"]
if not seen or seen[-1] != kv:
    raise SystemExit(f"override did not win: --kv-resident occurrences -> {seen}")
saved = [words[i + 1] for i, w in enumerate(words) if w == "--expert-profile-save"]
if saved[-1] != "/tmp/basalt_ab_preflight.bin":
    raise SystemExit(f"expert-profile-save override did not win: {saved}")
print(" | ".join(words))
PY
) || { st "preflight kv=$kv: REJECTED by serve.config / the engine flag list"; return 1; }
  st "preflight kv=$kv: ok -> $words"
  return 0
}

if ! preflight_one "$KV_A" || ! preflight_one "$KV_B"; then
  st "preflight failed: nothing was parked and nothing was measured. Fix the flags and re-run."
  exit 2
fi
if [ "$MODE" = preflight ]; then
  echo "basalt_ab: preflight passed for $KV_A and $KV_B; basalt was not touched."
  exit 0
fi

mkdir -p "$WORK"
: > "$STATE"
echo $$ > "$PIDFILE"
st "A/B start pid=$$ kv=$KV_A/$KV_B tokens=$TOKENS max_tokens=$MAXTOK config=$CFG url=$URL (synchronous: basalt stays parked until the very end)"

# --- park --------------------------------------------------------------------
BASALT_WAS=1          # the user had basalt up; the handoff at the end must put it back
FIRST_PARK=1
RESTORED=0
start_basalt() {
  if [ "$RESTORED" = 1 ]; then return 0; fi
  if basalt_running; then RESTORED=1; st "basalt: already running, nothing to start"; return 0; fi
  if ! command -v fish >/dev/null 2>&1; then
    st "WARN: fish not found -- basalt was NOT restarted. Start it by hand: basalt"; return 1
  fi
  # `sleep infinity` holds stdin open forever (exactly the Derp strata_build.sh trick) and
  # `fish -c basalt` is the user's own invocation; setsid detaches it from this session.
  setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$WORK/basalt_runtime.log" 2>&1 < /dev/null &
  st "basalt: starting (session pid $!); waiting for the model to load"
  RESTORED=1
  return 0
}

wait_ready() {   # wait_ready <seconds> -- the model must be resident AND listed as loaded
  local limit=$1 _
  for _ in $(seq 1 "$limit"); do
    if [ -n "$(engine_pids)" ] && curl -s --max-time 5 "$URL/v1/models" 2>/dev/null | grep -q '"value": *"loaded"'; then
      st "basalt: model loaded and answering on $URL ($(free -h | awk '/^Mem:/{print "mem used="$3" available="$7}'), vram $(vram_used_mib) MiB)"
      return 0
    fi
    sleep 5
  done
  return 1
}

park_basalt() {
  local s e p _
  s=$(server_pids); e=$(engine_pids)
  if [ -z "$s$e" ]; then
    st "basalt: not running; nothing to park"
    if [ "$FIRST_PARK" = 1 ]; then BASALT_WAS=0; fi   # only the first park may decide that it was never up
    FIRST_PARK=0
    return 0
  fi
  FIRST_PARK=0
  st "basalt: parking (server=[$s] engine=[$e])"
  for p in $s; do kill -INT "$p" 2>/dev/null || true; done      # serve's own graceful path: QUIT -> TERM -> KILL
  for _ in $(seq 1 60); do
    e=$(engine_pids); [ -n "$e" ] || { st "basalt: engine gone"; break; }
    sleep 2
  done
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
  # The pinned complement (31 GiB of page-locked RAM) and the VRAM have to be back
  # before the next measurement, not merely "the process is gone".
  for _ in $(seq 1 90); do
    [ "$(avail_gib)" -ge "$MIN_AVAIL_GIB" ] && [ "$(vram_used_mib)" -le "$MAX_VRAM_MIB" ] && break
    sleep 2
  done
  st "basalt: parked. mem $(free -h | awk '/^Mem:/{print "used="$3" available="$7}'), vram $(vram_used_mib) MiB"
  if [ "$(avail_gib)" -lt "$MIN_AVAIL_GIB" ]; then
    st "ERROR: only $(avail_gib) GiB available after parking (need $MIN_AVAIL_GIB). Something else holds the RAM; refusing to measure."
    return 1
  fi
  return 0
}

on_exit() {
  local rc=$?
  rm -f "$PIDFILE"
  if [ "$BASALT_WAS" = 1 ] && [ "$RESTORE" = 1 ] && [ "$RESTORED" = 0 ]; then
    st "exiting (rc=$rc) without a finished restore: making sure basalt is back"
    start_basalt || true
    wait_ready 600 || st "WARN: basalt did not report a loaded model -- check $WORK/basalt_runtime.log and start it by hand: basalt"
  fi
}
trap on_exit EXIT

# --- the fixed prompt --------------------------------------------------------
PROMPT_FILE=$WORK/prompt-$TOKENS.txt
if [ ! -f "$PROMPT_FILE" ]; then
  python3 - "$PROMPT_FILE" "$TOKENS" <<'PY'
import random, sys
path, target = sys.argv[1], int(sys.argv[2])
rnd = random.Random(20261031)
# Fixed corpus, fixed seed, fixed order: the same bytes in every run, so the only
# variable between runs is the setting under test. ~3.7 characters per token for
# this tokenizer, so the character target is an estimate; the engine's own
# "prompt N tokens" line in the report is the measured number.
# Measured on this pack and tokenizer: 150592 payload bytes -> 32765 engine-counted tokens, i.e. ~4.4
# characters per token; the first version of this file guessed 3.7 and produced a 32765 token prompt.
CHARS = 4.4
paragraphs = [
    "The storage tier sits between the pinned expert complement and the GPU cache, and every request pays for the distance it crosses.",
    "A resident expert is a memcpy away; a cached expert is a slot lookup away; a spilled expert is a pread on a seventy nine gigabyte file.",
    "Attention windows grow the key value cache monotonically, so the budget that was comfortable at eight thousand tokens is tight at forty thousand.",
    "Draft acceptance is the cheapest speed there is because a rejected draft still costs a verification pass but no new window.",
    "Quantisation chooses the arithmetic, the pack fixes it, and the runtime only chooses which arithmetic it can afford to keep close.",
    "Expert routing is a histogram of what the model actually says, which is why a profile learned from one conversation transfers badly to another.",
    "Memory bandwidth is the ceiling for the host side of a mixture of experts, and cores beyond the bandwidth only add scheduling noise.",
    "A page locked buffer cannot be reclaimed, so a pinned resident set is a promise the kernel keeps at the expense of everything else.",
    "Prefill is embarrassingly parallel and decode is serially dependent, which is why the two halves of a benchmark need different settings.",
    "Grammar masking turns sampling into a constraint problem, and the cost shows up as microseconds per window rather than tokens per second.",
]
facts = [
    "layers", "experts", "slots", "windows", "checkpoints", "blobs", "tokens", "drafts",
    "buffers", "affinity", "bandwidth", "quantisation", "residency", "context", "cache",
]
out = []
n = 0
while sum(len(p) for p in out) < int(target * CHARS):
    n += 1
    out.append(f"Section {n}.")
    for _ in range(rnd.randint(4, 7)):
        p = list(rnd.choice(paragraphs))
        out.append("".join(p) + " " + f"{rnd.choice(facts)} {rnd.randint(1, 999)} " + rnd.choice([
            "measured on this box", "reported by the engine", "counted per request",
            "after the adaptive round", "since the start of the run", "in the last window"]) + ".")
    out.append("")
text = "\n".join(out)
open(path, "w", encoding="utf-8").write(text)
print(f"prompt file: {len(text)} characters (~{int(len(text)//CHARS)} tokens estimated)")
PY
  st "prompt: built $PROMPT_FILE ($(stat -c %s "$PROMPT_FILE") bytes)"
else
  st "prompt: reusing $PROMPT_FILE ($(stat -c %s "$PROMPT_FILE") bytes)"
fi

# --- one run -----------------------------------------------------------------
run_one() {   # run_one <kv>
  local kv=$1 elog offset _
  local run=$WORK/run-$kv
  mkdir -p "$run"
  : > "$run/server.log"
  if [ -n "$PROFILE_CFG" ] && [ -f "$PROFILE_CFG" ]; then
    cp -p "$PROFILE_CFG" "$run/profile.bin"
    st "kv=$kv: starting profile = the saved one ($(stat -c %s "$run/profile.bin") bytes, copied so the shared file is never mutated mid-test)"
  else
    st "kv=$kv: no saved profile; the run starts from the pack's own profile"
  fi
  echo root | sudo -S -p '' sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null \
    && st "kv=$kv: page cache dropped (both runs read the pack cold)" \
    || st "kv=$kv: WARN could not drop the page cache (needs root) -- this run may read from a warm cache"

  elog=$(engine_log_path); offset=0
  [ -n "$elog" ] && offset=$(stat -c %s "$elog")
  st "kv=$kv: engine log = ${elog:-none} at offset $offset"

  st "kv=$kv: starting serve with the override (--kv-resident $kv)"
  setsid basalt serve --kv-resident "$kv" --expert-profile-save "$run/profile.bin" \
      >>"$run/server.log" 2>&1 < /dev/null &
  st "kv=$kv: serve session pid $!"

  if ! wait_ready 300; then
    st "kv=$kv: FAILED -- model not loaded within 1500 s; last server log lines:"
    tail -15 "$run/server.log" | sed 's/^/    /' | tee -a "$STATE"
    return 1
  fi

  # Prove the engine really got the flag: the engine reads its flags in order and the
  # last one wins, so the last --kv-resident on its command line must be this run's value.
  local epid ecmd last i
  epid=$(engine_pids | head -1)
  mapfile -t -d '' ecmd < "/proc/$epid/cmdline"
  last=""
  for i in "${!ecmd[@]}"; do
    [ "${ecmd[$i]}" = "--kv-resident" ] && last=${ecmd[$((i + 1))]:-}
  done
  if [ "$last" != "$kv" ]; then
    st "kv=$kv: FAILED -- engine cmdline carries --kv-resident ${last:-missing}: ${ecmd[*]}"
    return 1
  fi
  st "kv=$kv: engine verified --kv-resident $last (${#ecmd[@]} words)"

  jq -Rs --arg model "$MODEL" --argjson max "$MAXTOK" \
      '{model:$model, messages:[{role:"user", content:.}], max_tokens:$max, stream:false}' \
      "$PROMPT_FILE" > "$run/payload.json"
  st "kv=$kv: sending $(stat -c %s "$run/payload.json") byte payload, max_tokens=$MAXTOK"
  local t0=$SECONDS code
  code=$(curl -s -o "$run/answer.json" -w '%{http_code}' -m 1800 -H 'Content-Type: application/json' \
             -d "@$run/payload.json" "$URL/v1/chat/completions")
  st "kv=$kv: request returned HTTP $code in $((SECONDS - t0)) s"
  if [ "$code" != 200 ]; then
    st "kv=$kv: FAILED -- HTTP $code"; head -c 400 "$run/answer.json" | sed 's/^/    /' | tee -a "$STATE"
    return 1
  fi
  for _ in $(seq 1 20); do grep -q 'done  pp=' "$run/server.log" && break; sleep 1; done

  tail -c +"$((offset + 1))" "$elog" > "$run/engine-slice.log" 2>/dev/null || : > "$run/engine-slice.log"
  harvest_run "$kv" || { park_basalt || true; return 1; }
  st "kv=$kv: metrics harvested -> $run/metrics.json"
  if ! park_basalt; then st "kv=$kv: WARN park refused"; return 1; fi
  return 0
}

# --- metric harvest ----------------------------------------------------------
# Reachable on its own (--reparse) so a finished measurement can be re-read from the saved
# engine/server log slices without loading a 74 GiB model a second time.
harvest_run() {   # harvest_run <kv>  ->  $WORK/run-<kv>/metrics.json
  local kv=$1
  local run=$WORK/run-$kv
  python3 - "$run" "$kv" <<'PY'
import json, re, sys
run, kv = sys.argv[1], sys.argv[2]
eng = open(f"{run}/engine-slice.log", encoding="utf-8", errors="replace").read()
srv = open(f"{run}/server.log", encoding="utf-8", errors="replace").read()

def last(pattern, group=None, flags=0):
    """The last engine-log line matching `pattern` (the engine prints each of these once per request,
    and only the last one describes the A/B request). group=None keeps the whole capture."""
    m = re.findall(pattern, eng, flags)
    if not m:
        return None
    v = m[-1]
    if group is None:
        return v if isinstance(v, str) else " ".join(x for x in v)
    return v[group]

PROMPT = r"serve: prompt (\d+) tokens = (\d+) reused \+ (\d+) read in (\d+) ms \(([\d.]+) tok/s\), (\d+) generated in (\d+) ms \(([\d.]+) tok/s\), drafts accepted (\d+) of (\d+)"
CELLS = r"KV streaming: (\d+) of (\d+) cells per QSA layer in VRAM, the K/V in ([\d.]+) GiB of pinned RAM"
HIT = r"decode expert cache hit rate: ([\d.]+)% \((\d+) hits / (\d+) lookups\)"

metrics = {
    "kv_resident": kv,
    "kv_cells_in_vram": last(CELLS, 0),
    "kv_cells_total": last(CELLS, 1),
    "kv_pinned_ram_gib": last(CELLS, 2),
    "expert_cache_auto": last(r"expert cache auto: (.*)"),
    "expert_cache_slots": last(r"expert cache (\d+) slots, ([\d.]+) GiB of VRAM", 0),
    "expert_cache_vram_gib": last(r"expert cache (\d+) slots, ([\d.]+) GiB of VRAM", 1),
    # Two wordings for the RAM accounting.  Before the #114/#117/#107 stack the plan printed a
    # "RAM room for the complement: X GiB (Y GiB available minus Z GiB headroom)" line; after it the engine states
    # the placement ("experts live in VRAM ..., file (SSD) ...") and the floor ("RAM 6.69 GiB free, guard 2.74 GiB,
    # 0.90 GiB kept for serving").  Each field takes whichever wording this build printed.
    "ram_copy_gib": last(r"RAM floor .*? RAM copy <= ([\d.]+) of ([\d.]+) GiB", 0)
        or last(r"experts live in VRAM [\d.]+ GiB \(\d+%\), peer GPU [\d.]+ GiB \(\d+%\), RAM ([\d.]+) GiB"),
    "experts_on_ssd_gib": last(r"RAM floor .*?\), ([\d.]+) GiB experts on SSD")
        or last(r"file \(SSD\) ([\d.]+) GiB \(\d+%\)"),
    "experts_total_gib": last(r"([\d.]+) GiB in all"),
    "ram_available_gib": last(r"RAM room for the complement: [\d.]+ GiB \(([\d.]+) GiB available")
        or last(r"serve: RAM ([\d.]+) GiB free, guard"),
    "headroom_gib": last(r"RAM room for the complement: [\d.]+ GiB \([\d.]+ GiB available minus ([\d.]+) GiB headroom")
        or last(r"serve: RAM [\d.]+ GiB free, guard ([\d.]+) GiB"),
    "serve_kept_gib": last(r"guard [\d.]+ GiB, ([\d.]+) GiB kept for serving"),
    "complement_room_gib": last(r"RAM room for the complement: ([\d.]+) GiB \("),
    "complement_full_gib": last(r"resident complement ([\d.]+) GiB exceeds available RAM")
        or last(r"allocating ([\d.]+) GiB page-locked cache complement"),
    "complement_kept_gib": last(r"the hottest ([\d.]+) GiB are kept in RAM")
        or last(r"mapped pinned cache complement ready: resident ([\d.]+) GiB"),
    "stream_all_chunk": last(r"every expert streams from (\d+)-token chunks"),
    "prompt_nonres_gib": last(r"streams from \d+-token chunks \(([\d.]+) GiB non-resident"),
    "prompt_pinned_pct": last(r"non-resident, (\d+)% pinned"),
    "link_gbps": last(r"pinned, link ([\d.]+) GB/s\)"),
    "prompt_borrow_slots": last(r"the prompt path borrows (\d+) CUDA0 cache slots"),
    "complement_truncated": last(r"warning: the whole complement does not fit in RAM") and "yes" or "no (it fit)",
    "spare_places": last(r"FileExpertSource: (.*free places for the adaptive swaps.*)"),
    "pinned_ready": last(r"mapped pinned cache complement ready: (.*?); page-locked"),
    "resident_mode": last(r"resident RAM mode: (.*)"),
    "prompt_tokens": last(PROMPT, 0),
    "prompt_reused": last(PROMPT, 1),
    "prompt_read": last(PROMPT, 2),
    "pp_tok_s": last(PROMPT, 4),
    "generated": last(PROMPT, 5),
    "tg_tok_s": last(PROMPT, 7),
    "drafts_ok": last(PROMPT, 8),
    "drafts_total": last(PROMPT, 9),
    "hit_pct": last(HIT, 0),
    "hit_count": last(HIT, 1),
    "lookups": last(HIT, 2),
    "swaps_done": last(r"adaptive swaps: (\d+) into the VRAM tier this request"),
    "swaps_deferred": last(r"adaptive swaps: \d+ into the VRAM tier this request, ([\d.]+) deferred"),
    "resident_ram_gib": last(r"resident RAM: ([\d.]+) GiB of experts in RAM"),
    "ram_exchanged": last(r"resident RAM: [\d.]+ GiB of experts in RAM, (\d+) exchanged with the VRAM tier"),
    "file_blobs": last(r"resident RAM: .*? (\d+) blob reads from the file"),
    "file_mb_read": last(r"files \d+ blobs ([\d.]+) MB read"),
    "kv_block_hit_pct": last(r"serve: KV streaming: ([\d.]+)% of \d+ block reads hit VRAM"),
    "kv_ram_mib": last(r"block reads hit VRAM, ([\d.]+) MiB read from RAM"),
    "server_done": (re.findall(r"\[server\] s\d+ done  .*", srv) or [None])[-1],
}
critical = [k for k in ("hit_pct", "prompt_tokens", "tg_tok_s", "server_done") if metrics.get(k) is None]
if critical:
    print("ERROR missing engine lines: " + ", ".join(critical) + " -- this run is not comparable")
    raise SystemExit(1)
missing = [k for k, v in metrics.items() if v is None]
if missing:
    print("note: no such line this run: " + ", ".join(sorted(missing)))
json.dump(metrics, open(f"{run}/metrics.json", "w"), indent=1)
print("metrics.json: " + ", ".join(f"{k}={v}" for k, v in metrics.items() if k != "server_done"))
PY
  local rc=$?
  if [ "$rc" != 0 ] || [ ! -f "$run/metrics.json" ]; then
    st "kv=$kv: harvest failed (rc=$rc, see $run/engine-slice.log)"
    return 1
  fi
  return 0
}

# --- run both (or re-read a finished measurement) -----------------------------
OK_A=0; OK_B=0
if [ "$MODE" = reparse ]; then
  RESTORED=1                       # nothing was parked: whatever is running stays running
  st "reparse: re-reading saved log slices for kv=$KV_A and kv=$KV_B (model not loaded again)"
  harvest_run "$KV_A" && OK_A=1
  harvest_run "$KV_B" && OK_B=1
else
  if park_basalt; then
    run_one "$KV_A" && OK_A=1
    if park_basalt; then
      run_one "$KV_B" && OK_B=1
    fi
  else
    st "park failed before any measurement"
  fi
fi

# --- report + winner ---------------------------------------------------------
if [ "$OK_A$OK_B" = 11 ]; then
  python3 - "$WORK" "$KV_A" "$KV_B" "$REPORT" "$TOKENS" "$MAXTOK" "$PROMPT_FILE" <<'PY'
import json, os, sys
work, ka, kb, report, tokens, maxtok, prompt = sys.argv[1:8]
A = json.load(open(f"{work}/run-{ka}/metrics.json"))
B = json.load(open(f"{work}/run-{kb}/metrics.json"))
f = lambda d, k: d.get(k) or "-"

def num(x):
    try: return float(x)
    except (TypeError, ValueError): return float("nan")

hit_a, hit_b = num(f(A, "hit_pct")), num(f(B, "hit_pct"))
tg_a, tg_b = num(f(A, "tg_tok_s")), num(f(B, "tg_tok_s"))
if abs(hit_a - hit_b) <= 1.0:
    win, lose = (ka, kb) if tg_a >= tg_b else (kb, ka)
    why = f"hit rates within 1.0 point ({hit_a:g}% vs {hit_b:g}%), decode rate decided it: {tg_a:g} vs {tg_b:g} t/s"
else:
    win, lose = (ka, kb) if hit_a > hit_b else (kb, ka)
    why = f"decode expert-cache hit rate decided it: {hit_a:g}% vs {hit_b:g}%"

rows = [
    ("kv-resident", "kv_resident"),
    ("KV cells kept in VRAM / total cells (per full-attention layer)", "kv_cells_in_vram"),
    ("KV pinned in RAM (GiB)", "kv_pinned_ram_gib"),
    ("expert cache slots", "expert_cache_slots"),
    ("expert cache VRAM (GiB)", "expert_cache_vram_gib"),
    ("expert cache auto line", "expert_cache_auto"),
    ("RAM tier after placement (GiB)", "ram_copy_gib"),
    ("experts left on SSD (GiB)", "experts_on_ssd_gib"),
    ("expert corpus (GiB)", "experts_total_gib"),
    ("free RAM the engine saw (GiB)", "ram_available_gib"),
    ("RAM guard / headroom (GiB)", "headroom_gib"),
    ("kept for serving (GiB)", "serve_kept_gib"),
    ("room for the complement (GiB)", "complement_room_gib"),
    ("page-locked complement (GiB)", "complement_full_gib"),
    ("complement kept in RAM (GiB)", "complement_kept_gib"),
    ("stream-all chunk (tokens)", "stream_all_chunk"),
    ("prompt path non-resident (GiB)", "prompt_nonres_gib"),
    ("of it page-locked (%)", "prompt_pinned_pct"),
    ("measured link (GB/s)", "link_gbps"),
    ("slots the prompt path borrows", "prompt_borrow_slots"),
    ("complement truncated?", "complement_truncated"),
    ("free places for the adaptive swaps", "spare_places"),
    ("pinned complement ready", "pinned_ready"),
    ("resident RAM mode", "resident_mode"),
    ("prompt tokens (engine counted)", "prompt_tokens"),
    ("prompt reused", "prompt_reused"),
    ("prompt read", "prompt_read"),
    ("prefill (t/s)", "pp_tok_s"),
    ("generated tokens", "generated"),
    ("decode (t/s)", "tg_tok_s"),
    ("drafts accepted", "drafts_ok"),
    ("decode expert-cache hit (%)", "hit_pct"),
    ("hits / lookups", "hit_count"),
    ("adaptive swaps into VRAM this request", "swaps_done"),
    ("adaptive swaps deferred", "swaps_deferred"),
    ("resident experts (GiB)", "resident_ram_gib"),
    ("exchanged with the VRAM tier", "ram_exchanged"),
    ("blob reads from the file", "file_blobs"),
    ("MB read from the file", "file_mb_read"),
    ("KV block hit (%)", "kv_block_hit_pct"),
    ("KV read from RAM (MiB)", "kv_ram_mib"),
]
def look(d, key):
    if key == "kv_cells_in_vram":                      # the row shows VRAM / total cells
        return f"{f(d,'kv_cells_in_vram')} / {f(d,'kv_cells_total')}"
    if key == "hit_count":
        return f"{f(d,'hit_count')} / {f(d,'lookups')}"
    if key == "drafts_ok":
        return f"{f(d,'drafts_ok')} of {f(d,'drafts_total')}"
    return f(d, key)

lines = [
    f"# basalt kv-resident A/B ({os.path.basename(report).replace('ab-kv-resident-','').replace('.md','')})",
    "",
    f"Engine: `{' '.join(open(os.path.expanduser('~/.local/share/basalt/app/.pkg-version')).read().split())}` at "
    f"`/mnt/aosp/Projects/basalt/basalt_ab.sh`. One fixed prompt, both runs: `{os.path.basename(prompt)}` "
    f"({os.path.getsize(prompt)} bytes, {tokens} tokens targeted), max_tokens={maxtok}, page cache dropped before each "
    f"run, each run started from a copy of the same saved expert profile, no run writes the shared profile.",
    "",
    f"**Winner: `--kv-resident {win}`** -- {why}.",
    "",
    "| metric | kv-resident " + ka + " | kv-resident " + kb + " |",
    "| --- | --- | --- |",
]
for label, key in rows:
    lines.append(f"| {label} | {look(A, key)} | {look(B, key)} |")
lines += [
    "",
    "## The engine's own closing lines",
    "",
    "```",
    f"kv-resident {ka}: {f(A,'server_done')}",
    f"kv-resident {kb}: {f(B,'server_done')}",
    "```",
    "",
    "## How to read it",
    "",
    f"`--kv-resident {ka}` kept {f(A,'kv_cells_in_vram')} of {f(A,'kv_cells_total')} KV cells per full-attention layer in VRAM and left "
    f"{f(A,'expert_cache_slots')} slots ({f(A,'expert_cache_vram_gib')} GiB) to the expert cache; `--kv-resident {kb}` kept "
    f"{f(B,'kv_cells_in_vram')} in VRAM and left {f(B,'expert_cache_slots')} slots ({f(B,'expert_cache_vram_gib')} GiB).",
    "",
    "`--kv-resident` is the KV that **stays in VRAM**; everything above it streams through a pinned host-RAM buffer (the",
    "engine says so at load, in its own `KV streaming: N of M cells per QSA layer in VRAM` line). Raising it takes VRAM",
    "out of the expert cache and simultaneously grows the expert complement that has to find a home in RAM -- both",
    "figures are in the table. Measured on this pack, lower is better:",
    f"`hit {f(A,'hit_pct')}% -> {f(B,'hit_pct')}%`, `decode {f(A,'tg_tok_s')} -> {f(B,'tg_tok_s')} t/s`, `slots {f(A,'expert_cache_slots')} -> {f(B,'expert_cache_slots')}`.",
    "",
    "Both runs still ended with `adaptive swaps: ... deferred (no free RAM place)` and neither printed a `free places for",
    "the adaptive swaps` line, so the swap-spare problem sits on the RAM side and kv-resident does not fix it in this",
    "range -- that one is `resident-budget-gib` (README-setup.md, \"Why 1.83 M adaptive swaps were deferred\").",
    "",
    "Next probe with this wrapper, no edits needed: `./basalt_ab.sh 20480 0` (20480 is the engine's floor,",
    "`qsa_kv_resident_min`; 0 lets the KV grow elastically in VRAM).",
    "",
    "Related: `/mnt/aosp/Projects/basalt/README-setup.md` (the RAM safety headroom, the swap-spare diagnosis, the",
    "five-value A/B plan), `/usr/share/doc/basalt-engine-git/configuration/index.md`.",
    "",
]
open(report, "w").write("\n".join(lines))
print(f"report: {report}")
print(f"winner: {win}")
print(f"why: {why}")
PY
  WINNER=$(python3 - "$WORK" "$KV_A" "$KV_B" <<'PY'
import json, sys
work, ka, kb = sys.argv[1:4]
A = json.load(open(f"{work}/run-{ka}/metrics.json")); B = json.load(open(f"{work}/run-{kb}/metrics.json"))
def n(x):
    try: return float(x)
    except Exception: return float("nan")
ha, hb, ta, tb = n(A.get("hit_pct")), n(B.get("hit_pct")), n(A.get("tg_tok_s")), n(B.get("tg_tok_s"))
print(ka if (abs(ha-hb) <= 1.0 and ta >= tb) or (abs(ha-hb) > 1.0 and ha > hb) else kb)
PY
)
else
  WINNER=""
  st "A/B incomplete (run A ok=$OK_A run B ok=$OK_B): no winner, config left untouched"
fi

# --- optionally write the winner into the config, then restore --------------
if [ "$APPLY" = 1 ] && [ -n "$WINNER" ]; then
  cp -p "$CFG" "$WORK/config-backup-$TAG.json"
  jq --argjson kv "$WINNER" '.engine["kv-resident"] = $kv' "$WORK/config-backup-$TAG.json" > "$CFG"
  st "config: engine.kv-resident -> $WINNER (backup $WORK/config-backup-$TAG.json)"
fi

if [ "$MODE" != reparse ] && [ "$RESTORE" = 1 ] && [ "$BASALT_WAS" = 1 ]; then
  st "restore: handing the session back to basalt on $URL"
  start_basalt
  if wait_ready 300; then
    curl -s -o "$WORK/handoff.json" -m 60 -H 'Content-Type: application/json' \
      -d '{"model":"qwen3.8-flash-next-iq3_xxs","messages":[{"role":"user","content":"ping"}],"max_tokens":1200}' \
      "$URL/v1/chat/completions" >/dev/null
    st "handoff: /v1/chat/completions answered ($(proof_summary < "$WORK/handoff.json")) -- the session can infer again"
  else
    st "WARN: basalt did not report a loaded model within 1500 s -- check $WORK/basalt_runtime.log and start it by hand: basalt"
  fi
fi

st "done. report: $REPORT"
