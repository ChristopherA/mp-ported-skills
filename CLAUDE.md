# mp-ported-skills

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `ChristopherA/mp-ported-skills`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, each label string equal to its role name, plus a `research` label and a priority line in the issue body. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Wrapping one of Matt's skills

A ported skill that wraps one of Matt's installed skills owns only the concern it adds. For everything else it loads the installed skill rather than restating its steps, and names it `mattpocock-skills:<name>` in every instruction and subagent brief. When that skill is missing, the wrapper stops and says which skill it needs installed. The prefix matters because a bare name that another skill also registers loads the other one silently: in a Claude Code subagent, bare `code-review` loaded the built-in reviewer, not `mattpocock-skills:code-review`.

This covers wrappers only. A skill that just names a Matt command for the user to type, as `resuming` names `/implement`, is outside it.

## Releasing

A change under `plugins/mp-ported-skills/` bumps `version` in its `.claude-plugin/plugin.json`, in its own commit titled `Bump plugin to X.Y.Z`, after the change's commit: the plugin cache is keyed by version, so installs fetch the change only under a new one. Make the bump commit after `/code-review`'s fixes are committed, not before the review: a review fix under the plugin that lands after the bump leaves the bump ahead of part of its change, and in #194 it took a reset of the unpushed bump to put it last. Tests, docs and this file ship outside the plugin and take no bump. An agent bumps only the patch number (0.7.1 to 0.7.2), whatever the change, and whether it runs under `/implement`, `/supervise` or any other skill. A minor or major bump is the maintainer's: when a change looks like one (a new skill, a new hook, a breaking change), bump the patch number and say in the report that it may deserve a minor or major bump, for the maintainer to make.

After a push that bumps the version, run `claude plugin marketplace update mp-ported-skills && claude plugin update mp-ported-skills@mp-ported-skills` through Bash and report the version it installed. Call it as `command claude`: the maintainer's shell defines `claude` as a function wrapper, which in the Bash tool failed with `_claude_named: command not found` and updated nothing (#78's push). Do not offer it as a `!` command or on the clipboard: the maintainer may be on a remote client, where `!` commands and `/plugin` do not run and the clipboard is out of reach, and Bash works from any client. The maintainer then types `/reload-plugins` to load the new version in this session. In a session the `claude remote-control` server started (a new session from the Claude app), it is refused ("isn't available over a remote connection in this session"), so there say that a new session loads the new version.

## Tests

Tests are `tests/*.test.sh`, run with `sh`. Every `git commit` a test makes in a scratch repo passes `-c commit.gpgsign=false`: the maintainer's global git config signs commits, and a signing prompt hangs a test that has no terminal.

A check that two files match tests `cmp -s`'s exit status, as `same` in `tests/status-line-copy.test.sh` does. `cmp` reports a file that is a prefix of the other on stderr, so a check on its captured stdout reads empty, and passes, for files that differ.

A check on a line that lists several items, such as `ready, blockers closed:`, compares the whole list with `check`, not `has`. A substring passes when extra items follow it: two tickets that should have read as blocked were listed as ready while a `has` check still passed.

Each test sets or unsets every environment variable the scripts it runs read, so it gives the same result in any session. The maintainer's sessions set `MP_SESSION_TITLE=1`, which changes what the status line prints, and one test failed only there.

A test that runs `git` or `gh` unsets `CLAUDE_CODE_SESSION_ATTENDED`. A `/supervise` worker runs the suite with `scripts/worker-bin` first on its PATH and the variable at `0`, and there the wrappers refuse a scratch repo's push (docs/adr/0006); five test files failed only there. Check a new test the way a worker runs it: `PATH="$PWD/plugins/mp-ported-skills/scripts/worker-bin:$PATH" CLAUDE_CODE_SESSION_ATTENDED=0 sh tests/<name>.test.sh`.

To set a variable for one script run, set and export it in a subshell, as `launch_as` in `tests/iterm-pane.test.sh` does, not as a prefix to a helper function such as `run`. `/bin/sh` on macOS is bash in POSIX mode, where `X=1 f` leaves `X` set after the function returns, so every later check in the file runs with it.

A live test that starts `claude` in a pane runs it in a folder inside this repo's parent. The maintainer's shell picks the Claude Code config from a marker file in a parent folder, so a scratch folder elsewhere starts the session under the default config and at the folder-trust prompt, and the test observes a setup no real launch has.

A live test that starts `claude --bg` in a new scratch folder trusts the folder first: `--bg` shows no trust prompt and exits with `Workspace not trusted`. Start plain `claude` there once in a tmux window and choose `Yes, I trust this folder`; the prompt opens on `No, exit`. A plain folder inside this checkout inherits its trust and needs no such step, which is why `tests/live/supervise-resume.sh` makes its scratch folder there. A folder there with its own `git init` does not: three scratch repos made inside the checkout for #83 each exited `Workspace not trusted` until trusted this way (Claude Code 2.1.286).

