# basalt_config.json — the agentic-coding tuning round (2026-11-01)

Live file: `~/.local/share/basalt/basalt_config.json`. Every key, what it was before, what it is now,
and what backs it. Nothing here was applied without a measurement or a doc/source citation; the two
changed keys were applied by hand (not by a wrapper) and each is verified in the running engine's own
`/proc/<pid>/cmdline`.

Artifacts: `ab/ab-kv-resident-20261101_052142.md`, `tune/tune-20261101_072507.md` (spec sweep),
`tune/tune-latest.md` (rolling copy), `tune/arm-<label>/{metrics.json,server.log,engine-slice.log}`,
`tune/config-backup-20261101_0725.json` (the file as it stood before the `spec` change).

## changed

| key | before | after | backing |
| --- | --- | --- | --- |
| `engine.conversation-cache-disk-mib` | absent (RAM tier only) | `4096` | `basalt_tune.sh --restart-at 3`, same 4-turn transcript, engine restarted between turns 2 and 3: with the tier **118 677 reused / 40 290 read** and mean later-turn ttft **1.20 s** and **12 776** file blob reads; without it 79 153 / 79 814, **5.23 s**, 30 067. Containers land in `~/.cache/basalt/<model hash>/conversations/*.bcs` (810 MB in the test, capped by the budget). PR #149 wrote the tier, PR #150 made the files `0600`. |
| `engine.spec` | `7` (copied from strata) | `12` | 3-arm sweep, 6 turns, cold per arm, identical reuse in all three arms (`199 590 / 41 151`), `max_tokens 1024`: `spec 7` **55.9** t/s decode (55.5 in the replicate), 90.0 % acceptance, 3 743 deferred swaps, 72 556 file reads; **`spec 12` 57.2 t/s** (57.3 in the replicate), 88.5 %, **3 001**, **66 968**; `spec 16` 55.4 t/s. `spec 10` measured 57.6 t/s in a 4-turn arm — the gain plateaus between 10 and 12 and falls off by 16. |

## changed (2026-11-03, the resident headroom round)

| key | before | after | backing |
| --- | --- | --- | --- |
| `engine.resident-headroom-slack-gib` | absent (0) | `2` | new flag `--resident-headroom-slack-gib`; the engine's own line went from `minus the 11 GiB safety headroom` to `39.73 GiB available minus 9 GiB headroom`, copy 30.47 GiB page-locked. Details and the honest caveat (the copy is bounded by the RAM free at plan time; no t/s measured): [stack-20261103.md](stack-20261103.md). |
| `engine.prompt-cache` | `3` | `2` | a checkpoint is ~118 MiB of RAM the resident copy cannot use, and the round below found 3 and 6 equal on reuse; 2 gives the RAM back to the experts. |

## changed (2026-11-05, the v0.2.1 stack + adapt-margin round)

| key | before | after | backing |
| --- | --- | --- | --- |
| `engine.adapt-margin` | absent (1.5) | `3.0` | PR #231 flag `--adapt-margin`: sets the count margin needed before a missing expert displaces a resident one during adaptive rounds. With `adapt-every: 1`, a margin of 3.0 prevents thrashing/premature swaps. |
| `server.model` | `Qwen3.8-FN-GSQ-RCO-IQ3_XXS.v2.basalt` | `Qwen3.8-FN-UD-Q4_K_XL.v2.basalt` | UD-Q4_K_XL pack migrated to `.basalt` v2 format with `--compat-bf16` and installed to `~/.local/share/basalt/models/`. |

## kept, with the evidence that kept it

