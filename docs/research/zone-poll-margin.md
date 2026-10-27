# How far a worker's context grows between two zone polls

`watch.sh --zone` reads a worker's zone reading every 30 seconds, and `zone.sh` calls it due for a capture at `ZONE_CAPTURE`, or past a running background task at `ZONE_FORCE`. The capture must come before the worker auto-compacts, so a threshold needs a margin below the compact point at least as large as the context can grow between two polls (#181).

## Method

Context size is a main-chain call's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, one reading per distinct `requestId`, as `zone.sh` reads it. Sidechain rows, rows with no usage, and `<synthetic>` rows with zero usage are left out.

A poll taken just before call i+1 reads call i; the next poll, 30 seconds later, reads the last call before that time. For every call i, the growth is that later reading minus call i's, and a transcript's figure is the largest over all i: the worst placement of the poll grid. Compaction drops count as no growth.

The transcripts are every `/supervise` worker (a job named `worker ...`) under the maintainer's profile on 2026-10-26 whose transcript was still on disk, all on `claude-opus-5-5`. No transcript text was copied; only the counts below.

## Results

- Transcripts: 107
- Main-chain calls: 4,132
- 30-second polls the runs span: 9,242
- Largest growth in 30 seconds: 49990 tokens, across 8 calls, from a context of 51,089
- Next largest: 49,078 (5 calls); 90th percentile of per-transcript largest: 34.8k; median: 22.2k

The largest growths are several calls landing inside one poll interval (parallel reads, a subagent's result), not one tool result. The earlier bound, one Read result of 25k tokens, is half of what was measured.

## Thresholds

`zone.sh` sets `ZONE_MARGIN_K=50`, the largest growth rounded up to 1k. On the smallest window a worker runs on, 200k tokens at `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 80, the session compacts at 160k tokens, about 106% of a 150k zone. The force point plus the margin must stay below it:

- `ZONE_FORCE * 1.5k + 50k < 160k`, so `ZONE_FORCE` is at most 73; it is set to 72.
- `ZONE_CAPTURE` keeps its 8-point gap below the force point: 64.

On a 1M window (`claude-opus-5-5`, `claude-fable-5-1`, or a `[1m]` model id) the compact point is about 533% of zone, far above both. `zone.sh --compact MODEL`, which `watch.sh --zone` runs before its first poll, refuses when the running override and the model's window put the force point plus the margin at or past the compact point.