A live test removes every background session it starts, with `claude stop` then `claude rm`, before it exits. A finished session stays listed in `claude agents` until removed, and one left in a checkout makes `supervise`'s `resume.sh` refuse to resume there: two leftover live checks did so in this checkout.

A live test that runs `supervise`'s `resume.sh` (or `launch.sh`) in a scratch folder inside this checkout releases the worker's marker in its cleanup, with `release.sh --dir <scratch> --id <id>`. The marker goes in the repo holding the folder, which is this checkout, so a test that only stops and removes its session leaves this checkout read-only to every attended session: a `git commit` here was refused, naming a worker the test had already removed.

The profile's sessions start in auto mode, so a test that needs a permission prompt launches with `--permission-mode default`.

A test that needs a transcript's text builds on the shape-only fixtures in `tests/fixtures/transcripts/` and fills their text blocks in the test, as `tests/supervise-last-message.test.sh` does. Do not cut a new fixture with a real session's text kept: the auto-mode classifier refused copying a worker's transcript text into the repo (#71).

A transcript fixture puts each turn's `turn_duration` row after the text that turn ended on. `record.sh` and `watch.sh` read a turn by the last text before its end, so a row written before its `Waiting on:` text reads as a turn ending on a statement, a finished report, and a wait the test means to check is dropped: #131's settled-run check passed before the fix until the row was moved.

A pattern `pane-classify.sh` matches comes from a live capture in `tests/fixtures/pane-states/`, recorded in a wide pane and in a narrow one. Claude Code cuts text to fit a narrow pane: the interrupt marker `⎿  Interrupted` rendered as `⎿  Interrup·` at 27 columns, and a pattern built from the full word read that idle session as `working`.

A live test of a change to the plugin passes `--plugin-dir <checkout>/plugins/mp-ported-skills` to `claude`, as `tests/live/deny-shared-actions.sh` does: a plain session loads the installed release, which does not hold the change. To read a background session's result, it puts a unique token in the prompt and finds the transcript under `$CLAUDE_CONFIG_DIR/projects/` by that token. The session's `jobs/<id>/` folder may already be gone.

A live test that reads the session id from `claude --bg`'s `backgrounded · <id>` line strips color codes first, as `launch.sh` does. With `FORCE_COLOR` set, as the maintainer's sessions set it, the id is colored even with no terminal, and a pattern on the plain line finds no id (Claude Code 2.1.288).

A live test that resumes a background session reads the line `claude --bg --resume` prints: `woke session <id>` is the original, `started a copy as <id>` is a copy. Stop and `claude rm` a copy before going on, since it runs without the launch's saved flags. A resume issued as soon as `claude agents` showed the stopped session without a pid started one; the same resume 47 seconds later woke the original.

A live test that checks a background worker's edits looks in every worktree (`git worktree list`, `git log --all`), not only the checkout. From Claude Code 2.1.286 a background session may not edit the shared checkout, so a worker denied `EnterWorktree` made its own with `git worktree add` and committed there, while its `cwd` stayed the checkout (#83).

A live measurement of what a session loads before its first step uses a `claude --bg` session started the way `launch.sh` starts a worker, with one source removed per run, and reads the first call's context from its transcript, as `docs/research/worker-fixed-load.md` does. Not `claude -p`: print mode loads neither the Artifact tool nor Claude in Chrome, and read 45k where the same worker-shaped background session read 65k.

A live test that needs a particular model starts the session with `claude --model <id>`. Typing `/model` in a running session also saves the model to the profile's `settings.json` as the default, so it changes every later session on that profile.

A live test that runs a session unattended, with `--permission-mode auto` (a `claude --bg` session, or a pane nobody answers), runs it on a model that supports auto mode. Haiku 4.5 does not: the session prints `auto mode unavailable for this model`, falls back to manual mode, and blocks at a permission prompt on its first Bash command.

A live run of a skill that launches `/implement` workers is the maintainer's to type. From an agent session in auto mode, the classifier allowed `claude --bg` sessions on plain prompts but refused `launch.sh` starting an `/implement` worker ("Create Unsafe Agents").

A test that puts a fake command on `PATH` makes it executable and checks, before any call that could reach the real one, that `command -v` finds the fake, as `tests/supervise.test.sh` does for `claude`. A fake written without `chmod +x` is skipped silently: its launch tests ran the real `claude --bg`, which only its folder-trust check stopped.

