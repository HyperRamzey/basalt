# arch-packaging: the package build and the RTX 5070 12 GiB measurements

This branch carries the Arch Linux packaging for the engine stack on branch [`stack-5070`](../tree/stack-5070)
(tag `stack-5070-20261101`), plus the scripts that measured it and the measurement logs. Nothing here changes the
engine; the engine code is the upstream tree plus merged upstream pull requests.

## Machine

| | |
| --- | --- |
| GPU | 1x NVIDIA GeForce RTX 5070, 12 227 MiB, compute capability 12.0, power limit 250 W |
| PCIe | 4.0 x16, pinned host-to-device copy 28.2 GB/s (measured) |
| CPU | AMD Ryzen 7 5700X3D, 8 physical cores / 16 threads, 96 MiB L3, **no AVX-512** |
| RAM | 55 GiB usable, **dual-channel DDR4-3600**, streaming read 42.7 GB/s (measured, `basalt-bench --hardware`) |
| OS | Arch Linux, gcc 15, CUDA 13.4 (`/opt/cuda`), built for `sm_120` only |
| Model | `Qwen3.8-FN-GSQ-RCO-IQ3_XXS.basalt` (79 867 643 037 bytes, sha256 `d02bb1b1…fe65ed71`) from `jesdga/Qwen3.8-Flash-Next-Basalt` |

## Build the package

```sh
makepkg -si              # upstream BASE + patches/basalt-stack.patch (the reproducible path)
_no_stack=1 makepkg -si  # plain upstream HEAD, no stack
_stack=$PWD makepkg -si  # build from a development clone instead of the patch
```

`prepare()` builds in a detached git worktree (`$srcdir/stack`) at `patches/BASE`, applies
`patches/basalt-stack.patch` there, and stops unless the result hashes to `patches/TREE`:

```
BASE    876e47e875329d15b0c377bab7091cc5d82bae75   (upstream)
TIP     c7bf051c35c146ba290b28e03a91410791e9d098   (= branch stack-5070, tag stack-5070-20261101)
TREE    1829a53345a57c64af11f26b349cc01edb5900b4   (verified after the patch)
patch   174 files changed, 9913 insertions, 1585 deletions
```

`refresh-stack.sh` regenerates those five files from a branch, and verifies that a clean upstream clone plus the
patch reproduces the recorded tree. `-DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++` is pinned: clang plus
libstdc++ 16 fails on the recursive `JsonValue` in `src/program/grammar/schema.cpp`.

## The stack on this branch

Merged clean (17): `#179 #174 #167 #166 #67 #127 #177 #176 #175 #178 #112 #170 #150 #156 #181 #182 #183`
Hand-resolved onto upstream's split files (15): `#114 #115 #117 #128 #129 #149 #155 #157 #159 #100 #101 #107 #66 #89 #75`
Left out (10, all merge clean but not wanted here): `#13 #68 #70 #80 #87 #90 #96 #110 #126 #184`
`#98` was already in upstream history.

Two changes are this machine's test adaptations, not upstream behaviour:
`conversation_store_test` gets `CUDA_VISIBLE_DEVICES=-1` and `TIMEOUT 300` (45 s plain upstream, 127 s with the
`#149` disk storage), and `hc8_parity`'s row-slice margin widens to `5e-5` because `#157` pins per-shape cuBLASLt
algorithms and a slice starts at a different alignment.

ctest: **167 of 170 pass**. The three failures reproduce on plain upstream `876e47e8` or on the PR's own branch:
`expert_multi_test` (needs AVX-512-VNNI/VBMI, this CPU has none), `ple_reader_selftest` (keep-alive windows, fails
on plain upstream too), `prefill_fp8_dense_test` (E4M3 per-row scales disagree with the CPU encoder under CUDA 13.4,
fails on `#129`'s branch; FP8 dense prefill is opt-in and stays off).

## The community row (`measurements/row-5070-iq3_xxs.json`, `measurements/community.log`)

`basalt-bench --community`, three fresh engine processes, cold, int8 KV, engine defaults, no SSD spill:

```
prefill 16K 3119.5 t/s (5.3 s)   prefill 64K 3102.6 t/s (21.5 s)   decode 84.7 t/s (9630 tokens in 113.7 s)
conv 69.1 (87.1% accept, draft 1.61)   struct 90.6 (99.0%, 6.78)   prose 72.3 (82.7%, 1.26)
load 43.8 GiB in 12 s: 9.1 GiB VRAM + 34.7 GiB host RAM, 0 GiB read from the SSD
```

`basalt-probe` on defaults (`measurements/probe.log`): `5070 626 GB/s | PCIe 27.3 GB/s | RAM 45 GB/s`, experts
3527 in the GPU cache / the rest in RAM, cold decode 65 / 67 / 81 t/s (prose / conv / struct).

## Serving measurements (the config in `config-changes.md`)

`--max-context 196608 --kv int8 --kv-resident 32768 --expert-cache auto --resident-experts --vram-reserve-mib 700
--spec 12 --prompt-cache 3 --conversation-cache-disk-mib 4096`, four-turn scripted agentic transcripts, page cache
dropped before each arm, per-arm copy of the expert profile and of the conversation cache (`wrappers/basalt_tune.sh`):

| arm | reused / read tokens | mean decode | draft accept | deferred swaps | expert file reads |
| --- | --- | --- | --- | --- | --- |
| `--spec 7` | 199 590 / 41 151 | 55.9 t/s | 90.0 % | 3743 | 72 556 |
| **`--spec 12`** | 199 590 / 41 151 | **57.2 t/s** | 88.5 % | **3001** | **66 968** |
| `--spec 16` | 199 590 / 41 151 | 55.4 t/s | 89.0 % | 3321 | 69 696 |

`--kv-resident` A/B at 32 765 tokens (`measurements/ab-kv-resident.md`): 32 768 wins every line — 53.5 against
47.3 t/s decode, 54.1 % against 52.4 % expert-cache hit — because 131 072 resident cells take VRAM slots away from
the expert cache. `--conversation-cache-disk-mib 4096` is what kept prompt reuse across an engine restart
(118 677 reused / 12 776 expert file reads against 79 153 reused / 30 067 reads without it).

## Wrappers

`wrappers/` are the scripts that ran all of the above. Each one stops the running server first (the GPU and the
74 GiB of host RAM must be free), does its work, starts the server again, waits for `/v1/models` to report the model
loaded, and proves it with one chat completion before returning. They name this machine's paths at the top; change
those before reusing them.
