# Post on approval

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

A settled worker's capture can find something for the tracker that it may not post: a comment on another ticket, or a new ticket, that no grant covers. It lists the finding with the `gh` command that would post it, and ends either on `Waiting on: gh issue comment N` (`blocked input needed`) or on a statement (`done`). Either way the worker's work is done, so the supervisor asks the maintainer once per finding and, on a yes, posts it itself, as it pushes (docs/adr/0007). Without this the worker stays live, and the checkout read-only, until the maintainer attaches, for one comment.

Run it once the capture has ended, after Push on approval when a push also waits, so one stop serves both. Only a capture's findings come here: a build that blocks on an issue comment or new issue before its capture is reported as `SKILL.md`'s Report step says.

1. Stop the worker and release its marker, with `stop.sh` (Stopping, in `SKILL.md`), unless Push on approval already did. With `--watch tmux` or `--watch iterm`, close the viewer.
2. For each finding, take the worker's exact command from its capture report (its last output, Stopping in `SKILL.md`; `--count 2` when the `Waiting on:` line came in a message of its own). Write the body, exactly as the command would post it with its shell quoting undone, to `<scratchpad>/post-K.md`, and check, without posting:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/post.sh" --dir "<project folder>" --id ID --comment N --body-file "<scratchpad>/post-K.md" --sweep "<sweep command>" --check </dev/null
   ```

   For a new issue, pass `--create --title "<title>"` in place of `--comment N`, and a `--label <name>` for each label the command names; add `--repo <owner/repo>` when it names one. `<sweep command>` is the one Push on approval uses; `post.sh` runs it in the folder with a file holding the title and body appended. With none, pass `--no-sweep` and say in the question that the text was not swept. It prints `post <action>: <command>`, the command it will run, built from these options and never from the worker's text; the body, indented; and an `ok` or `fail` line for each check: no worker marker in the checkout, a body that is not empty, and the sweep. Exit 2: a check failed. Report each `fail` line and the sweep's indented output, and post nothing and ask nothing for that finding. Exit 1: report the error.
3. All checks passed: ask the maintainer one question per finding, one at a time: post this, or leave it. Put in it the worker's command exactly as its capture wrote it, and `post.sh`'s command and body, so the maintainer sees that what goes out is what the worker wrote. Ask nothing else in the same question, and take only an explicit yes given in this session as the go-ahead. A no, or no answer, posts nothing; report the finding as unposted, with the worker's command. `record.sh` then counts the worker's wait for it as a wait on a human, since the finding still waits on one.
4. On a yes, post, with the same options as the check:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/post.sh" --dir "<project folder>" --id ID --comment N --body-file "<scratchpad>/post-K.md" --sweep "<sweep command>" </dev/null
   ```

   It runs every check again, runs the command, and prints `posted <action> <url>`. It records the post in the checkout, so `actions.sh` lists it as `<action> posted by the supervisor on the maintainer's approval: <url>`, and `record.sh` does not count the worker's wait for it as a wait on a human, as long as no prompt reached the worker between its block and the post. Exit 2: a check failed since the question; report it and post nothing. Exit 3: `gh` failed; report its error. If a permission check refuses the post, report the refusal and stop. Do not route around it.
5. Go on with `SKILL.md`'s Report step for `done`, with no second capture, as Push on approval's step 6, in `push-on-approval.md`, says, with each post's URL, or the finding as unposted.
