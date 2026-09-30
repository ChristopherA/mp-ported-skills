# transcripts fixtures

A background worker's transcript, `<config dir>/projects/<folder>/<session id>.jsonl`, cut from one live `/implement` worker (Claude Code 2.1.284, `claude --bg --model claude-sonnet-5`), for the `watch.sh` tests in `tests/supervise.test.sh`. Each row keeps only its shape: `type`, `subtype`, `operation`, `isSidechain`, `isMeta`, `cwd`, the message's role and content block types, and a `turn_duration` row's `durationMs` and `pendingBackgroundAgentCount`. Prompt text becomes `<prompt>` and the Project path becomes `/work/project`.

Each file opens with the transcript's first 12 rows: the header rows and the `/implement` prompt.

| File | Ends with |
|---|---|
| `just-launched.jsonl` | the prompt, before any assistant row |
| `mid-turn.jsonl` | an assistant `tool_use` row, its result not yet in |
| `waiting-on-agents.jsonl` | a `turn_duration` row with `pendingBackgroundAgentCount: 2`: the turn ended while two review agents ran, and their reports started the next turn |
| `turn-ended.jsonl` | the final summary and a `turn_duration` row with no pending agents, then `last-prompt` and `cost-state` |

The recorded worker entered a worktree during its run, and its whole transcript, including the rows written before that, was moved to the worktree's project folder. The rows after the move carry the worktree's `cwd`.
