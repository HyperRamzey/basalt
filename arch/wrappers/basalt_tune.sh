#!/usr/bin/env bash
# =============================================================================
# basalt_tune.sh -- park basalt, run ONE growing multi-turn transcript through
#                   several engine-flag settings, compare them, restore basalt.
#
#   basalt_tune.sh [--arm 'label|--flag VALUE ...']... [options]
#                  [--turns N] [--tokens N] [--max-tokens N] [--apply LABEL]
#                  [--no-restore] [--dry-run] [--status] [--reparse]
#
# Arms repeat (1..4).  With no --arm the default three are the agentic-coding
# questions this rig actually has:
#     incumbent|                              what basalt_config.json already says
#     adapt|--adapt-decay 0.85 --adapt-swaps 256
#     cache|--prompt-cache 6 --prompt-cache-every 8192
#
# WHY A GROWING TRANSCRIPT AND NOT ONE LONG PROMPT
# An agentic coding session is not one 32 K prompt: it is the same prefix re-sent
# with a new turn on the end, dozens of times.  What decides the feel of such a
# session is how much of each re-send the engine can take from its conversation
# checkpoints instead of re-reading, and how fast the decode runs once the prompt
# is in.  So turn 1 is the long prompt; turn k > 1 is that prompt plus a fixed
# scripted assistant reply and a fixed user follow-up.  The scripted replies are
# identical in every arm - the model's own output is never fed back - so the only
# thing that differs between arms is the setting under test, and "N reused + M
# read" is comparable turn by turn.
#
# WHY A WRAPPER (same contract as Derp's hm_mod/strata_build.sh, pointer:
# Derp/AGENTS.md "Building -- permanent rule while strata is running")
# This host's local LLM serves THIS agent session (qwen3.8-flash-next-iq3_xxs on
# 127.0.0.1:8080), and basalt answers that port.  Parking it kills the session's
# own inference, so the run is SYNCHRONOUS: preflight, park, measure every arm,
# restore, wait until /v1/models says "loaded", prove one tiny completion, return.
#
# Fairness rules (the ones the kv-resident A/B already uses, restated):
#   - the same bytes per turn index in every arm (scripted transcript, fixed seed);
#   - page cache dropped before every arm, so each reads the pack equally cold;
#   - a COPY of the saved expert profile per arm (--expert-profile-save is read at
#     start, and the shared file must never be mutated by a test);
#   - RAM and VRAM actually released (not just the process gone) before the next arm;
#   - the engine's own command line is checked for the arm's flags before measuring;
#   - the config file is only touched with --apply LABEL, and then with a backup.
# =============================================================================
set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$HERE/tune
STATE=$WORK/state
PIDFILE=$WORK/tune.pid
TAG=$(date +%Y%m%d_%H%M%S)
REPORT=$WORK/tune-$TAG.md

APP=${BASALT_APP:-$HOME/.local/share/basalt/app}
CFG=${BASALT_CONFIG:-$HOME/.local/share/basalt/basalt_config.json}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}/basalt
ENGINE_BIN=$APP/bin/basalt

ARMS=()
TURNS=4
RESTART_AT=0            # >0: restart the engine before this turn - what survives a restart is the disk tier's job
TOKENS=40000
MAXTOK=512
APPLY_LABEL=""
RESTORE=1
MODE=run
MIN_AVAIL_GIB=38          # refuse to measure if something else still holds the RAM (~41 needed)

usage() { sed -n '1,60p' "$0" | sed -n '/^# /p'; }

