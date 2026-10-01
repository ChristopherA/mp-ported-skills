# agents-json fixtures

Recorded output of `claude agents --json --all` from Claude Code 2.1.284, one
file per background-session state, for `tests/supervise.test.sh`. Each was
captured from a live `claude --bg --model claude-sonnet-5` session:

| File | Background session record |
|---|---|
| `working-idle.json` | just launched: `status: idle` but `state: working` |
| `working-busy.json` | `status: busy`, `state: working` |
| `blocked-input-needed.json` | stopped at a question it asked: `state: blocked`, `waitingFor: input needed` |
| `blocked-permission-prompt.json` | launched with `--permission-mode default`, stopped at a Bash prompt: `waitingFor: permission prompt` |
| `done.json` | finished its turn: `status: idle`, `state: done`, still live |
| `stopped.json` | after `claude stop`: `state: stopped`, no `status` or `pid` |
| `working-moved.json` | `working-busy.json` with the background session's `cwd` edited to a worktree under `/work/project/.claude/worktrees/`, as a worker that called `EnterWorktree` reports |

The interactive sessions listed beside each one are kept, so the watcher is
tested against a list it has to pick its session out of. Their paths and names
are replaced with `/work/...` and placeholder names; ids are as recorded.

`job-state.json` is a background job's `state.json` from
`<config dir>/jobs/<id>/`, cut down, with account and bridge ids removed. It
is not a plain recording: the recorded job ran in default mode on a `date`
prompt, so `respawnFlags` is edited to auto mode with `EnterWorktree`
disallowed, in the order a live launch recorded them, and `intent` and `name`
to an `/implement` launch, and `needs` is left out for each test to add. A
recorded `needs` read `approve Bash: mkdir -p <path>`.