A stub that stands in for a real command refuses what the real one refuses, with the same exit status, as the sweep stub in `tests/supervise-push.test.sh` exits 2 on an empty range. A stub that accepts every input passes a case the real command fails: `push.sh` swept a repo with nothing to push, the real sweep exited 2, and a live push was refused while its test, on a stub that took the empty range, passed (#179).

## Grant actions

A new grant action, or a change to what one covers, goes into every list of the actions, not only the scripts that enforce it: `grant.sh`, the classifier `shared-action-classify.sh` (`grant_action`), `launch.sh`'s grants text, `actions.sh`, `answer.sh`, `capturing`'s `before-clear.sh` and its `SKILL.md`, the template in `setup-mp-ported-skills`' `setup.sh`, `docs/agents/supervision.md`, and ADR 0005. Find them with `rg -l 'issue-create' plugins docs`. A list left behind still accepts the old set: in #141, `before-clear.sh` would have reported a Distribution repo push as covered by the `push` grant, and the hook would then have refused it.

## Calling claude from scripts

A `claude` option that takes a list (`--allowedTools`, `--disallowedTools`, and any other `claude --help` shows as `<tools...>` or `<values...>`) goes before another option, never right before the prompt, as `launch.sh` places `--disallowedTools`. A list option reads every word after it that does not start with `-`, so the prompt becomes an entry in the list: `claude -p --disallowedTools EnterWorktree 'Reply OK'` warns that the deny rule "Reply" matches no known tool, then fails with `Input must be provided`.

## jq in scripts

Build a JSON value from a shell string with `jq -n --arg`, as `fixed_nums` in `resuming`'s `state.sh` does. `jq -R` on empty stdin prints nothing, so a later `--argjson` of that value fails, and a script that goes on after the failure reports empty results as if they were real.

## Checking a path is a repo

To check that a path a file names is a repo of its own, compare `git -C <path> rev-parse --show-toplevel` with the path, resolved. `rev-parse --git-dir` succeeds in any folder inside a repo, so a plain folder there passes and the checks after it read the repo around it: `launch.sh` accepts such a folder as a Distribution repo (#167), and `state.sh` read the Project's own git as its Distribution repo's until #142's review.

## gh api lists

A `gh api` read of a list (sub-issues, comments, labels) passes `--paginate` with `per_page=100`. GitHub returns one page, 30 items by default, with no sign that more exist: #40's first page of sub-issues held only closed children, so a read for its open ones came back empty with exit 0.

A test of a paged read gives each page data that only the merged list answers rightly. Without the merge, jq runs its filter once per page: `last` printed one login per page, and a check that the newest comment was a reply passed with the merge removed (#155).

## Checking what a hook did

The terminal and a screenshot show a session's title and state, not what set them. To learn whether a `SessionStart` hook ran and what it printed, read the session's transcript, `$CLAUDE_CONFIG_DIR/projects/<cwd with / as ->/<session id>.jsonl`. A session that entered a worktree has its whole transcript moved to the worktree's folder, so a script finds it by session id in any folder, `projects/*/<session id>.jsonl`, as `transcript_of` in `supervise`'s `watch.sh` does. Each hook run is an `attachment` record carrying `hookName` (`SessionStart:<source>`), `command` and `stdout`, and the title in force is the last `custom-title` record. A forked or branched session's transcript opens with copies of its parent's records, timestamps included, so a hook run belongs to the new session only when its timestamp is after the fork.

What a worker's Bash call did, as opposed to what its command text says, is on the result's `user` record: `toolUseResult.gitOperation` holds a `push` (`branch`), a `pr` (`number`, `url`, `action`) or a `commit`, recorded from what ran, so it shows a push made by a script whose text names none. A subagent's calls are in `projects/*/<session id>/subagents/*.jsonl`. `supervise`'s `actions.sh` reads both.

A background agent's report reaches the worker as a `user` row with no `isMeta`, `origin.kind` `task-notification`, and text starting `<task-notification>`. A script that reads a worker's prompts from its `user` rows leaves those rows out by `origin.kind`, as `record.sh`'s `asked` does: otherwise an agent's report reads as a prompt that someone typed. Leaving out every row that starts with `<` drops typed slash commands too (#138).

A session's cost is its transcript's last `cost-state` row: `totalCostUSD` and, per model in `modelUsage`, four token counts and `costUSD`, subagents included (a model only a subagent called appears there). A running interactive session's transcript holds no `cost-state` row yet, and a background worker's may hold none until `claude stop` writes one: #58's worker sat idle for hours after its turn ended with no row, and a record read right after the stop still missed it. A cost read from a live session is unknown, never zero. An assistant row is written once per content block, so count API calls by distinct `requestId`, as `supervise`'s `record.sh` does.

## Files beside a SKILL.md

Claude Code fills in `${CLAUDE_SKILL_DIR}`, `${CLAUDE_SESSION_ID}` and `$ARGUMENTS` only in a skill's `SKILL.md`; the Bash tool's shell sets none of them, and a file beside it that the skill tells the reader to open is read as written. So a file split out of a `SKILL.md`, as `supervise`'s `loop.md` and `push-on-approval.md` are, says at its top what each such variable in its commands stands for, and `SKILL.md` names the file at the step that reaches it with `read `${CLAUDE_SKILL_DIR}/<file>``, which is filled in there. A split-out file that sends the reader on to another does the same. A file only mentioned (`Post on approval, in `post-on-approval.md``) is one a run reaches without reading; a mention that only says where a section lives names the file in parentheses, `(Post on approval, `post-on-approval.md`)`. `tests/supervise-sections.test.sh` checks both for `supervise`, mention by mention: a check that dropped whole lines with a read instruction on them hid a bare mention beside one (#135).