| key | value | backing |
| --- | --- | --- |
| `engine.kv-resident` | `32768` | measured twice on this stack (`ab-kv-resident-20261101_052142.md`): 32768 → 2 841 expert-cache slots, 53.5 t/s decode, 54.1 % hit; 131072 → 47.3 t/s, 52.4 %. On the older build the same ordering held (40.3 vs 33.1). Source bound: `qsa_kv_resident_min() = 20480` (`src/core/layer.cpp`). |
| `engine.prompt-cache` | `3` | arm with `prompt-cache 6 --prompt-cache-every 8192`: 55.1 t/s vs 55.9, mean later-turn wall 1.07 s vs 1.03, checkpoints 18 vs 17 for no reuse gain. |
| `engine.adapt-every` / `adapt-swaps` / `adapt-decay` | `1` / `160` / `0.97` | arms: `adapt-decay 0.85 --adapt-swaps 256` → 52.9 t/s and +1 550 deferred swaps; `--adapt-every 64` → 53.7 t/s. The community profile for boxes with swap spares is measurably worse here. |
| `engine.max-context` | `196608` | 192 K, the value the strata instance ran; the pack's native context is 262 144, so no RoPE scaling. |
| `engine.kv` | `int8` | strata parity, and the KV tier is what leaves 4.69 GiB of VRAM for the expert cache on a 12 227 MiB card. |
| `engine.vram-reserve-mib` | `700` | the operator's chosen value; the engine reports 11 226–11 254 MiB used with it. |
| `engine.resident-experts` / `expert-cache` | `true` / `auto` | the engine places 40.0 GiB of experts (4.7 VRAM + 35.3 RAM, **0.0 on the SSD**) and prints `FileExpertSource: 113 free places for the adaptive swaps` — the reason `resident-budget-gib` is not set. |
| `engine.expert-profile-save` / `-every` | path / `10` | persists what the adaptive tier learns; every test copies it per run so no test mutates the shared file. |
| `server.alias` | `qwen3.8-flash-next-iq3_xxs` | strata client compatibility: the served model name must not change (`serve/server.py` sets `cfg["model_name"] = a.alias`, `serve/handler.py` answers 404 for anything else). |
| `server.host` / `port` / `gpu` | `127.0.0.1` / `8080` / `0` | operator's choice; only one engine may hold 8080. |
| `server.temperature` `top-p` `top-k` `min-p` `presence-penalty` `repetition-penalty` | `0.8` `0.95` `20` `0.0` `0.0` `1.0` | the pack's own `sampling` block (`temperature 1.0`, `top_p 0.95`, `top_k 20`, `min_p 0.0`) with the strata session's temperature; nothing here is measurable without changing the model's output distribution, so the copied values stand. |
| `server.grammar` | `true` | tool-call arguments are constrained by the grammar mask; #167/#166 fixed quoted string values and namespaced tool names in `serve/frontend.py`, which is the path the coding agents use. |
| `server.vision` | `dynamic` | PR #181 (sidecar found by the engine's executable suffix) and #75 (input file closed before the reply, `vision-max-tokens`); the pack carries a 0.845 GiB `vision/mmproj` section. |
| *no* `reasoning-budget-tokens` | default `0` (none) | `--answer-room` (default on) already reserves answer space for caps ≥ 1024; at `max_tokens 1200` a "ping" answers normally (`end=stop`, 99 reasoning tokens). A positive default would truncate the deep thinking of agent requests that omit `reasoning_budget_tokens`. Caps **below** 1024 can be swallowed by the thinking (`finish_reason: length`, `content: null`) — that is a client cap, so every wrapper's proof request now asks for 1200. |
| *no* `prefill-fp8` | off | opt-in; `prefill_fp8_dense_test` disagrees with cuBLASLt 13.4 on this box, and it fails the same way on PR #129's own branch. |
| *no* `slots` / `batch` | default | a second slot costs another session's VRAM on a 12 GiB card. |

## validation

`serve.config.load_config_file` + `build_parser` + `check_engine_flags(file_words, engine_flags_of(engine_bin))`
parse the live file into 27 engine words, every one accepted by the installed engine, with no model loaded:
`--max-context 196608 --kv int8 --kv-resident 32768 --expert-cache auto --resident-experts
--vram-reserve-mib 700 --adapt-every 1 --adapt-swaps 160 --adapt-decay 0.97 --expert-profile-save …
--expert-profile-save-every 10 --spec 12 --prompt-cache 3 --conversation-cache-disk-mib 4096`.

Live proof after each change (engine restarted by `build/restart_apply.sh`): `/v1/models` reports
`qwen3.8-flash-next-iq3_xxs` `loaded` with `n_ctx=196608`, and a chat completion answers
(`end=stop`, real content). Engine cmdline after the last restart:

```
--adapt-decay 0.97 --spec 12 --prompt-cache 3 --conversation-cache-disk-mib 4096
--conversation-cache-dir /home/sanjxz/.cache/basalt/f81e506f470fa3ec/conversations …
```
