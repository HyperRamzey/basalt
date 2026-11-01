# basalt agentic-tuning sweep spec7..spec16 (tune)

Arms: spec7, spec12, spec16.  Same scripted transcript in every arm (turn 1 = the long prompt; each later turn adds a fixed assistant block and a fixed user follow-up), same saved expert profile copied per arm, page cache dropped per arm, RAM/VRAM proven released between arms.

## per turn

### spec7

| turn | prompt tokens | reused | read | pp t/s | wall s | tg t/s | accept % | ttft s | hit % |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 39156 | 0 | 39156 | 3040.0 | 0.0 | 54.8 | 89 | 13.0 | 49.1 |
| 2 | 39529 | 39151 | 378 | 444.7 | 0.0 | 56.3 | 100 | 0.9 | 40.7 |
| 3 | 40007 | 39524 | 483 | 486.8 | 0.0 | 56.5 | 100 | 1.1 | 39.3 |
| 4 | 40275 | 40002 | 273 | 319.8 | 1.0 | 52.8 | 83 | 0.9 | 51.4 |
| 5 | 40648 | 40270 | 378 | 390.2 | 0.9 | 56.7 | 83 | 1.0 | 40.0 |
| 6 | 41126 | 40643 | 483 | 455.3 | 1.1 | 58.4 | 85 | 1.1 | 63.0 |

- reused / read over all turns: **199590 / 41151** (82.9% of all prompt tokens taken from cache)
- first turn prefill 3040.0 t/s, later turns 419.4 t/s, mean decode 55.9 t/s, mean later-turn wall 0.6 s (mean ttft 1.0 s)
- expert cache 2841 slots (4.69 GiB), spare places 113
- adaptive swaps 29252 done / 3743 deferred, file reads 72556 blobs / 0 MB, checkpoints 17
- placement: 4.7 GiB (12%), peer GPU 0.0 GiB (0%), RAM 35.3 GiB (88%), file (SSD) 0.0 GiB (0%); 40.0 GiB in all
- prompt path: 5632 35.3 100 28.4

### spec12

| turn | prompt tokens | reused | read | pp t/s | wall s | tg t/s | accept % | ttft s | hit % |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 39156 | 0 | 39156 | 3039.7 | 0.0 | 55.9 | 84 | 13.0 | 55.0 |
| 2 | 39529 | 39151 | 378 | 449.2 | 0.0 | 55.3 | 96 | 0.9 | 43.4 |
| 3 | 40007 | 39524 | 483 | 491.4 | 0.9 | 59.0 | 91 | 1.1 | 47.2 |
| 4 | 40275 | 40002 | 273 | 321.2 | 0.8 | 57.2 | 85 | 0.9 | 63.6 |
| 5 | 40648 | 40270 | 378 | 389.3 | 0.0 | 59.2 | 92 | 1.0 | 35.9 |
| 6 | 41126 | 40643 | 483 | 470.0 | 0.0 | 56.3 | 83 | 1.1 | 49.5 |

- reused / read over all turns: **199590 / 41151** (82.9% of all prompt tokens taken from cache)
- first turn prefill 3039.7 t/s, later turns 424.2 t/s, mean decode 57.1 t/s, mean later-turn wall 0.34 s (mean ttft 1.0 s)
- expert cache 2841 slots (4.69 GiB), spare places 113
- adaptive swaps 27150 done / 3001 deferred, file reads 66968 blobs / 0 MB, checkpoints 17
- placement: 4.7 GiB (12%), peer GPU 0.0 GiB (0%), RAM 35.3 GiB (88%), file (SSD) 0.0 GiB (0%); 40.0 GiB in all
- prompt path: 5632 35.3 100 28.4

### spec16

| turn | prompt tokens | reused | read | pp t/s | wall s | tg t/s | accept % | ttft s | hit % |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 39156 | 0 | 39156 | 3042.7 | 0.0 | 54.0 | 88 | 13.0 | 50.9 |
| 2 | 39529 | 39151 | 378 | 437.1 | 0.0 | 55.1 | 86 | 1.0 | 34.9 |
| 3 | 40007 | 39524 | 483 | 498.3 | 0.0 | 58.0 | 80 | 1.1 | 41.9 |
| 4 | 40275 | 40002 | 273 | 322.6 | 0.0 | 55.4 | 80 | 0.9 | 51.0 |
| 5 | 40648 | 40270 | 378 | 385.5 | 0.0 | 55.4 | 100 | 1.1 | 41.6 |
| 6 | 41126 | 40643 | 483 | 460.9 | 0.9 | 54.8 | 100 | 1.1 | 50.5 |

- reused / read over all turns: **199590 / 41151** (82.9% of all prompt tokens taken from cache)
- first turn prefill 3042.7 t/s, later turns 420.9 t/s, mean decode 55.4 t/s, mean later-turn wall 0.18 s (mean ttft 1.04 s)
- expert cache 2841 slots (4.69 GiB), spare places 113
- adaptive swaps 29442 done / 3321 deferred, file reads 69696 blobs / 0 MB, checkpoints 17
- placement: 4.7 GiB (12%), peer GPU 0.0 GiB (0%), RAM 35.3 GiB (88%), file (SSD) 0.0 GiB (0%); 40.0 GiB in all
- prompt path: 5632 35.3 100 28.4

## verdict

winner: **spec12**
why: cache reuse over the whole transcript (82.9% of prompt tokens reused); arms within 2 points were separated by mean decode rate, then by fewer re-read tokens.

| arm | reused % | read tokens | mean tg t/s | mean later-turn wall s | file reads | deferred swaps |
|---|---|---|---|---|---|---|
| spec7 | 82.9 | 41151 | 55.9 | 0.6 | 72556 | 3743 |
| spec12 | 82.9 | 41151 | 57.1 | 0.34 | 66968 | 3001 |
| spec16 | 82.9 | 41151 | 55.4 | 0.18 | 69696 | 3321 |

No option was written to basalt_config.json by this run unless it was started with --apply LABEL.