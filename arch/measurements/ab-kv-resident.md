# basalt kv-resident A/B (20261101_052142)

Engine: `0.1.0.r2271.gc7bf051c-1` at `/mnt/aosp/Projects/basalt/basalt_ab.sh`. One fixed prompt, both runs: `prompt-40000.txt` (149251 bytes, 40000 tokens targeted), max_tokens=512, page cache dropped before each run, each run started from a copy of the same saved expert profile, no run writes the shared profile.

**Winner: `--kv-resident 32768`** -- decode expert-cache hit rate decided it: 54.1% vs 52.4%.

| metric | kv-resident 32768 | kv-resident 131072 |
| --- | --- | --- |
| kv-resident | 32768 | 131072 |
| KV cells kept in VRAM / total cells (per full-attention layer) | 32768 / 196608 | 131072 / 196608 |
| KV pinned in RAM (GiB) | 2.32 | 2.32 |
| expert cache slots | 2841 | 2131 |
| expert cache VRAM (GiB) | 4.69 | 3.52 |
| expert cache auto line | 5.86 GiB free, 700 MiB reserved (+218 MiB for the draft head, +278 MiB for what loads after) -> 2163 slots | 4.70 GiB free, 700 MiB reserved (+218 MiB for the draft head, +280 MiB for what loads after) -> 1624 slots |
| RAM tier after placement (GiB) | 35.3 | 36.4 |
| experts left on SSD (GiB) | 0.0 | 0.0 |
| expert corpus (GiB) | 40.0 | 40.0 |
| free RAM the engine saw (GiB) | 6.69 | 6.17 |
| RAM guard / headroom (GiB) | 2.74 | 2.74 |
| kept for serving (GiB) | 0.90 | 0.90 |
| room for the complement (GiB) | - | - |
| page-locked complement (GiB) | 36.62 | 36.97 |
| complement kept in RAM (GiB) | 36.62 | 36.97 |
| stream-all chunk (tokens) | 6144 | 6144 |
| prompt path non-resident (GiB) | 35.3 | 36.4 |
| of it page-locked (%) | 100 | 100 |
| measured link (GB/s) | 12.0 | 7.1 |
| slots the prompt path borrows | 2533 | 1914 |
| complement truncated? | no (it fit) | no (it fit) |
| free places for the adaptive swaps | 113 free places for the adaptive swaps (9 blob sizes, 189 MiB) | 113 free places for the adaptive swaps (9 blob sizes, 189 MiB) |
| pinned complement ready | resident 36.62 GiB, pinned 36.62 GiB in 7 s | resident 36.97 GiB, pinned 36.97 GiB in 8 s |
| resident RAM mode | 36.62 GiB of experts in RAM (page-locked), 2841 in the GPU cache; adaptive swaps exchange them with the GPU cache (no file reads) | 36.97 GiB of experts in RAM (page-locked), 2131 in the GPU cache; adaptive swaps exchange them with the GPU cache (no file reads) |
| prompt tokens (engine counted) | 32765 | 32765 |
| prompt reused | 0 | 0 |
| prompt read | 32765 | 32765 |
| prefill (t/s) | 2980.2 | 2760.1 |
| generated tokens | 512 | 512 |
| decode (t/s) | 53.5 | 47.3 |
| drafts accepted | 293 of 334 | 199 of 247 |
| decode expert-cache hit (%) | 54.1 | 52.4 |
| hits / lookups | 145975 / 269760 | 142701 / 272160 |
| adaptive swaps into VRAM this request | 5480 | 4954 |
| adaptive swaps deferred | 3631 | 4079 |
| resident experts (GiB) | 36.62 | 36.97 |
| exchanged with the VRAM tier | 3794 | 4367 |
| blob reads from the file | 6056 | 8395 |
| MB read from the file | 10727.3 | 14961.4 |
| KV block hit (%) | 97.69 | 98.28 |
| KV read from RAM (MiB) | 322.6 | 242.0 |

## The engine's own closing lines

```
kv-resident 32768: [server] s1 done  pp=32765/0c 11.0s 2980t/s  tg=512 53.5t/s acc=88%  ttft=11.1s  end=length  hit=54.1%  pcie=0.0%
kv-resident 131072: [server] s1 done  pp=32765/0c 11.9s 2760t/s  tg=512 47.3t/s acc=81%  ttft=12.0s  end=length  hit=52.4%  pcie=0.0%
```

## How to read it

`--kv-resident 32768` kept 32768 of 196608 KV cells per full-attention layer in VRAM and left 2841 slots (4.69 GiB) to the expert cache; `--kv-resident 131072` kept 131072 in VRAM and left 2131 slots (3.52 GiB).

`--kv-resident` is the KV that **stays in VRAM**; everything above it streams through a pinned host-RAM buffer (the
engine says so at load, in its own `KV streaming: N of M cells per QSA layer in VRAM` line). Raising it takes VRAM
out of the expert cache and simultaneously grows the expert complement that has to find a home in RAM -- both
figures are in the table. Measured on this pack, lower is better:
`hit 54.1% -> 52.4%`, `decode 53.5 -> 47.3 t/s`, `slots 2841 -> 2131`.

Both runs still ended with `adaptive swaps: ... deferred (no free RAM place)` and neither printed a `free places for
the adaptive swaps` line, so the swap-spare problem sits on the RAM side and kv-resident does not fix it in this
range -- that one is `resident-budget-gib` (README-setup.md, "Why 1.83 M adaptive swaps were deferred").

Next probe with this wrapper, no edits needed: `./basalt_ab.sh 20480 0` (20480 is the engine's floor,
`qsa_kv_resident_min`; 0 lets the KV grow elastically in VRAM).

Related: `/mnt/aosp/Projects/basalt/README-setup.md` (the RAM safety headroom, the swap-spare diagnosis, the
five-value A/B plan), `/usr/share/doc/basalt-engine-git/configuration/index.md`.
