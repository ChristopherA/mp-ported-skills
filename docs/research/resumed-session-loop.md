# Can a resumed background session capture, clear and implement?

Question from #77: can one supervised background session run the maintainer's loop (`/implement #N`, `/capturing`, `/clear`, next step, `/implement #M`), each command sent by stop and resume, or does each ticket need a fresh background session, as ADR 0003 assumes?

Tested live on **Claude Code 2.1.286**, 2026-09-30, with `claude-sonnet-5`. The Project was a scratch git repo inside the Hub, with no remote and no tracker. The tickets were two no-op specs given as `/implement`'s arguments: create `hello.txt`, then `bye.txt`, and commit. One session was launched as `launch.sh` launches (`claude --bg --model claude-sonnet-5 --disallowedTools EnterWorktree --permission-mode auto '/mattpocock-skills:implement ...'`), and each later command was sent with `claude stop <id>`, then `claude --bg --resume <session id> '<command>'` with no other flags.

## Answers

1. **`/mp-ported-skills:capturing` as a resume prompt loads the skill, as a first prompt does.** The transcript gained a `<command-name>/mp-ported-skills:capturing</command-name>` record and the skill body, and the session ran the capture through to "Safe to clear: yes". No SessionStart hook ran on the resume (the plugin's hooks match `startup|clear|compact`), and no `No response requested.` turn was injected, since the session was not waiting on a question.

2. **`/clear` as a resume prompt clears the context and keeps the short id, but moves the conversation to a new session id.**
   - The context is fresh: the first call after the clear read 66,559 input tokens, against 67,450 for the brand-new session's first call.
   - The short id stays (`872473df`), and so do the saved flags (`--disallowedTools EnterWorktree --permission-mode auto --model claude-sonnet-5`).
   - The conversation continues in a new transcript, `projects/<cwd>/<new id>.jsonl`, opening with the `/clear` record and a `SessionStart:clear` hook run. `/clear` is a local command, so no model turn runs.
   - `claude agents --json` reports the new id as `sessionId` while the session runs, and the original id again once it is stopped. The job's `state.json` keeps the original id in `sessionId` and puts the new one in `resumeSessionId`.
   - `--resume <original session id>` after the clear woke the job and continued the **cleared** conversation, so the original id stays a stable handle for resuming.
   - The job's `name` and `intent` stay those of the first ticket ("hello.txt commit"), so `claude agents` and the Claude app show the first ticket's title for every later one.

3. **`/mattpocock-skills:implement ...` as a resume prompt after the clear loads the full skill.** The transcript holds the `<command-name>` record and the whole body ("Use /tdd where possible ..."), and the worker built and committed `bye.txt`. It ran `/code-review` but judged a one-line text file too small for its two review subagents, and reported both axes itself; that is the model's judgment on a no-op ticket, not a resume effect.

4. **`/next`'s question is still not in the transcript, but the job's `state.json` now holds it while it is pending.** Resumed with `/mp-ported-skills:next`, the session blocked on its question within 30 seconds (`agents --json`: `status: waiting`, `waitingFor: input needed`, `state: blocked`). The transcript had no `AskUserQuestion` record. `jobs/<id>/state.json` carried:
   - `needs`: `answer: <question> (<option> · <option> · ...)`
   - `block.questions[]`: each question's text and every option's `label` and `description`, the recommended one marked `(Recommended)` as `/next` writes it.

   `claude stop` sets both to `null`, so the question has to be read before the stop. This is a way to read `/next`'s answer, but #54's reason to skip `/next` still holds: its answer names a user-invoked command that the session cannot start, and `state.sh`'s `next:` line gives the same step with no session.

## Stop and resume, observed

- **A resume can start a copy even after `claude agents` shows no pid.** The first `/clear` resume, issued about a second after `claude stop` returned and the row dropped its `pid`, printed `session 872473df is already running in the background, so this started a copy as 17d1a711`. The same resume issued about a minute after that stop woke the original.
- **The copy lost the saved options.** Its job's `respawnFlags` were `["--model","opus"]`: no `--disallowedTools EnterWorktree`, no auto mode, and a different model from the one the supervisor chose. A copy is not only a split worker; it is one that runs without the launch's guards.
- **What a finished stop looks like is not consistent.** After three stops of the same session: once `agents --json` showed `state: working` with no pid while `state.json` said `done`; once both said `stopped` within a second; once neither said `stopped` within 30 seconds, and the resume issued after that woke the original. The process exit (`ps -p <pid>`) was quick every time. No single reading marked "safe to resume".

## Side finding: background sessions are made to work in a worktree

The background service's system prompt in 2.1.286 tells a session to call `EnterWorktree` before its first edit, and enforces it. The worker's first `Write` in the checkout was refused:

> This background session hasn't isolated its changes yet. Call EnterWorktree first so edits land in a worktree instead of the shared checkout, then retry this edit using the worktree path (a path inside a linked git worktree, including one you create with `git worktree add`, is accepted). (To disable this guard for this repo, set `"worktree": {"bgIsolation": "none"}` in .claude/settings.json.)

With `EnterWorktree` denied, as `launch.sh` denies it, both workers ran `git worktree add .claude/worktrees/<name> -b implement-<name>` from Bash and committed there, while the session's `cwd` stayed the Project folder. `launch.sh`'s checks and `watch.sh`'s `moved` state both read the session's `cwd`, so neither sees it, and the commits sit on a branch nobody pushes, which is what `/supervise`'s policy that a worker stays in the Project folder exists to prevent. The second worker's branch started from `main`, not from the first worker's unmerged branch.

The guard names its own switch, `"worktree": {"bgIsolation": "none"}` in the Project's `.claude/settings.json`. Whether setting it keeps a worker in the checkout is untested here.

## Recommendation for #59: a fresh background session per ticket

Per ticket, the loop in each shape:

| | Same session, `/clear` by resume | Fresh session per ticket |
|---|---|---|
| Stop-and-resume cycles | 3: `/capturing`, `/clear`, `/implement #M` | 1: `/capturing`; then stop, `claude rm`, and a new `claude --bg` |
| Context at the next ticket | fresh (66.6k first call) | fresh (67.5k first call) |
| Cost | the same model turns; `/clear` runs none | the same model turns |
| Ids the maintainer follows in the Claude app | one short id, titled with the first ticket for every ticket | one per ticket, titled with its own ticket |
| Transcripts per session | one per ticket, under ids the job only partly records (`sessionId` keeps the first, `resumeSessionId` the latest) | one, under the job's `sessionId` |

- **Cost does not decide it.** A clear by resume gives the same fresh context as a new session, and neither shape adds a model turn the other lacks.
- **Copy risk decides it.** Every stop and resume is a chance to start a copy (ADR 0003), and a copy here ran without the deny, auto mode or the chosen model. The same-session loop takes three of them per ticket, the fresh-session loop one.
- **The record breaks in the same-session loop.** `actions.sh` and `record.sh` find the transcript by the job's `sessionId`, which after a clear is the first ticket's transcript. They would report the first ticket's actions and cost for every later ticket unless they learned to follow `resumeSessionId` across clears.
- **One id is the same-session loop's only gain**, and its title names the wrong ticket.

So #59 should keep ADR 0003's shape: on `done`, resume the finished worker once with `/mp-ported-skills:capturing`, then stop and `claude rm` it, and launch the next ticket with `launch.sh` in a new session.

Before #59 loops, the worktree guard above has to be settled. With it on, every ticket in the loop lands on its own unpushed branch, and the "finished ticket has not landed" stop fires after every ticket.
