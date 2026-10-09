# Loop

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them. `${CLAUDE_SESSION_ID}` in the commands below is this session's id, as `SKILL.md`'s glance command shows it filled in; write it out the same way.

With `--loop`, the supervisor runs the maintainer's manual loop: tickets one after another, never in parallel, each in a fresh background session (#77, ADR 0003). Without it, one ticket, then stop.

`--loop N` caps the loop at N tickets (#149); without a count it runs until another rule stops it. Check the count before `SKILL.md`'s step 1, so a bad one launches nothing:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/next.sh" --max N </dev/null
```

It prints `count N` (exit 0). Exit 1: the count is not a positive integer; report the error and end there, before any launch.

A ticket that continued after a zone capture (Zone capture, `zone-capture.md`) is settled by its continuation, the second worker, which these conditions then read. A ticket's run goes on to the next only when its work is settled and has landed: its watch, after any routine answers, came to `done` with its work committed, or to `blocked input needed` on a `git push` no grant covers; its capture ran (Capture, in `SKILL.md`); its work is on the default branch's upstream, by the worker's own push under a standing grant, or by Push on approval on the maintainer's yes; any issue comment or new issue its capture listed went through Post on approval, posted or not; `stop.sh` exited 0, so the worker is stopped and its marker released; and its run record is posted on its ticket. Any other outcome ends the loop at that ticket, reported by `SKILL.md`'s Report step for it, with the condition it stopped on, the worker's id and the ticket: a permission prompt, a question, a block on an action no grant covers other than that push or a capture's issue comment or new issue, a declined or failed push, a continuation's own `capture-due`, a `moved`, `hang`, `stopped` or `gone`, a failed launch or launch check, a stop that was refused or exited 1 (ask, as `stop-refused.md` says, and on a yes go on from there), or a ticket the worker did not finish.

A finished worker is stopped, not removed: `record.sh` reads its job after the stop, and `launch.sh` counts a stopped session as not live, so it stays listed in `claude agents` until the maintainer removes it.

Between tickets, read what comes next, passing every ticket this loop ran:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/next.sh" --dir "<project folder>" --ran "<N M ...>" --session "${CLAUDE_SESSION_ID}" --session-dir "$PWD" </dev/null
```

With `--loop N`, add `--max N`. `--session` and `--session-dir` name this supervisor session and its own folder, as the glance in `SKILL.md`'s Report step does, so `next.sh` reads its zone reading. With no reading it prints a `note:` line on stderr and goes on; report that line, since the loop then runs without its zone stop.

It fetches, then prints `next implement #M` (exit 0), after a `scripts <version> <dir>` line when the scripts run from the plugin cache: go back to `SKILL.md`'s step 1 for #M, reading its body and comments, recording its start and taking a fresh snapshot, then Launch, which runs the one-session-per-checkout check again, so a session from the previous ticket still live refuses the launch (#57). Or it prints `stop <kind>: <detail>` (exit 2), and the loop ends there:

- `held`: the checkout's marker still names a worker, so a stop did not finish.
- `not-landed`: uncommitted paths, no upstream, or commits the upstream lacks. The next ticket starts from the default branch as pushed, so the loop waits for the maintainer rather than stacking work.
- `behind`: the upstream moved on, so the next worker would start from an old commit.
- `count-reached`: the loop ran the N tickets `--loop N` asked for. It is read after the three above, so a last ticket whose work did not land is still reported as `held`, `not-landed` or `behind`.
- `zone`: this session's zone reading is at or past the point the loop stops at (90% of zone), so it starts no more tickets and wraps up (Zone stop, below). It is read after the four above.
- `nothing-left`: `state.sh`'s next step is nothing in motion.
- `other-step`: any other step than `/implement` of a `ready-for-agent` ticket.
- `repeat`: `state.sh` still recommends a ticket this loop already ran, which happens when its work went in without `Closes #N`; running it again would rebuild it.

Exit 1: report the error, and end the loop. One such error is a zone stop at or above this session's auto-compact point, read from the same reading in zone units: the session would compact before the loop stopped, so `next.sh` refuses rather than go on.

The `scripts` line names the newest installed version of this plugin (a cache folder marked `.orphaned_at` does not count) and its `supervise/scripts` folder, which `next.sh` already read the next step with (#169). A worker that pushes a plugin bump installs the new version, but this session goes on naming the folder it loaded, and `/reload-plugins` does not change that mid-loop; in the #141 to #143 loop, the next worker would have launched without the grants text the previous one added. So run every script for the rest of the loop, step 1 to the next `next.sh`, from that folder in place of `${CLAUDE_SKILL_DIR}/scripts`. When the line ends `(newer than the loaded <version>; ...)`, say in the report that the loop switched, from which version to which. Each ticket's script version is the one the `scripts` line before it named; for the first ticket, the loaded one, `basename "$(cd "${CLAUDE_SKILL_DIR}/../.." && pwd)"`, which outside the cache is a folder name, not a version.

## Zone stop

A loop that runs past this session's zone makes its stop-or-continue calls, and its wrap-up, from where sessions stop working well (#78). So `next.sh` stops the loop at 90% of zone, below 100% so the wrap-up runs inside the zone: in the #141 to #143 loop each ticket added 6 to 10 points. The check comes between tickets, so the running worker has already finished, been captured, landed and been stopped. On `stop zone`:

1. **Evaluate.** Post a loop summary on the tickets' parent. Read each ticket's parent in the Project folder with `gh api "repos/{owner}/{repo}/issues/<N>/parent" --jq .number`, which exits 1 with `No parent issue found` for a ticket with none; post the summary on each distinct parent, or on the last ticket run when none has one. Write it to `<scratchpad>/loop-summary.md`, then post it with `gh issue comment <parent> --body-file "<scratchpad>/loop-summary.md"`. It holds the `stop zone` line, and for each ticket the loop ran, in order: its number, the worker's id, its outcome, any gate it hit (a routine answer, a push or post on approval, a refusal), and its run record, as posted, with the URL of that comment. So that each record is still at hand, in a loop save each ticket's record as `<scratchpad>/run-record-<N>.md`, not the one `run-record.md`.
Like the run record, the summary is a comment the supervisor posts without asking: it holds what the run records already hold.
2. **List what waits on the human.** In the final report, list each push, merge or issue close the loop reached that no grant covered and that was not taken on the maintainer's yes, from each ticket's `actions.sh` `ungranted` lines and its capture's report, each with the command that takes it, in a fenced code block. Take none of them: each still needs the maintainer's yes, asked as `push-on-approval.md` or `post-on-approval.md` says.
3. **Capture.** After the final report, run `/mp-ported-skills:capturing` in this session, last, so the maintainer can `/clear` and start the next supervisor session from the tracker alone.

The final report says the loop stopped because the supervisor reached its zone stop, with the reading `next.sh` printed.

The final report lists every ticket the loop ran, in order: its number, the worker's id, the script version it was launched with, its outcome, the supervisor's glance line at its end, its commits, the shared actions, the capture's report and the run record's comment; then the condition that ended the loop, with the worker's id and the ticket it stopped on, and for a `zone` stop the loop summary's URL and the actions waiting on the maintainer. A stop from `next.sh` comes after the last ticket, so name that ticket and its worker's id with its `stop` line.
