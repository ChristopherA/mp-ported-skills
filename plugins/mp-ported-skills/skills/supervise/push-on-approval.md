# Push on approval

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

A worker blocked on a `git push` no grant covers has finished its work and committed it. The capture runs first (Capture, in `SKILL.md`), so this runs once, after it, over the work and any commits the capture made. The supervisor checks the commits, asks the maintainer once, and on a yes pushes them itself, so the push needs no terminal and no `!` command and works from a remote client (docs/adr/0007).

With a Distribution repo, the worker's ticket waits on that push too (#186): while the Distribution repo holds commits its upstream lacks, the hook and the wrappers refuse the worker's `gh issue close`, even under an `issue-close` grant, and the worker ends on `Waiting on: git -C <dist> push origin <branch>; gh issue close <N>`. Steps 3 and 4 settle that close with `close.sh`, once the maintainer has answered the push.

1. Stop the worker and release its marker, with `stop.sh` (Stopping, in `SKILL.md`). With `--watch tmux` or `--watch iterm`, close the viewer.
2. Check, without pushing:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/push.sh" --dir "<project folder>" --id ID --start <start> --sweep "<sweep command>" --check </dev/null
   ```

   `<sweep command>` is the maintainer's public-artifact sweep, which takes `--range A..B`, as named in their own instructions; `push.sh` runs it in the folder with the range appended. With none named, pass `--no-sweep` and say in the question that the range was not swept. It prints the branch and its upstream, a `commit` line for each commit to go, and an `ok` or `fail` line for each check: no worker marker in the checkout, a clean tree, a fast-forward onto the upstream after a fetch, the worker's start already on the upstream, every plugin version change a patch bump at most, and the sweep. Exit 2: a check failed. Report each `fail` line, and the sweep's indented output, and stop there: do not push, and do not ask. Exit 1: report the error. With a Distribution repo (#141), add `--dist-start <dist start>` to both runs, from step 1; without it, or with it and no Distribution repo, `push.sh` exits 1. It then checks both repos, each with its own range and sweep run in that repo, and names the repo after each line's first word (`push project ...`, `commit distribution ...`, `ok distribution sweep: ...`); a repo with nothing to push is passed over when the other has something. A `fail` in either repo pushes neither, and asks nothing.
3. All checks passed: ask the maintainer one question, with the commits and the `ok` lines in it: push these commits to the upstream, or leave them. With a Distribution repo, the one question covers both repos' commits. Ask nothing else in the same question, and take only an explicit yes given in this session as the go-ahead. A no, or no answer, leaves the commits local; report them as unpushed. On an explicit no, when the `needs` line also named `gh issue close <N>`, keep the ticket from reading done or ready to build:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/close.sh" --dir "<project folder>" --id ID --ticket <N> --declined </dev/null
   ```

   It checks that no worker marker is left and that the Distribution repo still holds commits its upstream lacks, then reopens #N if it was closed, comments the unpushed commits and that the push was declined, and relabels it `ready-for-human`, so `/supervise`'s next step does not build it again. Exit 2: report each `fail` line; nothing ran. Exit 3: report gh's error. With no answer, run nothing: the ticket stays as the worker left it, open.
4. On a yes, push:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/push.sh" --dir "<project folder>" --id ID --start <start> --sweep "<sweep command>" </dev/null
   ```

   It runs every check again, pushes only the checked commit, to the branch's upstream, and prints `pushed <upstream> A..B`. It records the push in the checkout, so `actions.sh` names the branch as pushed by the supervisor on the maintainer's approval, not as the worker's, and `record.sh` does not count the worker's wait for it as a wait on a human, as long as no prompt reached the worker between its block and the push. Exit 2: a check failed since the question; report it and push nothing. Exit 3: the push failed; report its error. With two repos it tries both with `--dry-run` before pushing either, and prints `pushed distribution:<upstream> A..B` for the Distribution repo; an exit 3 after the first push landed says which already went, and the other is reported as unpushed. If a permission check refuses the push, report the refusal and stop. Do not route around it.

   When the Distribution push landed (its `pushed distribution:` line) and the `needs` line named `gh issue close <N>`, close the ticket:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/close.sh" --dir "<project folder>" --id ID --ticket <N> --pushed </dev/null
   ```

   It checks that no worker marker is left, that the Distribution repo is even with its upstream, and that the Project grants `issue-close`, then closes #N with a comment naming the pushed commit and prints `closed <url>`. It records the close in the checkout, so `actions.sh` names it as the supervisor's, after the push. A `fail grant` line means no grant covers the close: ask the maintainer one question, close #N or leave it open, and on an explicit yes run the same command with `--approved` added. Any other exit 2: report each `fail` line; nothing ran. Exit 3: report gh's error. When the Distribution push did not land, close nothing. A Distribution branch with no upstream holds the close for good, and `close.sh` refuses both outcomes there: report it, for the maintainer to set the upstream or close the ticket by hand.
5. When a `version` line showed a bump of a plugin this profile has installed, update it through Bash: `claude plugin marketplace update <marketplace> && claude plugin update <plugin>@<marketplace>`, and report the version it installed.
6. When the capture lists an issue comment or new issue, Post on approval: read `${CLAUDE_SKILL_DIR}/post-on-approval.md` and follow it. Then go on with `SKILL.md`'s Report step for `done`, with no second capture: the ticket's state, the capture's report, and `finish.sh` (Finishing, in `SKILL.md`) with no viewer flag, since step 1 closed the viewer, for the shared actions, the glance and the run record, taken now, after the capture, the stop and the push, so the record carries the worker's cost, the capture and the push.
