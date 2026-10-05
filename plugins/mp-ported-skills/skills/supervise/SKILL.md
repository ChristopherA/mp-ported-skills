---
name: supervise
description: Run a Project's next ready-for-agent ticket, or with --loop each next one in turn, through the full /implement in a Claude Code background session, and report done or blocked.
disable-model-invocation: true
---

Run one ticket in a Project, from the Hub or from inside the Project, as the maintainer would by hand: read the next step, start `/implement #N` in a fresh session, watch it, and report. The worker is a Claude Code background session (`claude --bg`), whose first prompt enters through the human's door, so the ticket gets the full `/mattpocock-skills:implement`, its TDD and its own `/code-review` (ADR 0003). One ticket, then stop; with `--loop`, the next ticket after each one that lands, until a rule stops it (Loop, below).

The Project folder, relative to this session's folder or absolute, is the first word here (`.` when this session runs inside the Project); `--model <id>`, `--effort <level>`, `--watch tmux` or `--watch iterm`, and `--loop` may follow: $ARGUMENTS

## Policy

The supervisor drives build-loop defaults and nothing else:

- **It may**: take the step `state.sh` names, launch `/implement #N` for a `ready-for-agent` ticket, watch the worker, send it a build-loop follow-up (Follow-ups, below), answer a routine question its policy already decides (Routine answers, below), and stop a worker that finished or failed a launch check.
- **It stops for anything that changes the spec**: any other step, any other question the worker asks, a permission prompt, a ticket that needs a decision. It reports these and answers none of them. The human answers in the worker with `claude attach <id>`, or in the approval request the Claude app shows for the worker's permission prompt.
- **Shared actions are gated on standing grants, never on the worker's own say.** A push, PR, issue close, issue comment or new issue that `/implement` or a capture reaches is refused by a PreToolUse hook (#66) unless a grant in the Project's `docs/agents/supervision.md` covers it, read only from the default branch as committed on origin -- never the worker's working tree or local commits, which a worker can reach without the maintainer seeing it, and never the worker's to add (#58, docs/adr/0005). With no such file, or no matching grant, the push stops for approval exactly as before; in a background session the `git` and `gh` wrappers below refuse it outright, in any permission mode. `launch.sh` tells the worker, in an `--append-system-prompt`, which shared actions its Project grants, from the same source through `grant.sh`, that a granted one goes ahead without asking, and that any other ends its turn on one line, `Waiting on: <action>`, without trying it (#88): without that, a worker asks before every push and the run stalls at `blocked` with a grant in place. With one, the worker's own attempt goes through, and `actions.sh`'s report (step 4) cites the grant on that line instead of marking it `ungranted`; the report still lists every shared action the worker took, granted or not, in case a form got past the hook or an older worker predates it. A second hook (`deny-worker-grant-edits.sh`) refuses a worker's own Edit, Write or NotebookEdit to that grant file, and to anything under this session's own profile directory, so a worker cannot grant itself one or change what gates it. A push from inside a script, which the hook cannot see, meets the same check in the `git` and `gh` wrappers a SessionStart hook puts first on a background session's PATH (docs/adr/0006). A push no grant covers, which the worker ends its turn waiting on, is the supervisor's to make, and only on the maintainer's go-ahead given in this session, after checking it (Push on approval, below; docs/adr/0007). A message typed into the worker is not a grant, and the hook refuses the worker's push after one.
- **The supervisor stays read-only in the Project while a worker runs**, whether it runs from a parent folder or inside the Project, where the two share one working tree. No file edits, and no git `commit`, `merge`, `rebase`, `checkout`, `switch`, `reset` or `stash` there; reads, `gh` and these scripts still run. `launch.sh` marks the checkout with the worker's id, a PreToolUse hook (#76) refuses those calls in any attended session while the mark is there, the maintainer's own included, and `release.sh` clears it in the Report step. A refusal names the worker and `claude attach <id>`.
- **A worker stays in the Project folder, on its branch, for the whole run**: its commits would otherwise land on a branch nobody pushes. It is launched without the `EnterWorktree` tool and with the background service's worktree guard off (`bgIsolation: none`), so its edits in the folder are not refused. It is stopped at launch if the background service placed it elsewhere, and the moment `watch.sh` sees it leave the folder, or sees a worktree or branch made in the Project's repo since the launch.
- **A worker that stops making progress is reported, not stopped.** `watch.sh --stall` (step 3) reports `hang` when the worker's transcript has not grown in that long, distinct from a permission prompt or a question: the worker is left running, since a long tool call can hold the transcript steady in its own right, so this is a "no progress for a while" signal, not proof of a real hang.

## 1. Step

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/step.sh" "<project folder>" </dev/null
```

It runs `resuming`'s `state.sh` in the folder and reads the `next:` line. `implement #N` means the step is `/implement` of a `ready-for-agent` ticket with nothing else in flight: go on. `stop: ...` means any other step, including work in flight in git: report the line and end here.

Then read the ticket's body and every comment (`gh issue view N --json title,body,comments`, run in the folder), and record where the branch starts, for the report, and the repo's worktrees and branches, for `watch.sh`:

```sh
git -C "<project folder>" rev-parse HEAD
sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --dir "<project folder>" --snapshot > "<scratchpad>/snapshot.txt" </dev/null
```

## 2. Launch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N </dev/null
```

Add `--model <id>` when the user gave one; the default is `claude-sonnet-5`, and a model without auto mode (Haiku) is refused. Add `--effort <level>` (`low`, `medium`, `high`, `xhigh` or `max`) when the user gave one; without it the worker runs at the model's default effort. It sets `CLAUDE_CONFIG_DIR` to this profile for the worker, launches in auto mode with `--disallowedTools EnterWorktree,Artifact,Workflow,ScheduleWakeup,SendFeedback`, `--no-chrome`, `--settings '{"worktree":{"bgIsolation":"none"}}'` and the grants text in `--append-system-prompt`, names the worker `worker <project> #N: <ticket title>` with `--name` (cut to 80 characters), so `claude agents` and the Claude app tell workers apart (#103), and reads the job's `state.json` to confirm the worker got this profile, the folder itself rather than a worktree, auto mode, the `EnterWorktree` deny, the setting, the grants text, the name, the effort, the unused-tools deny and `--no-chrome`. Beyond `EnterWorktree`, the deny list and `--no-chrome` drop tools a worker never uses (publishing a page, workflows, `/loop` wakeups, feedback drafts, the user's browser), which took 19.5k tokens of its context before its first step (#130, `docs/research/worker-fixed-load.md`). The name survives the session-title hook at startup and a `resume.sh` wake; a `/clear` in the worker, which runs that hook again, is untested. When `gh issue view` cannot read the title, the name leaves it out and a `note:` line on stderr says so; report that line. A grant committed but not on origin is left out, and `grant.sh` names it on stderr as `note: ... ignored`; report that line. Without the setting, Claude Code 2.1.286 refuses a background worker's edits in the folder until it isolates, and a worker denied `EnterWorktree` makes its own worktree with `git worktree add` (#83). First it checks the Project is on its default branch, with a clean tree and no other live background session in it, and refuses otherwise: report the error, since a dirty tree or a branch is the maintainer's to settle. Once the worker passes its checks it writes the worker's id to the checkout's marker (`git rev-parse --git-path mp-supervise-worker`), which holds this session read-only there. It prints the worker's short id. Exit 1: nothing launched, report the error. Exit 2: the worker failed a check and was stopped, report the error with the id.

With `--watch tmux` or `--watch iterm`, open the worker's viewer now (Watching, below).

## 3. Watch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --id ID --dir "<project folder>" --since "<scratchpad>/snapshot.txt" </dev/null
```

Run it with the Bash tool's `run_in_background`, since a ticket outlasts a foreground call, and wait for its completion notice. It polls `claude agents --json --all` every 30 seconds while the worker is `working`, and returns at the first other state, with the worker's `cwd` on the next line and, for a blocked worker, a `needs` line naming what it waits for. A working worker whose `cwd` is no longer the Project folder returns at once as `moved`. So does a working or done worker when the Project's repo has gained a worktree, or a branch other than the folder's has been made or moved, since the snapshot: a worker can make a worktree from Bash and keep its `cwd` in the folder. Each one is listed after the state as `worktree <path>`, `branch <name>`, and a `commit <sha> <subject>` line for each of the branch's commits, or a detached worktree's, that the folder's branch lacks. Any state can carry these lines, and a `note` line when the repo was not read. They count every worktree and branch made since the launch, the worker's or not. The one exception is a worktree the Claude app made and locked for its own bridge session in the same Project during the run (`.claude/worktrees/bridge-<session id>`, locked `claude agent bridge-<session id> (pid ...)`): `watch.sh` lists it as `other <path>` instead, leaves its branch out of the branch lines, and does not turn a working or done worker into moved for either. Report an `other` line as another session's worktree, not the worker's, and do not stop the worker for it. `claude agents` can go on saying `working` for hours after the worker's turn ended, so `watch.sh` also reads the worker's transcript and returns `done` when it shows the turn ended with no background agents pending, adding the line `note claude agents still said working`. A watch that follows `resume.sh` passes `--after <epoch>` from its `after` line (Follow-ups, below). With it, only what the worker wrote at or after that time counts: `done` needs a turn end in the transcript that late, whether the transcript or `claude agents` says done, since the list can still show the previous turn's `done` for a moment after the resume (a `done` from the list stands when no transcript is found), and a `Waiting on:` line counts only in text that late (#122, #126). A worker whose turn ended on a line starting `Waiting on:`, as `launch.sh` tells it to end on a shared action no grant covers, returns as `blocked input needed` instead, with that action as the `needs` line (#88). The same holds when `claude agents` already shows that worker as blocked with nothing named as waited for: a `Waiting on:` line in its last text makes it `blocked input needed`, and the action it names replaces the job's own `needs` summary, which can name a side question from the worker's report (#97). A worker `claude agents` shows as blocked with nothing named, whose last text has no `Waiting on:` line and ends on a statement rather than a question, returns as `done` with the line `note claude agents said blocked`: a finished report that quotes a decision, such as a capture listing a draft ticket, reads to `claude agents` as a question (#114). `record.sh` likewise does not count such a block as a wait on a human. A working worker whose transcript has not grown in 30 minutes (`--stall` changes this) returns as `hang`, with a `note` line naming how long, rather than waiting out the full timeout (#58): a long tool call can hold the transcript steady in its own right, so this is a signal to report, not proof the worker is stuck. After 4 hours it exits 124 with the last state (`--timeout` changes this).

## 4. Report

One report, by the first line `watch.sh` printed. A `blocked question` or `blocked input needed` first goes through Routine answers, below; only one it does not answer is reported by the items here. Whatever the outcome, it lists the shared actions the worker took, with `<cwd>` from `watch.sh` and `<start>` from step 1. For a settled run, take them after the capture and any push (Capture, below), since the capture can take shared actions of its own:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/actions.sh" --id ID --dir "<cwd>" --start <start> </dev/null
```

It prints one line for each PR or issue in the worker's job, each remote branch holding its commits, and each push, PR or issue command in its transcript or a subagent's, with whether it `succeeded`, was `refused`, `failed` or has `no result`. A command counts when the #66 hook would refuse it, when it runs a `gh pr` or `gh issue` subcommand that is not read-only, or when Claude Code recorded a push or PR on its result. It prints `none` only when it found nothing and read every source. A branch or command line is marked `granted (<citation>)` when a standing grant in `docs/agents/supervision.md` covers it, read only from the default branch as committed on origin (#58); otherwise `ungranted`. A branch line reads `pushed by the supervisor on the maintainer's approval` instead when `push.sh` pushed it for this worker (Push on approval, below). It reads `pushed by someone else`, neither granted nor ungranted, when no call in the worker's transcripts that succeeded or has no result pushed to it, such as a branch the maintainer pushed from their own terminal; a refused or failed push of the worker's does not count (#98). When a transcript could not be read, the branch is read as the worker's. Report a `granted` line too -- it is what the maintainer's standing grant already approved, not something to re-approve -- report every `ungranted` line as a shared action the maintainer did not approve, a `pushed by someone else` line as no action of the worker's, and every `note` line as a source that was not read, never as no actions.

- **`done`**: the ticket and its commits, `git -C <cwd> log --oneline <start>..HEAD`, the shared actions, and whether the ticket is closed (`gh issue view N --json state`). `done` means only that the worker's turn ended: with no commits and the ticket open, read its last output (below), since it may have ended on a question asked in plain text, and report that as blocked with `claude attach ID`. Otherwise the work is settled: send the capture first (Capture, below), unless this `done` is the capture's own. Then stop the worker, which is still live, and release its marker, with `stop.sh` (Stopping, below). When `cwd` is not the Project folder, say the commits sit in that checkout, on a branch nobody pushes, and send no capture: the worker is out of its folder, as for `moved`.
- **`moved`**: stop the worker at once, and release its marker, with `stop.sh` (Stopping, below). Report where it went: the `cwd` line, with its commits there, `git -C <cwd> log --oneline <start>..HEAD` on `git -C <cwd> branch --show-current`, when `cwd` is not the Project folder; and every `worktree`, `branch` and `commit` line. Say the commits sit on a branch nobody pushes. A worktree inside the Project folder, such as one under `.claude/worktrees/`, also leaves its folder untracked there, so `state.sh` reports work in flight until the maintainer removes the worktree; say so. Moving or salvaging the commits is the maintainer's. An `other` line alongside these is still another session's worktree, not the worker's; report it as such, not as part of why the worker moved.
- **`blocked input needed`** whose `needs` line is a `git push` no grant covers: the work is settled. Send the capture first (Capture, below), unless this block is the capture's own, then follow Push on approval, below, instead of the rest of this item. Do not tell the maintainer to push from a terminal, with a `!` command, or by telling the worker: the first two do not work from a remote client, and the hook refuses the third.
- **`blocked permission prompt`**, **`blocked input needed`**, **`blocked question`**: what it waits for (the `needs` line), the id, and the command to open it, in a fenced code block of its own:

  ```sh
  claude attach ID
  ```

  `input needed` is a question the worker asked and is waiting on an answer to, or a shared action no grant covers other than a push, which the `needs` line names: the maintainer takes it in their own session. `question` is a worker that ended its turn on a question asked in plain text, which `claude agents` shows as blocked with nothing named as waited for; the `needs` line holds the question when the job names one, and with none, report its last output (below) instead (#85). Leave the worker running, and its marker in place. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`hang`**: the id, the `note` line naming how long its transcript has not grown, and `claude attach ID` to look. Leave the worker running, and its marker in place -- this is a "no progress for a while" signal, not confirmation the worker is actually stuck, since a long tool call can hold the transcript steady on its own. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`stopped`**: the id, and that `claude attach ID` reopens it, which starts it again. Release its marker (below).
- **`gone`**: the id; the session was removed and there is nothing to open. Release its marker (below).
- **`unknown ...`**, or exit 124: the state, the id, and its last output (below). Exit 1: `claude agents` could not be read, so the worker's state is unknown; report that, never that it is gone.

### Stopping

Stop a live worker the policy says to stop (after `done`, `moved`, and in Push on approval) with `stop.sh`, never a bare `claude stop ID`, and pass the Project folder, not the worker's `<cwd>`, since the folder's repo holds the marker even when the worker has moved:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/stop.sh" --dir "<project folder>" --id ID </dev/null
```

In the #90 run, the auto-mode classifier refused the supervisor's bare `claude stop` of its own finished worker as interfering with a running job (#132), likely reading it against the maintainer's earlier words that a stuck worker must not just be stopped; `resume.sh`'s own stop in the same run went through. So the stop goes through a script, as `resume.sh`'s does, whose command names the job as the worker this session launched and checks it before stopping anything: the job is in this profile's `jobs/`, and the folder's marker names it or is gone. A permission allow rule was the other way: it would allow every `claude stop` from this profile, not only of its own worker, and it is a settings edit the maintainer would have to make by hand. `stop.sh` stops the worker, waits until `claude agents` shows it stopped or gone, or has shown no pid for 60 seconds (`--settle`), so its cost row is written before `record.sh` reads it, then releases its marker. It prints `stopped ID` (or `gone ID`), then `released ID` or `no marker in <folder>`. Exit 1, in two kinds: a check failed first (the marker names another worker, or the job is not this profile's) and nothing was stopped, which the error says; or the worker was not seen to stop, or was stopped and its marker not released, and the error says whether the checkout is still read-only and ends on a `finish with:` line, the command that finishes the run.

When the stop is refused, by the classifier or a permission prompt, or `stop.sh` exits 1 with a `finish with:` line, do not route around it and do not stop mid-report. Go on with the report and say in it: the stop was refused, and why; whether the worker is still live and its marker still holds the checkout read-only for commits; that the run record waits on the stop, since the worker's cost is written then; and the one command that finishes the run, the `finish with:` line or, for a refusal, the `stop.sh` command above, in a fenced code block of its own. Then ask the maintainer, in one question, whether to run it again. On an explicit yes given in this session, run it, and go on from where the stop was called: the rest of the Report step (viewer, record) after `done` or `moved`, or step 2 of Push on approval, whose check refuses while the marker is held. A retry after the maintainer's approval in the session went through in the #90 run.

To read a worker's last output, print its last message from its transcript, which `last-message.sh` finds by the job's `sessionId` in any project folder, since a worker that entered a worktree has its transcript moved:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/last-message.sh" --id ID </dev/null
```

`--count N` prints its last N messages, oldest first. A `note:` line says when the message may not be the worker's last word: its turn ended with background agents pending, whose reports start another turn, so the message is often an interim "waiting for agents" note; or its turn has not ended. Report it as such, not as the worker's summary. Exit 1, with nothing printed but an `Error:` line, means no message was read (no such worker, no transcript, or none written yet); report that, never an empty output as the worker's.

Not `claude logs ID`: it prints the worker's raw terminal stream, cursor moves and colour codes included, which reads as noise (`[42B[38;2;215;119;87m✻`) rather than as the worker's words.

Release the marker whenever the worker was stopped or is gone, and `stop.sh` did not already, so the checkout is writable again and the next launch finds no stale mark (a stale one does not block `launch.sh`, but it keeps the hook refusing):

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/release.sh" --dir "<project folder>" --id ID </dev/null
```

It prints `released ID`, or `no marker in <folder>`. Exit 1: the marker names another worker, or the folder is not a checkout; report it and leave the marker.

With `--watch tmux`, once the worker is stopped or gone, remove the tmux session too, so the run leaves none behind:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --close </dev/null
```

It prints `closed mp-supervise`, or `no tmux session mp-supervise` when the window already closed with the worker. With `--watch iterm`, close the pane instead, with the coordinates `view.sh` printed when it opened it:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --close --pane '<session> <window> <tab>' </dev/null
```

It prints `closed pane <session>`, or `pane <session> already closed` when iTerm2 closed it with the viewer. It closes the pane whatever runs there, so never call it while the worker runs. While the worker is left running (`blocked`, `hang`), leave its viewer open, in either mode: it is where the maintainer answers.

Then record the run, whatever the outcome, with the same `<cwd>` and `<start>` and the ticket's number. For a settled run, record it after the capture and any push, once the worker is stopped, so its `captures and clears` field counts the capture and its shared actions show the push:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/record.sh" --id ID --dir "<cwd>" --start <start> --ticket N > "<scratchpad>/run-record.md" </dev/null
```

It prints the record as a Markdown list: the worker's model, launch and turn-end times, how long after the turn end this report came, API calls, tokens and cost by model, this session's own calls, tokens and cost since the launch, the peak zone reading and the call that first reached 100% of the zone, captures and clears, the questions the supervisor answered (Routine answers, below), waits on a human (a wait the supervisor answered is not one, nor a block that follows a turn ending on a statement, which `watch.sh` reads as `done`) and messages typed into the worker, the shared actions from `actions.sh`, and the outcome. A field whose source was not read says `unknown`, with a `note` line naming the source. The supervisor's own cost reads `unknown` while this session runs, because a running interactive session's transcript holds no cost row yet; its calls and tokens are still counted. Post it on the ticket, run in the Project folder, and include it in the report:

```sh
gh issue comment N --body-file "<scratchpad>/run-record.md"
```

`record.sh --session <session id>` in place of `--id` records a plain interactive session, such as a hand-run `/implement` of a ticket the same size, leaving out the job's fields: that is the baseline a supervised run is compared against.

## Capture

A worker whose work is settled ends with `/mp-ported-skills:capturing` in its own session, before any push and before it is stopped for good: only that session holds what it decided and learned. A peaked zone, a long ticket, or a context near or past compaction is no reason to skip it or move it to a fresh session.

- **When:** as soon as the work is settled, before any push: after `done` with the work committed, and after `blocked input needed` whose `needs` line is a `git push` no grant covers.
- **Not** after `moved`, `hang`, any other block, `stopped` or `gone`, nor after `done` with `cwd` outside the Project folder: a worker left running is the maintainer's to answer, and one out of its folder is stopped as it stands.

Capturing after the push cost a second round of Push on approval each time the capture committed (#67, #98), and its report then described push state from before the push. So the capture goes first, and one push covers the work and the capture's commits.

1. Take a fresh snapshot, since the worker's first watch is over:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --dir "<project folder>" --snapshot > "<scratchpad>/snapshot-capture.txt" </dev/null
   ```

2. Send the capture as a follow-up (Follow-ups, below), and with `--watch tmux` or `--watch iterm` open the viewer again once it prints `resumed ID`:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "/mp-ported-skills:capturing" </dev/null
   ```

3. Watch it as in Watch (section 3), with `--since "<scratchpad>/snapshot-capture.txt"` and `--after <epoch>` from the `after` line `resume.sh` printed, and go on by its first line:
   - **`done`**, with nothing waiting on a push: the Report step for `done`, with no second capture.
   - **`blocked input needed`** on a `git push` no grant covers: the capture committed, or the work was already waiting on the push. Push on approval, below, once, over everything from `<start>` to HEAD.
   - **`blocked question`** with no `Waiting on:` line: the capture's last text ends on a question to the maintainer; report it as the Report step says for `blocked question`. A capture that only lists its unposted findings, one ending on a decision, returns as `done` with `note claude agents said blocked` (#114), and goes on as for `done`.
   - **Any other state**: the Report step for that state.
4. Pass on the capture's report, from its last output, in this run's report:
   - its unposted findings, and its ungranted before-clear jobs, as items for the maintainer, leaving out any the supervisor then does itself (the push, a plugin update);
   - its next step, and when that differs from what `step.sh` now prints for the folder, say so and give `step.sh`'s;
   - push state as it stands after Push on approval, not as the capture described it: the capture wrote before the push.

## Push on approval

A worker blocked on a `git push` no grant covers has finished its work and committed it. The capture runs first (Capture, above), so this runs once, after it, over the work and any commits the capture made. The supervisor checks the commits, asks the maintainer once, and on a yes pushes them itself, so the push needs no terminal and no `!` command and works from a remote client (docs/adr/0007).

1. Stop the worker and release its marker, with `stop.sh` (Stopping, above). With `--watch tmux` or `--watch iterm`, close the viewer.
2. Check, without pushing:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/push.sh" --dir "<project folder>" --id ID --start <start> --sweep "<sweep command>" --check </dev/null
   ```

   `<sweep command>` is the maintainer's public-artifact sweep, which takes `--range A..B`, as named in their own instructions; `push.sh` runs it in the folder with the range appended. With none named, pass `--no-sweep` and say in the question that the range was not swept. It prints the branch and its upstream, a `commit` line for each commit to go, and an `ok` or `fail` line for each check: no worker marker in the checkout, a clean tree, a fast-forward onto the upstream after a fetch, the worker's start already on the upstream, every plugin version change a patch bump at most, and the sweep. Exit 2: a check failed. Report each `fail` line, and the sweep's indented output, and stop there: do not push, and do not ask. Exit 1: report the error.
3. All checks passed: ask the maintainer one question, with the commits and the `ok` lines in it: push these commits to the upstream, or leave them. Ask nothing else in the same question, and take only an explicit yes given in this session as the go-ahead. A no, or no answer, leaves the commits local; report them as unpushed.
4. On a yes, push:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/push.sh" --dir "<project folder>" --id ID --start <start> --sweep "<sweep command>" </dev/null
   ```

   It runs every check again, pushes only the checked commit, to the branch's upstream, and prints `pushed <upstream> A..B`. It records the push in the checkout, so `actions.sh` names the branch as pushed by the supervisor on the maintainer's approval, not as the worker's. Exit 2: a check failed since the question; report it and push nothing. Exit 3: the push failed; report its error. If a permission check refuses the push, report the refusal and stop. Do not route around it.
5. When a `version` line showed a bump of a plugin this profile has installed, update it through Bash: `claude plugin marketplace update <marketplace> && claude plugin update <plugin>@<marketplace>`, and report the version it installed.
6. Go on with the Report step for `done`, with no second capture: the shared actions, the ticket's state, the capture's report and the run record, taken now, after the capture, the stop and the push, so the record carries the worker's cost, the capture and the push.

## Loop

With `--loop`, the supervisor runs the maintainer's manual loop: tickets one after another, never in parallel, each in a fresh background session (#77, ADR 0003). Without it, one ticket, then stop.

A ticket's run goes on to the next only when all of these held: its watch, after any routine answers, came to `done` with its work committed; its capture ran (Capture, above) and came to `done`; its work landed on the default branch's upstream, by the worker's own push under a standing grant or by Push on approval on the maintainer's yes; `stop.sh` exited 0, so the worker is stopped and its marker released; and its run record is posted on its ticket. Any other outcome ends the loop at that ticket, reported by the Report step for it, with the condition it stopped on, the worker's id and the ticket: a permission prompt, a question, a block on an action no grant covers, a declined or failed push, a `moved`, `hang`, `stopped` or `gone`, a failed launch or launch check, a stop that was refused or exited 1 (ask, as Stopping says, and on a yes go on from there), or a ticket the worker did not finish.

Between tickets, read what comes next, passing every ticket this loop ran:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/next.sh" --dir "<project folder>" --ran "<N M ...>" </dev/null
```

It fetches, then prints `next implement #M` (exit 0): go back to step 1 for #M, reading its body and comments, recording its start and taking a fresh snapshot, then Launch, which runs the one-session-per-checkout check again, so a session from the previous ticket still live refuses the launch (#57). Or it prints `stop <kind>: <detail>` (exit 2), and the loop ends there:

- `held`: the checkout's marker still names a worker, so a stop did not finish.
- `not-landed`: uncommitted paths, no upstream, or commits the upstream lacks. The next ticket starts from the default branch as pushed, so the loop waits for the maintainer rather than stacking work.
- `behind`: the upstream moved on, so the next worker would start from an old commit.
- `nothing-left`: `state.sh`'s next step is nothing in motion.
- `other-step`: any other step than `/implement` of a `ready-for-agent` ticket.
- `repeat`: `state.sh` still recommends a ticket this loop already ran, which happens when its work went in without `Closes #N`; running it again would rebuild it.

Exit 1: report the error, and end the loop.

Leaving the supervisor's zone is not yet a stop condition (#78), so expect a two-ticket loop to end past it; say so in the report when the session's peak zone reading passed 100%.

The final report lists every ticket the loop ran, in order: its number, the worker's id, its outcome, its commits, the shared actions, the capture's report and the run record's comment; then the condition that ended the loop, with the worker's id and the ticket it stopped on, or `next.sh`'s `stop` line.

## Routine answers

Some questions a worker asks are ones the policy already decides: confirming the ticket it was launched on ("Proceed with #N?"), and asking for a shared action a standing grant covers (#58), which `launch.sh` told it to take without asking. For a `blocked question` or `blocked input needed`, before anything in the Report step, ask:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/answer.sh" --id ID --dir "<project folder>" --ticket N --state "<watch.sh's first line>" > "<scratchpad>/answer.txt" </dev/null
```

It reads the question from the worker's transcript: a pending AskUserQuestion with one question, a last line `Waiting on: <command>`, or the last sentence of its last message when that ends on the only `?` in it. Only two kinds are routine. A confirmation of ticket N is the whole sentence, naming no other ticket. A shared action (push, PR create or merge, issue close, comment or create) is the question's opening verb, the only action it names, and one `grant.sh` finds granted on origin's default branch. A question that offers a choice (" or "), names another ticket, or is anything else goes to the maintainer, as does a permission prompt and an action no grant covers. A question the supervisor answered once and the worker asks again is not answered twice.

- **Exit 0**: it printed `question <q>`, `rule ticket` or `rule grant <citation>`, and `answer <prompt>`. Send the prompt as a follow-up (Follow-ups, below), watch again with `--after`, and go on by the new watch's first line:

  ```sh
  sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "$(sed -n 's/^answer //p' "<scratchpad>/answer.txt")" </dev/null
  ```

  The prompt starts `[supervisor answer to "<q>"]`, which `record.sh` lists under `supervisor answers`, apart from human interventions. List each question answered and its answer in the report.
- **Exit 2**: `not routine: <why>`, after `question <q>` when one was read. Report the block by the Report step's items, as before, with `claude attach ID`, adding the `why` line.
- **Exit 1**: report the error, and the block as before.

## Follow-ups

No command sends input to a running background session, so a follow-up to a worker, such as the capture (Capture, above), goes by stop and resume:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "<prompt>" </dev/null
```

It stops the worker, waits until `claude agents` shows it `stopped` or has shown no pid for 60 seconds (`--settle`), and resumes the job's original session id with the prompt and no flags. It refuses while another background session is live in the same checkout, naming each. A resume that starts a copy instead of waking the worker loses the launch's EnterWorktree deny, auto mode and model, so the copy is stopped and removed at once, the worker stopped again, and the resume retried, up to 3 times (`--tries`). It prints one line for each copy, then `after <epoch>` and `resumed ID`; name every copy in the report. On a wake it writes the worker's marker again, since the worker is live again, and prints a `note` line first when it could not; report that line. Release the marker again once the follow-up's worker is stopped. The id stays the same, so watch it again with `watch.sh`, adding `--after <epoch>` from the `after` line. Right after the resume, the worker's transcript still ends on the turn that ended before the stop, and a watch without `--after` reads that as the follow-up's turn ending and returns `done` while the follow-up still runs (#122). With it, only a turn end written at or after that time counts. Then, with `--watch tmux` or `--watch iterm` open its viewer again (Watching, below) once `resumed ID` is printed, never before. Exit 1: nothing resumed, report the error. Exit 2: every try started a copy; each was removed, the worker is left stopped, and the error names them all.

## Watching

With `--watch tmux`, the maintainer can watch the worker in tmux. Open a viewer once after `launch.sh` succeeds and once after each `resume.sh` that printed `resumed ID`:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --id ID --dir "<project folder>" </dev/null
```

It opens a window in the tmux session `mp-supervise` whose own command is `claude attach ID`, so the window closes by itself when the worker is stopped, and the session ends with its last window. It prints the window and the watch command. Pass both lines on in the next message to the maintainer, with the rule below. Exit 1: no viewer opened, for the reason it names. Report it and go on: the run does not depend on the viewer.

With `--watch iterm`, the viewer is an iTerm2 split pane beside this session, opened at the same times, with nothing to attach by hand:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --iterm --id ID --dir "<project folder>" </dev/null
```

It splits this session's pane through `iterm-pane`'s `pane-open.sh`, and the pane's first command changes into the folder and runs `exec env CLAUDE_CONFIG_DIR=<this profile> <claude> attach ID`, since the pane's login shell does not inherit the profile. The pane's shell ends with the viewer, so under a profile that closes a session when it ends (iTerm2's default profile does) the pane closes by itself within a few seconds of the worker's stop (seen live on Claude Code 2.1.288, #102). The Report step closes it in any case, since run within a second of the stop it can still find the pane open. It prints `viewer iterm pane <session> <window> <tab> runs claude attach ID` and the `close:` command; keep the coordinates for that command, and pass both lines on to the maintainer. Exit 1: no pane opened, with one line naming why: this session runs inside tmux, is not in iTerm2, or was started by the `claude remote-control` server from the app (its terminal is the server's own pane), or `pane-open.sh` failed. Report that line and go on without a viewer.

Never open a viewer at any other time, and never in a loop. Attaching wakes a stopped session, so a viewer opened between `resume.sh`'s stop and its resume makes the resume start a copy and splits the worker (#55).

Tell the maintainer, with the watch command (`tmux attach -t mp-supervise`, or `tmux -CC attach -t mp-supervise` in iTerm2) or the pane:

- the viewer is live: what they type there reaches the worker as a prompt, and answering a permission prompt there is fine;
- attaching to the worker by hand (`claude attach ID`, or a viewer of their own) between a stop and a resume splits the worker. Leaving the tmux session (`Ctrl+B d`) is always safe; with `--watch iterm`, leave the pane for the supervisor to close.

Done when the report names the ticket (with `--loop`, each ticket the loop ran, and the condition that ended it), the outcome, each question the supervisor answered with its answer, the shared actions (or `none`), either its commits or the id with `claude attach`, the capture's report for a settled run, and the run record's comment.
