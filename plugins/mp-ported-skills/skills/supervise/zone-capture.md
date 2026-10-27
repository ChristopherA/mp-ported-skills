# Zone capture

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

A worker whose zone reading passes the threshold while it is still building gets the maintainer's own treatment from the status line: capture, then go on in a fresh session (#60). Workers went on building, reviewing and committing past their zone without one: 129%, 174%, and 166% in the #141 run, which crossed 100% at call 34 of 109.

`zone.sh` reads the reading as the status line records it after a call, from the context of the worker's last call on its main chain, and calls it due at or past 80% of zone, and only at a safe point: every tool call has its result and every background command or agent the worker started has reported back, so the stop below cuts no command mid-run. From 88%, a background task still running no longer holds it, and the due line reads `due: background task <id> is cut`: review agents can run for minutes, the stop ends them, and the continuation runs them again; say so in the report. A running tool call holds it at any reading. Both points sit below the auto-compact point of a 200k window, about 106% of zone at the profile's `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` of 80, by more than one tool result can add between polls (`tests/supervise-zone.test.sh` fails otherwise). The worker runs on between the watch's return and `resume.sh`'s stop, so run step 2 at once.

1. Take a fresh snapshot, as Capture's step 1 in `SKILL.md` does, to `<scratchpad>/snapshot-zone.txt`.
2. Send the capture, naming the next phase, so the capture commits the work so far and records what is left on the ticket rather than in a new one:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "/mp-ported-skills:capturing next: a fresh worker continues #N from this session's commits; commit the work so far, and record what is left on #N, not in a new ticket" </dev/null
   ```

3. Watch it as Capture's step 3 in `SKILL.md` does, with `--since "<scratchpad>/snapshot-zone.txt"`, `--after`, `--capture` and `--detail`, and no `--zone`, and go on by its first line. The ticket's work has **landed** when the worker pushed it before the reading fired, as a worker under a `push` grant does in its build turn: the capture ended on `live-check.sh`, the ticket is closed (`gh issue view N --json state`), or the capture's report says nothing is left for an agent. In the #133 run the reading fired at 84% after the worker's granted push, and the zone capture found nothing left to build (#197).
   - **`done`**: go on to step 4.
   - **`blocked input needed`** on a `git push`: when the capture's message names `live-check.sh --apply N` as well, the work has landed: take the `live-check.sh` bullet below, since the `needs` line holds only the last `Waiting on:` line. Otherwise, when the work has not landed, go on to step 4 and push nothing: the ticket is not finished, and the continuation reaches its own push. When it has landed, the push that waits is the capture's own commits, and no continuation will reach it: Push on approval, as Capture's step 3 does (read `${CLAUDE_SKILL_DIR}/push-on-approval.md` and follow it), whose last step runs `finish.sh` in place of step 4.
   - **`blocked input needed`** on `live-check.sh --apply N`: the work has landed, and the capture left #N open for a live check that no grant covers. Follow Capture's step 3 in `SKILL.md` for this block; when a `git push` also waits, its Push on approval comes first, up to its step 6, so the live check is asked before `finish.sh` (read `${CLAUDE_SKILL_DIR}/push-on-approval.md` and follow it). Then Push on approval's step 6 when it ran; or else, when the capture's message names a `gh issue comment` or `gh issue create` no grant covers, Post on approval (read `${CLAUDE_SKILL_DIR}/post-on-approval.md` and follow it), whose last step runs `finish.sh` in place of step 4; or else step 4.
   - **`blocked input needed`** on a `gh issue comment` or `gh issue create` no grant covers: when the capture's message names `live-check.sh --apply N` as well, the work has landed: take the `live-check.sh` bullet above, which posts after the live check. Otherwise Post on approval: read `${CLAUDE_SKILL_DIR}/post-on-approval.md` and follow it, then step 4.
   - **Any other state**: `SKILL.md`'s Report step for that state, with no continuation.
4. End the first worker's run with `finish.sh` (Finishing, in `SKILL.md`), with the viewer flag when a viewer is open: it stops the worker, releases its marker, reads its shared actions, takes the glance, and writes and posts its run record, as for any worker. A `stop failed:` line goes to `stop-refused.md` as there, and launches nothing until the stop goes through. When `git -C "<project folder>" status --porcelain` prints anything, the capture left work uncommitted: report it and the worker's id, and launch nothing.
5. When the work has landed (step 3), launch no continuation. When `git -C "<project folder>" status -sb` shows the branch ahead of its upstream, the capture's commits went unpushed with no `Waiting on:` line naming them: report them and the worker's id, and with `--loop` the loop ends there. Otherwise the run is settled, as a `done` run is. Report it with the reading that set off the capture and the ticket's state, and with `--loop` go on to the next ticket (Loop, `loop.md`). Otherwise continue the ticket in a fresh worker: `SKILL.md`'s step 1 snapshot command again, to `<scratchpad>/snapshot.txt`, then Launch with `--continue <start>`, the same `--model` and `--effort`:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N --continue <start> </dev/null
   ```

   Its prompt tells `/implement` that the commits since `<start>` and the capture's notes on the ticket are the work so far, and its name ends `#N (continued)`. Tell the maintainer the ticket continues, with the new id and the reading that set it off, then Watch and Report it as any worker, keeping the first worker's `<start>` for `actions.sh`, `push.sh` and `record.sh`, so its push and record cover both workers' commits. With a Distribution repo, keep step 1's `<dist start>` the same way for `--dist-start`, not the new snapshot's `dist head`.

A ticket continues once per supervisor session. A worker this session launched from `step.sh`'s `continue #N from <sha>` (step 1 in `SKILL.md`) is that session's continuation of #N: when it returns `capture-due`, it gets what a continuation gets, below, and step 5 launches no further worker. A continuation that returns `capture-due` itself gets steps 1 to 4, then the wrap-up below, and then the report, with both workers' ids and readings and no third worker; with `--loop`, the loop ends there. A later supervisor session may continue the ticket again from the same `<start>`: while the newest run record on #N accounts for the unpushed commits exactly, `step.sh` reads them as `continue #N from <start>` (#214).

## Wrap-up before a continuation

A supervisor that ends while a zone-captured ticket still has work to build leaves the commits since `<start>` on the default branch, unpushed, and only this session knows `<start>` (#214). That holds on every path between a capture and the continuation's launch: a continuation's own `capture-due`, this session's own zone stop or the maintainer's stop before step 5 launched, or a failed launch at step 5. Before the report:

1. Push on approval's steps 2 to 5 over `<start>` to HEAD, with the last worker's id (read `${CLAUDE_SKILL_DIR}/push-on-approval.md` and follow it). Its step 1 is already done, since step 4 stopped the worker; its step 6 is this report. It asks the maintainer first, unless the push is a checked one.
2. Pushed or not, the report gives the command a later session runs to continue the ticket, in a fenced code block, with the first worker's `<start>` in full and the `--model` and `--effort` this run launched with:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N --continue <start> --model <model> --effort <effort> </dev/null
   ```

   On a no, a failed check or a failed push, the report also lists the unpushed commits, `git -C "<project folder>" log --oneline <start>..HEAD`, and says that a later `/supervise` continues the ticket from them on its own, as long as nothing is committed on top of them.