while [ $# -gt 0 ]; do
  case $1 in
    --arm) shift; ARMS+=("$1") ;;
    --turns) shift; TURNS=$1 ;;
    --restart-at) shift; RESTART_AT=$1 ;;
    --tokens) shift; TOKENS=$1 ;;
    --max-tokens) shift; MAXTOK=$1 ;;
    --apply) shift; APPLY_LABEL=$1 ;;
    --no-restore) RESTORE=0 ;;
    --dry-run) MODE=preflight ;;
    --reparse) MODE=reparse ;;
    --status) MODE=status ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "basalt_tune: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "basalt_tune: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ${#ARMS[@]} -eq 0 ]; then
  ARMS=("incumbent|" "adapt|--adapt-decay 0.85 --adapt-swaps 256" \
        "cache|--prompt-cache 6 --prompt-cache-every 8192")
fi
if [ ${#ARMS[@]} -gt 4 ]; then echo "basalt_tune: at most four arms" >&2; exit 2; fi

# label|flags  ->  LABELS[i] (safe for paths) and FLAGS[i] (an array of words)
LABELS=(); FLAGLIST=()
for a in "${ARMS[@]}"; do
  case $a in
    *\|*) label=${a%%|*}; flags=${a#*|} ;;
    *)    echo "basalt_tune: an arm is 'label|--flag VALUE ...', got '$a'" >&2; exit 2 ;;
  esac
  case $label in (*[!A-Za-z0-9._-]*|'') echo "basalt_tune: bad arm label '$label' (A-Za-z0-9._- only)" >&2; exit 2 ;; esac
  for l in "${LABELS[@]}"; do [ "$l" = "$label" ] && { echo "basalt_tune: duplicate arm label '$label'" >&2; exit 2; }; done
  LABELS+=("$label"); FLAGLIST+=("$flags")
done

mkdir -p "$WORK"
st() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATE"; }
# finish_reason plus how many answer characters came back: a max_tokens below 1024 can be swallowed by the thinking
proof_summary(){ jq -r '"end=" + (.choices[0].finish_reason // "?") + " content=" + ((.choices[0].message.content // "") | length | tostring) + " chars"' 2>/dev/null; }

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
MODEL=$(cfg_get server alias); MODEL=${MODEL:-qwen3.8-flash-next-iq3_xxs}
PROFILE_CFG=$(cfg_get engine expert-profile-save)

arm_flags() {   # arm_flags <index> -> the arm's extra words, one per line
  local f=${FLAGLIST[$1]} w
  for w in $f; do [ -n "$w" ] && printf '%s\n' "$w"; done
}

server_pids() { pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
engine_pids() { pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
basalt_running() { [ -n "$(server_pids)$(engine_pids)" ]; }
avail_gib() { free -g | awk '/^Mem:/{print $7}'; }
vram_used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
engine_log_path() { ls -t "$CACHE_HOME"/*/engine.log 2>/dev/null | head -1; }
run_dir() { echo "$WORK/arm-${LABELS[$1]}"; }

if [ "$MODE" = status ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "tune run in progress: pid $(cat "$PIDFILE")"
  else
    echo "no tune run in progress"
  fi
  [ -f "$STATE" ] && { echo "--- state ---"; tail -20 "$STATE"; }
  newest=$(ls -t "$WORK"/tune-*.md 2>/dev/null | head -1)
  [ -n "$newest" ] && { echo "--- newest report: $newest"; head -40 "$newest"; }
  exit 0
fi

[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && {
  echo "basalt_tune: another run is already going (pid $(cat "$PIDFILE")). Refusing." >&2; exit 1; }

# --- preflight: is every flag real, and does it win over the config file? ----
preflight_arm() {   # preflight_arm <index>
  local i=$1 words
  words=$(python3 - "$CFG" "$APP" "$ENGINE_BIN" "${FLAGLIST[$i]}" "${LABELS[$i]}" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from serve.config import build_parser, parse_settings, check_engine_flags, engine_flags_of
cfg, app, bin_, arm, label = sys.argv[1:6]
arm_words = arm.split()
ap = build_parser()
probe = "/tmp/basalt_tune_preflight.bin"
a, argv, file_words, cli_words = parse_settings(ap, ["--config", cfg] + arm_words +
                                                ["--expert-profile-save", probe])
check_engine_flags(cli_words, engine_flags_of(bin_), "command line")
words = file_words + cli_words
# The engine takes the LAST word of each name, so an arm flag must be the last one.
j = 0
while j < len(arm_words):
    w = arm_words[j]
    if not w.startswith("--"):
        j += 1; continue
    seen = [words[k + 1] for k, t in enumerate(words) if t == w]
    if not seen:
        raise SystemExit(f"{label}: {w} never reached the engine line")
    if j + 1 < len(arm_words) and not arm_words[j + 1].startswith("--"):
        if seen[-1] != arm_words[j + 1]:
            raise SystemExit(f"{label}: {w} -> {seen[-1]}, expected {arm_words[j+1]}")
        j += 2
    else:
        j += 1
saved = [words[k + 1] for k, t in enumerate(words) if t == "--expert-profile-save"]
if saved[-1] != probe:
    raise SystemExit(f"{label}: the profile-copy override did not win ({saved[-1]})")
print(" | ".join(words))
PY
) || { st "preflight ${LABELS[$i]}: REJECTED by serve.config or the engine's flag list"; return 1; }
  st "preflight ${LABELS[$i]}: ok -> $words"
  return 0
}

for i in "${!LABELS[@]}"; do preflight_arm "$i" || {
  st "preflight failed for ${LABELS[$i]}: basalt was not touched, nothing measured."; exit 2; }
done
if [ "$MODE" = preflight ]; then
  echo "basalt_tune: preflight passed for ${LABELS[*]}; basalt was not touched."; exit 0
fi

# --- the scripted transcript --------------------------------------------------
# Turn 1 is the long prompt file.  Turn k adds a fixed assistant block and a fixed
# user block per earlier turn: same bytes in every arm, and the model's own answer
# is never fed back, so a cache win is a cache win and not a different conversation.
PROMPT_FILE=$WORK/prompt-$TOKENS.txt
if [ ! -f "$PROMPT_FILE" ]; then
  python3 - "$PROMPT_FILE" "$TOKENS" <<'PY'
import random, sys
path, target = sys.argv[1], int(sys.argv[2])
rnd = random.Random(20261031)
CHARS = 4.4          # measured: 150592 payload bytes -> 32765 engine tokens
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
facts = ["layers", "experts", "slots", "windows", "checkpoints", "blobs", "tokens", "drafts",
         "buffers", "affinity", "bandwidth", "quantisation", "residency", "context", "cache"]
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
open(path, "w", encoding="utf-8").write("\n".join(out))
PY
  st "prompt: built $PROMPT_FILE ($(stat -c %s "$PROMPT_FILE") bytes)"
else
  st "prompt: reusing $PROMPT_FILE ($(stat -c %s "$PROMPT_FILE") bytes)"
fi

if [ ! -f "$WORK/transcript.py" ]; then
  cat > "$WORK/transcript.py" <<'PY'
"""Build turn k of the scripted transcript: the long prompt, then (k-1) fixed
assistant/user exchanges.  Deterministic: the same bytes for the same k in every arm."""
import json, sys
path, turn, maxtok, model = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
base = open(path, encoding="utf-8").read()
REPLY = ("Applied. The change is in the tier that owns the copy: the borrow is sized before the "
         "slots are handed out, the place list is checked against the pinned complement, and the "
         "deferred count is reported instead of guessed. Nothing in the arithmetic moved, the "
         "profile keeps its learned placement, and the run reports the same answers as before.\n"
         "Diff summary: two call sites updated, one helper extracted, one warning added when the "
         "free places run out, one test extended to cover a chunk that is smaller than a page.\n")
FOLLOW = ("Now re-read the same file and check the second call site: does it take the same size, "
          "and what does it do when the list is empty? Answer with the call and the size.\n")
msgs = [{"role": "user", "content": base}]
for k in range(1, turn):
    msgs.append({"role": "assistant", "content": REPLY * (2 + (k % 3))})
    msgs.append({"role": "user", "content": FOLLOW + f"Follow-up {k}.\n"})
json.dump({"model": model, "messages": msgs, "max_tokens": maxtok, "stream": False},
          sys.stdout, ensure_ascii=False)
PY
fi
payload_for() {   # payload_for <turn> -> json on stdout
  python3 "$WORK/transcript.py" "$PROMPT_FILE" "$1" "$MAXTOK" "$MODEL"
}

# --- park / restore (the same machinery the kv-resident A/B uses) -------------
BASALT_WAS=1
FIRST_PARK=1
RESTORED=0
start_basalt() {
  if [ "$RESTORED" = 1 ]; then return 0; fi
  if basalt_running; then RESTORED=1; st "basalt: already running, nothing to start"; return 0; fi
  if ! command -v fish >/dev/null 2>&1; then
    st "WARN: fish not found -- basalt was NOT restarted. Start it by hand: basalt"; return 1
  fi
  setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$WORK/basalt_runtime.log" 2>&1 < /dev/null &
  st "basalt: starting (session pid $!); waiting for the model to load"
  RESTORED=1
  return 0
}

wait_ready() {   # wait_ready <seconds>
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
    if [ "$FIRST_PARK" = 1 ]; then BASALT_WAS=0; fi
    FIRST_PARK=0
    return 0
  fi
  FIRST_PARK=0
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
    [ "$(avail_gib)" -ge "$MIN_AVAIL_GIB" ] && [ "$(vram_used_mib)" -le 2500 ] && break
    sleep 2
  done
  st "basalt: parked. mem $(free -h | awk '/^Mem:/{print "used="$3" available="$7}'), vram $(vram_used_mib) MiB"
  if [ "$(avail_gib)" -lt "$MIN_AVAIL_GIB" ]; then
    st "ERROR: only $(avail_gib) GiB available after parking (need $MIN_AVAIL_GIB); refusing to measure."
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
    wait_ready 600 || st "WARN: basalt did not report a loaded model -- start it by hand: basalt"
  fi
}
trap on_exit EXIT

# --- one arm ------------------------------------------------------------------
# Start serve for the current arm and prove the engine really carries its flags.  Used at the start of
# an arm and again after a --restart-at restart, so both halves of an arm are measured the same way.
CUR_RUN=""; CUR_LABEL=""; CUR_FLAGS=()
start_and_verify() {
  if [ ${#CUR_FLAGS[@]} -gt 0 ]; then st "arm $CUR_LABEL: starting serve with ${CUR_FLAGS[*]}"; else st "arm $CUR_LABEL: starting serve with no extra flags"; fi
  # Each arm gets its own parked-conversation directory.  The disk tier (PR #149) writes
  # ~/.cache/basalt/<model hash>/conversations/*.bcs, and an arm that started with another arm's parked
  # conversation sitting there would read it back at the first turn: the comparison would measure the
  # previous arm, not this setting.
  setsid basalt serve ${CUR_FLAGS[@]+"${CUR_FLAGS[@]}"} --expert-profile-save "$CUR_RUN/profile.bin" \
      --conversation-cache-dir "$CUR_RUN/conversations" >>"$CUR_RUN/server.log" 2>&1 < /dev/null &
  st "arm $CUR_LABEL: serve session pid $!"
  if ! wait_ready 300; then
    st "arm $CUR_LABEL: FAILED -- model not loaded; last server log lines:"
    tail -15 "$CUR_RUN/server.log" | sed 's/^/    /' | tee -a "$STATE"
    return 1
  fi
  local epid ecmd last j w
  epid=$(engine_pids | head -1)
  mapfile -t -d '' ecmd < "/proc/$epid/cmdline"
  j=0
  while [ $j -lt ${#CUR_FLAGS[@]} ]; do
    w=${CUR_FLAGS[$j]}
    case $w in --*) ;; *) j=$((j + 1)); continue ;; esac
    last=""
    for k in "${!ecmd[@]}"; do [ "${ecmd[$k]}" = "$w" ] && last=${ecmd[$((k + 1))]:-}; done
    nxt=""
    [ $((j + 1)) -lt ${#CUR_FLAGS[@]} ] && nxt=${CUR_FLAGS[$((j + 1))]}
    case $nxt in --*) nxt="" ;; esac
    if [ -n "$nxt" ]; then
      [ "$last" != "$nxt" ] && { st "arm $CUR_LABEL: FAILED -- engine has $w ${last:-missing}, wanted $nxt"; return 1; }
      j=$((j + 2))
    else
      case "$w" in --*) case " ${ecmd[*]} " in *" $w "*) ;; *) st "arm $CUR_LABEL: FAILED -- $w missing from the engine cmdline"; return 1 ;; esac ;; esac
      j=$((j + 1))
    fi
  done
  last=""
  for k in "${!ecmd[@]}"; do [ "${ecmd[$k]}" = "--conversation-cache-dir" ] && last=${ecmd[$((k + 1))]:-}; done
  [ "$last" != "$CUR_RUN/conversations" ] &&
      { st "arm $CUR_LABEL: FAILED -- engine parks conversations in ${last:-nowhere}, wanted $CUR_RUN/conversations"; return 1; }
  st "arm $CUR_LABEL: engine verified (${#ecmd[@]} words, conversations in $CUR_RUN/conversations)"
  return 0
}

run_arm() {   # run_arm <index>
  local i=$1 label=${LABELS[$i]} run elog offset code t0
  local -a flags=()
  while IFS= read -r w; do [ -n "$w" ] && flags+=("$w"); done < <(arm_flags "$i")
  run=$(run_dir "$i"); mkdir -p "$run"; : > "$run/server.log"
  # A repeat of a label must not inherit the previous run's parked conversations, or the arm starts warm and the
  # comparison measures the earlier run's disk tier instead of this setting (that is what inflated a spec10 arm).
  rm -rf "$run/conversations"
  CUR_RUN=$run; CUR_LABEL=$label; CUR_FLAGS=(${flags[@]+"${flags[@]}"})

  if [ -n "$PROFILE_CFG" ] && [ -f "$PROFILE_CFG" ]; then
    cp -p "$PROFILE_CFG" "$run/profile.bin"
    st "arm $label: starting profile = the saved one ($(stat -c %s "$run/profile.bin") bytes, copied; the shared file is never mutated)"
  else
    st "arm $label: no saved profile; the run starts from the pack's own profile"
  fi
  echo root | sudo -S -p '' sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null \
    && st "arm $label: page cache dropped (every arm reads the pack equally cold)" \
    || st "arm $label: WARN could not drop the page cache (needs root)"

  elog=$(engine_log_path); offset=0
  [ -n "$elog" ] && offset=$(stat -c %s "$elog")
  st "arm $label: engine log = ${elog:-none} at offset $offset"

  start_and_verify || return 1

  local t=1
  while [ "$t" -le "$TURNS" ]; do
    if [ "$RESTART_AT" -gt 0 ] && [ "$t" = "$RESTART_AT" ]; then
      # A coding session survives an engine restart (a package upgrade, a crash).  This is the arm
      # variable that asks the question: what does the conversation cost after the process is gone?
      st "arm $label: --restart-at $t: parking the engine, then starting the same arm again"
      park_basalt || return 1
      start_and_verify || return 1
    fi
    payload_for "$t" > "$run/payload-$t.json"
    t0=$SECONDS
    code=$(curl -s -o "$run/answer-$t.json" -w '%{http_code}' -m 2400 -H 'Content-Type: application/json' \
               -d "@$run/payload-$t.json" "$URL/v1/chat/completions")
    st "arm $label: turn $t ($(stat -c %s "$run/payload-$t.json") bytes) HTTP $code in $((SECONDS - t0)) s"
    if [ "$code" != 200 ]; then
      st "arm $label: FAILED at turn $t -- HTTP $code"; head -c 300 "$run/answer-$t.json" | sed 's/^/    /' | tee -a "$STATE"
      return 1
    fi
    for _ in $(seq 1 30); do [ "$(grep -c 'done  pp=' "$run/server.log")" -ge "$t" ] && break; sleep 1; done
    t=$((t + 1))
  done

  # The engine's own per-request line lands just after the server's terminal line; take the slice only
  # once every turn has one, otherwise the last turn is measured from the server side alone.
  for _ in $(seq 1 40); do
    [ "$(tail -c +"$((offset + 1))" "$elog" 2>/dev/null | grep -c 'serve: prompt .* tokens = ')" -ge "$TURNS" ] && break
    sleep 1
  done

  tail -c +"$((offset + 1))" "$elog" > "$run/engine-slice.log" 2>/dev/null || : > "$run/engine-slice.log"
  harvest_arm "$i" || { park_basalt || true; return 1; }
  st "arm $label: metrics harvested -> $run/metrics.json"
  if ! park_basalt; then st "arm $label: WARN park refused"; return 1; fi
  return 0
}

# --- harvest ------------------------------------------------------------------
harvest_arm() {   # harvest_arm <index> -> <run dir>/metrics.json
  local i=$1 run label
  run=$(run_dir "$i"); label=${LABELS[$i]}
  python3 - "$run" "$label" "$TURNS" <<'PY'
import json, re, sys
run, label, turns = sys.argv[1], sys.argv[2], int(sys.argv[3])
srv = open(f"{run}/server.log", errors="replace").read()
eng = open(f"{run}/engine-slice.log", errors="replace").read()

def last(p, g=None, src=None):
    m = re.findall(p, src if src is not None else eng)
    if not m: return None
    v = m[-1]
    if g is None: return v if isinstance(v, str) else " ".join(v)
    return v[g]

# One line per finished request, in order: the server's terminal line for the slot.
# A fully cached turn prints no prefill rate at all (`pp=40007/40002c 0.9s  tg=512 ...`), so the rate is optional.
DONE = re.compile(r"done\s+pp=(\d+)/(\d+)c\s+([\d.]+)s\s+(?:([\d.]+)t/s\s+)?tg=(\d+)\s+([\d.]+)t/s\s+"
                  r"acc=(\d+)%\s+ttft=([\d.]+)s\s+end=(\S+)\s+hit=([\d.]+)%")
dones = DONE.findall(srv)
# The engine's own per-request line, same order, with the reused/read split.
PROMPT = re.compile(r"serve: prompt (\d+) tokens = (\d+) reused \+ (\d+) read in (\d+) ms \(([\d.]+) tok/s\), "
                    r"(\d+) generated in (\d+) ms \(([\d.]+) tok/s\), drafts accepted (\d+) of (\d+), (\d+) checkpoints")
prompts = PROMPT.findall(eng)

# The engine prints its per-request prompt line **twice**: once when the new tokens are applied and once after the
# reply's own windows are stored (`prompt 39156 = 39151 reused + 5 read` then `prompt 39671 = 39667 reused + 4 read`
# for the same turn).  The server's terminal line is one per finished request and its `pp=<total>/<cached>c` matches
# the engine's first line, so rows follow the server lines and engine lines are looked up by total token count.
by_total = {}
for p in prompts:
    by_total.setdefault(int(p[0]), p)
matched = []
src = dones if dones else prompts
rows = []
for n in range(len(src)):
    d = src[n] if dones else None
    p = by_total.get(int(d[0])) if d else src[n]
    if p is not None:
        matched.append(p)
    total = int(p[0]) if p else (int(d[0]) if d else None)
    reused = int(p[1]) if p else (int(d[1]) if d else None)
    read = int(p[2]) if p else (total - reused if total is not None and reused is not None else None)
    rows.append({
        "turn": n + 1,
        "prompt_tokens": total,
        "reused": reused,
        "read": read,
        "pp_tok_s": float(p[4]) if p else (float(d[3]) if d and d[3] else None),
        "turn_s": float(d[2]) if d else None,
        "generated": int(p[5]) if p else (int(d[4]) if d else None),
        "tg_tok_s": float(p[7]) if p else (float(d[5]) if d else None),
        "accept_pct": int(d[6]) if d else (100.0 * int(p[8]) / max(1, int(p[9])) if p else None),
        "ttft_s": float(d[7]) if d else None,
        "hit_pct": float(d[9]) if d else None,
        "end": d[8] if d else None,
    })

metrics = {
    "label": label,
    "turns": len(rows),
    "rows": rows,
    "reused_total": sum(r["reused"] or 0 for r in rows),
    "read_total": sum(r["read"] or 0 for r in rows),
    "prompt_total": sum(r["prompt_tokens"] or 0 for r in rows),
    "first_pp_tok_s": rows[0]["pp_tok_s"] if rows else None,
    "later_pp_tok_s": (sum(r["pp_tok_s"] or 0 for r in rows[1:]) / max(1, len(rows) - 1)) if len(rows) > 1 else None,
    "mean_tg_tok_s": sum(r["tg_tok_s"] or 0 for r in rows) / max(1, len(rows)),
    "mean_ttft_s": sum(r["ttft_s"] or 0 for r in rows[1:]) / max(1, len(rows) - 1) if len(rows) > 1 else None,
    "mean_turn_s": (sum(r["turn_s"] or 0 for r in rows[1:]) / max(1, len(rows) - 1)) if len(rows) > 1 else None,
    "mean_accept_pct": sum(r["accept_pct"] or 0 for r in rows) / max(1, len(rows)),
    "expert_cache_slots": last(r"expert cache (\d+) slots, ([\d.]+) GiB of VRAM", 0),
    "expert_cache_vram_gib": last(r"expert cache (\d+) slots, ([\d.]+) GiB of VRAM", 1),
    "kv_line": last(r"KV streaming: (.*)"),
    "complement_gib": last(r"allocating ([\d.]+) GiB page-locked cache complement"),
    "resident_mode": last(r"resident RAM mode: (.*)"),
    "placement": last(r"experts live in VRAM (.*)"),
    "ram_free_gib": last(r"serve: RAM ([\d.]+) GiB free, guard"),
    "ram_guard_gib": last(r"serve: RAM [\d.]+ GiB free, guard ([\d.]+) GiB"),
    "serve_kept_gib": last(r"guard [\d.]+ GiB, ([\d.]+) GiB kept for serving"),
    "spare_places": last(r"FileExpertSource: (\d+) free places for the adaptive swaps"),
    "stream_all": last(r"every expert streams from (\d+)-token chunks \(([\d.]+) GiB non-resident, (\d+)% pinned, link ([\d.]+) GB/s\)"),
    # Per-request counters, summed over the sweep's turns (the engine prints one line per request).
    "swaps_done_total": sum(int(x) for x in re.findall(r"adaptive swaps: (\d+) into the VRAM tier this request", eng)),
    "swaps_deferred_total": sum(int(x) for x in re.findall(r"adaptive swaps: \d+ into the VRAM tier this request, (\d+) deferred", eng)),
    "file_reads_total": sum(int(x) for x in re.findall(r"(\d+) blob reads from the file", eng)),
    "file_mb_total": round(sum(float(x) for x in re.findall(r"([\d.]+) MB read from the file", eng)), 1),
    "prompt_cache_lines": len(matched),
    "checkpoints_total": sum(int(p[10]) for p in matched),
}
json.dump(metrics, open(f"{run}/metrics.json", "w"), indent=1)
print(f"metrics.json: label={label} turns={metrics['turns']} reused={metrics['reused_total']} "
      f"read={metrics['read_total']} first_pp={metrics['first_pp_tok_s']} later_pp={metrics['later_pp_tok_s']} "
      f"mean_tg={metrics['mean_tg_tok_s']} mean_ttft={metrics['mean_ttft_s']} accept={metrics['mean_accept_pct']} "
      f"slots={metrics['expert_cache_slots']} spare={metrics['spare_places']} deferred={metrics['swaps_deferred_total']} "
      f"file_reads={metrics['file_reads_total']} checkpoints={metrics['checkpoints_total']}")
PY
}

# --- go ----------------------------------------------------------------------
mkdir -p "$WORK"; : > "$STATE"; echo $$ > "$PIDFILE"
st "=== basalt_tune start pid=$$ arms=[${LABELS[*]}] turns=$TURNS max_tokens=$MAXTOK config=$CFG url=$URL (synchronous: basalt stays parked until the very end) ==="

OKARMS=()
if [ "$MODE" = reparse ]; then
  st "reparse: re-reading saved log slices for ${LABELS[*]} (model not loaded again)"
  for i in "${!LABELS[@]}"; do
    [ -f "$(run_dir "$i")/engine-slice.log" ] && harvest_arm "$i" && OKARMS+=("$i") || st "arm ${LABELS[$i]}: no saved slice to reparse"
  done
else
  for i in "${!LABELS[@]}"; do
    st "=== arm ${LABELS[$i]} ==="
    if ! park_basalt; then st "park refused before arm ${LABELS[$i]}: stopping the sweep"; break; fi
    if run_arm "$i"; then OKARMS+=("$i"); else st "arm ${LABELS[$i]} FAILED"; fi
  done
fi

REPORT=""
if [ ${#OKARMS[@]} -ge 2 ]; then
  REPORT=$WORK/tune-$TAG.md
  python3 - "$WORK" "$TAG" "${LABELS[@]}" <<'PY'
import json, os, sys
work, tag = sys.argv[1], sys.argv[2]
labels = [lb for lb in sys.argv[3:] if os.path.exists(f"{work}/arm-{lb}/metrics.json")]
M = {lb: json.load(open(f"{work}/arm-{lb}/metrics.json")) for lb in labels}
def n(x):
    try: return float(x)
    except Exception: return float("nan")

lines = [f"# basalt agentic-tuning sweep {labels[0]}..{labels[-1]} ({os.path.basename(work)})", "",
         f"Arms: {', '.join(labels)}.  Same scripted transcript in every arm "
         "(turn 1 = the long prompt; each later turn adds a fixed assistant block and a fixed user follow-up), "
         "same saved expert profile copied per arm, page cache dropped per arm, RAM/VRAM proven released between arms.",
         "", "## per turn", ""]
for lb in labels:
    m = M[lb]
    lines += [f"### {lb}", "",
              "| turn | prompt tokens | reused | read | pp t/s | wall s | tg t/s | accept % | ttft s | hit % |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for r in m["rows"]:
        lines.append(f"| {r['turn']} | {r['prompt_tokens']} | {r['reused']} | {r['read']} | {r['pp_tok_s']} | "
                     f"{r['turn_s']} | {r['tg_tok_s']} | {round(r['accept_pct'] or 0, 1)} | {r['ttft_s']} | {r['hit_pct']} |")
    lines += ["", f"- reused / read over all turns: **{m['reused_total']} / {m['read_total']}** "
                  f"({round(100 * m['reused_total'] / max(1, m['prompt_total']), 1)}% of all prompt tokens taken from cache)",
              f"- first turn prefill {m['first_pp_tok_s']} t/s, later turns {round(m['later_pp_tok_s'] or 0, 1)} t/s, "
                  f"mean decode {round(m['mean_tg_tok_s'] or 0, 1)} t/s, mean later-turn wall {round(m['mean_turn_s'] or 0, 2)} s "
                  f"(mean ttft {round(m['mean_ttft_s'] or 0, 2)} s)",
              f"- expert cache {m['expert_cache_slots']} slots ({m['expert_cache_vram_gib']} GiB), spare places {m['spare_places']}",
              f"- adaptive swaps {m['swaps_done_total']} done / {m['swaps_deferred_total']} deferred, "
                  f"file reads {m['file_reads_total']} blobs / {m['file_mb_total']} MB, checkpoints {m['checkpoints_total']}",
              f"- placement: {m['placement']}", f"- prompt path: {m['stream_all']}", ""]

# The rule, stated before the numbers: for a coding agent the cache decides the cost of a turn,
# decode speed decides how the turn feels, and the swap deferral says whether the tier is saturated.
ratio = {lb: n(M[lb]["reused_total"]) / max(1.0, n(M[lb]["prompt_total"])) for lb in labels}
best = max(labels, key=lambda lb: ratio[lb])
close = [lb for lb in labels if ratio[lb] >= ratio[best] - 0.02]
if len(close) > 1:
    top_tg = max(n(M[lb]["mean_tg_tok_s"]) for lb in close)
    near = [lb for lb in close if n(M[lb]["mean_tg_tok_s"]) >= top_tg - 0.5]
    best = min(near, key=lambda lb: n(M[lb]["read_total"])) if len(near) > 1 else max(close, key=lambda lb: n(M[lb]["mean_tg_tok_s"]))
lines += ["## verdict", "",
          f"winner: **{best}**",
          f"why: cache reuse over the whole transcript ({round(100 * ratio[best], 1)}% of prompt tokens reused); "
          "arms within 2 points were separated by mean decode rate, then by fewer re-read tokens.", ""]
lines += ["| arm | reused % | read tokens | mean tg t/s | mean later-turn wall s | file reads | deferred swaps |",
          "|---|---|---|---|---|---|---|"]
for lb in labels:
    m = M[lb]
    lines.append(f"| {lb} | {round(100 * ratio[lb], 1)} | {m['read_total']} | {round(m['mean_tg_tok_s'] or 0, 1)} | "
                 f"{round(m['mean_turn_s'] or 0, 2)} | {m['file_reads_total']} | {m['swaps_deferred_total']} |")
lines += ["", "No option was written to basalt_config.json by this run unless it was started with --apply LABEL."]
open(f"{work}/tune-latest.md", "w").write("\n".join(lines))
open(f"{work}/tune-{tag}.md", "w").write("\n".join(lines))   # keep every sweep, the way basalt_ab.sh keeps its reports
print(f"report: {work}/tune-{tag}.md (and the rolling {work}/tune-latest.md)")
print(f"winner: {best}")
print(f"why: cache reuse over the whole transcript ({round(100 * ratio[best], 1)}% of prompt tokens reused)")
PY
else
  st "fewer than two arms produced metrics: no comparison, config untouched"
fi

# --- optional apply ----------------------------------------------------------
if [ -n "$APPLY_LABEL" ]; then
  case " ${LABELS[*]} " in *" $APPLY_LABEL "*) ;; *) echo "basalt_tune: --apply '$APPLY_LABEL' is not one of ${LABELS[*]}" >&2; exit 2 ;; esac
  cp -p "$CFG" "$WORK/config-backup-$TAG.json"
  python3 - "$CFG" "${FLAGLIST[${LABELS.index("$APPLY_LABEL")}]}" <<'PY'
import json, sys
cfg, arm = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
eng = d.setdefault("engine", {})
words = arm.split()
i = 0
while i < len(words):
    w = words[i]
    if not w.startswith("--"): i += 1; continue
    key = w[2:]
    if i + 1 < len(words) and not words[i + 1].startswith("--"):
        v = words[i + 1]
        try: v = int(v)
        except ValueError:
            try: v = float(v)
            except ValueError: v = v
        eng[key] = v
        i += 2
    else:
        eng[key] = True
        i += 1
json.dump(d, open(cfg, "w"), indent=2)
print("engine block now:", json.dumps(eng, sort_keys=True))
PY
  st "config: applied arm '$APPLY_LABEL' (${FLAGLIST[${LABELS.index("$APPLY_LABEL")}]}); backup $WORK/config-backup-$TAG.json"
fi

if [ "$MODE" != reparse ] && [ "$RESTORE" = 1 ] && [ "$BASALT_WAS" = 1 ]; then
  st "restore: handing the session back to basalt on $URL"
  start_basalt
  if wait_ready 300; then
    # 1200 > 1024 so --answer-room reserves room for the answer instead of the thinking eating the cap
    curl -s -o "$WORK/handoff.json" -m 60 -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1200}" \
      "$URL/v1/chat/completions" >/dev/null
    st "handoff: /v1/chat/completions answered ($(proof_summary < "$WORK/handoff.json")) -- the session can infer again"
  else
    st "WARN: basalt did not report a loaded model -- check $WORK/basalt_runtime.log and start it by hand: basalt"
  fi
fi

st "done. report: ${REPORT:-$WORK/tune-latest.md}"
