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

A change under `plugins/mp-ported-skills/` bumps `version` in its `.claude-plugin/plugin.json`, in its own commit titled `Bump plugin to X.Y.Z`, after the change's commit: the plugin cache is keyed by version, so installs fetch the change only under a new one. Tests, docs and this file ship outside the plugin and take no bump. An agent bumps only the patch number (0.7.1 to 0.7.2), whatever the change, and whether it runs under `/implement`, `/supervise` or any other skill. A minor or major bump is the maintainer's: when a change looks like one (a new skill, a new hook, a breaking change), bump the patch number and say in the report that it may deserve a minor or major bump, for the maintainer to make.

After a push that bumps the version, run `claude plugin marketplace update mp-ported-skills && claude plugin update mp-ported-skills@mp-ported-skills` through Bash and report the version it installed. Do not offer it as a `!` command or on the clipboard: the maintainer may be on a remote client, where `!` commands and `/plugin` do not run and the clipboard is out of reach, and Bash works from any client. The maintainer then types `/reload-plugins` to load the new version in this session. In a session the `claude remote-control` server started (a new session from the Claude app), it is refused ("isn't available over a remote connection in this session"), so there say that a new session loads the new version.

## Tests

Tests are `tests/*.test.sh`, run with `sh`. Every `git commit` a test makes in a scratch repo passes `-c commit.gpgsign=false`: the maintainer's global git config signs commits, and a signing prompt hangs a test that has no terminal.

A check that two files match tests `cmp -s`'s exit status, as `same` in `tests/status-line-copy.test.sh` does. `cmp` reports a file that is a prefix of the other on stderr, so a check on its captured stdout reads empty, and passes, for files that differ.

A check on a line that lists several items, such as `ready, blockers closed:`, compares the whole list with `check`, not `has`. A substring passes when extra items follow it: two tickets that should have read as blocked were listed as ready while a `has` check still passed.

Each test sets or unsets every environment variable the scripts it runs read, so it gives the same result in any session. The maintainer's sessions set `MP_SESSION_TITLE=1`, which changes what the status line prints, and one test failed only there.

To set a variable for one script run, set and export it in a subshell, as `launch_as` in `tests/iterm-pane.test.sh` does, not as a prefix to a helper function such as `run`. `/bin/sh` on macOS is bash in POSIX mode, where `X=1 f` leaves `X` set after the function returns, so every later check in the file runs with it.

A live test that starts `claude` in a pane runs it in a folder inside this repo's parent. The maintainer's shell picks the Claude Code config from a marker file in a parent folder, so a scratch folder elsewhere starts the session under the default config and at the folder-trust prompt, and the test observes a setup no real launch has.

A live test that starts `claude --bg` in a new scratch folder trusts the folder first: `--bg` shows no trust prompt and exits with `Workspace not trusted`. Start plain `claude` there once in a tmux window and choose `Yes, I trust this folder`; the prompt opens on `No, exit`. The profile's sessions start in auto mode, so a test that needs a permission prompt launches with `--permission-mode default`.

A pattern `pane-classify.sh` matches comes from a live capture in `tests/fixtures/pane-states/`, recorded in a wide pane and in a narrow one. Claude Code cuts text to fit a narrow pane: the interrupt marker `⎿  Interrupted` rendered as `⎿  Interrup·` at 27 columns, and a pattern built from the full word read that idle session as `working`.

A live test of a change to the plugin passes `--plugin-dir <checkout>/plugins/mp-ported-skills` to `claude`, as `tests/live/deny-shared-actions.sh` does: a plain session loads the installed release, which does not hold the change. To read a background session's result, it puts a unique token in the prompt and finds the transcript under `$CLAUDE_CONFIG_DIR/projects/` by that token. The session's `jobs/<id>/` folder may already be gone.

A live test that needs a particular model starts the session with `claude --model <id>`. Typing `/model` in a running session also saves the model to the profile's `settings.json` as the default, so it changes every later session on that profile.

A live test that runs a session unattended, with `--permission-mode auto` (a `claude --bg` session, or a pane nobody answers), runs it on a model that supports auto mode. Haiku 4.5 does not: the session prints `auto mode unavailable for this model`, falls back to manual mode, and blocks at a permission prompt on its first Bash command.

A live run of a skill that launches `/implement` workers is the maintainer's to type. From an agent session in auto mode, the classifier allowed `claude --bg` sessions on plain prompts but refused `launch.sh` starting an `/implement` worker ("Create Unsafe Agents").

A test that puts a fake command on `PATH` makes it executable and checks, before any call that could reach the real one, that `command -v` finds the fake, as `tests/supervise.test.sh` does for `claude`. A fake written without `chmod +x` is skipped silently: its launch tests ran the real `claude --bg`, which only its folder-trust check stopped.

## jq in scripts

Build a JSON value from a shell string with `jq -n --arg`, as `fixed_nums` in `resuming`'s `state.sh` does. `jq -R` on empty stdin prints nothing, so a later `--argjson` of that value fails, and a script that goes on after the failure reports empty results as if they were real.

## Checking what a hook did

The terminal and a screenshot show a session's title and state, not what set them. To learn whether a `SessionStart` hook ran and what it printed, read the session's transcript, `$CLAUDE_CONFIG_DIR/projects/<cwd with / as ->/<session id>.jsonl`. Each hook run is an `attachment` record carrying `hookName` (`SessionStart:<source>`), `command` and `stdout`, and the title in force is the last `custom-title` record. A forked or branched session's transcript opens with copies of its parent's records, timestamps included, so a hook run belongs to the new session only when its timestamp is after the fork.
