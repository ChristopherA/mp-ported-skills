# transcripts fixtures

A background worker's transcript, `<config dir>/projects/<folder>/<session id>.jsonl`, cut from one live `/implement` worker (Claude Code 2.1.284, `claude --bg --model claude-sonnet-5`), for the `watch.sh` tests in `tests/supervise.test.sh`. Each row keeps only its shape: `type`, `subtype`, `operation`, `isSidechain`, `isMeta`, `cwd`, the message's role and content block types, and a `turn_duration` row's `durationMs` and `pendingBackgroundAgentCount`. Prompt text becomes `<prompt>` and the Project path becomes `/work/project`.

Each file opens with the transcript's first 12 rows: the header rows and the `/implement` prompt.

| File | Ends with |
|---|---|
| `just-launched.jsonl` | the prompt, before any assistant row |
| `mid-turn.jsonl` | an assistant `tool_use` row, its result not yet in |
| `waiting-on-agents.jsonl` | a `turn_duration` row with `pendingBackgroundAgentCount: 2`: the turn ended while two review agents ran, and their reports started the next turn |
| `turn-ended.jsonl` | the final summary and a `turn_duration` row with no pending agents, then `last-prompt` and `cost-state` |

`tests/supervise-last-message.test.sh` reads `turn-ended.jsonl`, `waiting-on-agents.jsonl` and `just-launched.jsonl` for the `last-message.sh` tests, filling each text block with a marker naming its row, since the fixtures keep no text.

The recorded worker entered a worktree during its run, and its whole transcript, including the rows written before that, was moved to the worktree's project folder. The rows after the move carry the worktree's `cwd`.

`shared-actions.jsonl` is cut differently, from the `/implement #66` worker that opened PR #72 (Claude Code 2.1.284), for the `actions.sh` tests. It holds only the rows for six Bash calls and their results, in order: a `gh issue view`, a `git commit` whose message names `git push`, the `git push origin HEAD:main` the auto-mode classifier refused, the `git push -u` of its own branch, a `gh pr create` refused for its runtime variable, and the `gh pr create` that opened PR #72. Each row keeps `type`, `isSidechain`, the message's role, each tool call's `id`, `name` and `command`, each result's `tool_use_id`, `is_error` and the first line of its content (the classifier's refusal cut to its first sentence), and the result's `toolUseResult.gitOperation`, which Claude Code records for a commit, push or PR. Home paths become `/work/project` and `/work/config`.

The job's `children` entry the tests add to `agents-json/job-state.json` is the one that worker's job recorded: `{"id": "72", "href": "https://github.com/ChristopherA/mp-ported-skills/pull/72", "kind": "pr"}`.

`hand-run.jsonl`, with its two subagents' transcripts in `hand-run/subagents/`, and `live-check-worker.jsonl` are cut for the `record.sh` tests in `tests/supervise-record.test.sh`. They come from two live sessions (Claude Code 2.1.285): an interactive `/implement` run by hand, and a background session launched in auto mode on a short prompt. They are cut differently from the fixtures above. Every conversation, `system` and `cost-state` row is kept. Each row keeps its `type`, `subtype`, `timestamp`, `isMeta`, `requestId` and `pendingBackgroundAgentCount`, the message's role, model and four usage counts, and each content block's type. A tool call keeps its name, and a `Skill` call keeps `input.skill`. A `cost-state` row keeps `totalCostUSD` and each model's four token counts and cost. Text becomes `typed text`, `<system text>` for text that starts with `<` or `[`, or the command's `<command-name>` element for a slash command.

The job for `live-check-worker.jsonl` is `tests/fixtures/jobs/1420c08b/`: its `state.json`, cut to the fields a script reads, with the folder and config paths as `/work/...`, and its `timeline.jsonl` as recorded.

