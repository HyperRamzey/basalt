#!/usr/bin/env bash
# Park the live basalt, start it again so the edited basalt_config.json takes effect, prove it answers.
set -u
URL=http://127.0.0.1:8080
LOG=/mnt/aosp/Projects/basalt/build/restart_apply.log
st(){ printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
proof_summary(){ jq -r '"end=" + (.choices[0].finish_reason // "?") + " content=" + ((.choices[0].message.content // "") | length | tostring) + " chars"' 2>/dev/null; }
engine_pids(){ pgrep -f 'basalt/app/bin/basalt --serve' 2>/dev/null || true; }
server_pids(){ pgrep -f 'python3 -m serve\.server .*basalt/app/bin/basalt' 2>/dev/null || true; }
for p in $(server_pids); do kill -INT "$p"; done
for _ in $(seq 1 60); do [ -z "$(engine_pids)" ] && break; sleep 2; done
if [ -n "$(engine_pids)" ]; then for p in $(engine_pids); do kill -TERM "$p"; done; fi
for _ in $(seq 1 90); do
  avail=$(free -g | awk '/^Mem:/{print $7}'); used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1}END{print s+0}')
  [ "$avail" -ge 38 ] && [ "$used" -le 2500 ] && break; sleep 2
done
st "parked: $(free -h | awk '/^Mem:/{print "avail="$7}'), vram $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{s+=$1}END{print s+0}') MiB"
setsid bash -c 'sleep infinity | exec fish -c basalt' >>"$LOG" 2>&1 < /dev/null &
for _ in $(seq 1 200); do
  if [ -n "$(engine_pids)" ] && curl -s --max-time 5 "$URL/v1/models" | grep -q '"value": *"loaded"'; then st "loaded"; break; fi
  sleep 5
done
curl -s -o /tmp/restart_proof.json -m 60 -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next-iq3_xxs","messages":[{"role":"user","content":"ping"}],"max_tokens":1200}' \
  "$URL/v1/chat/completions" >/dev/null
st "proof: $(proof_summary < /tmp/restart_proof.json)"
ep=$(engine_pids | head -1); mapfile -t -d '' cmd < "/proc/$ep/cmdline"
last=""; for i in "${!cmd[@]}"; do [ "${cmd[$i]}" = "--conversation-cache-disk-mib" ] && last=${cmd[$((i+1))]:-}; done
st "engine --conversation-cache-disk-mib = ${last:-MISSING}"
