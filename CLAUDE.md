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

A change under `plugins/mp-ported-skills/` bumps `version` in its `.claude-plugin/plugin.json`, in its own commit titled `Bump plugin to X.Y.Z`, after the change's commit: the plugin cache is keyed by version, so installs fetch the change only under a new one. Tests, docs and this file ship outside the plugin and take no bump. A new skill bumps the minor number; a script, fix or doc change inside an existing skill bumps the patch number (`iterm-pane` came in as 0.7.0, its launcher as 0.7.2).

After a push that bumps the version, ask with AskUserQuestion how the maintainer wants to update, offering the two routes `capturing` gives a terminal job: run `claude plugin marketplace update mp-ported-skills && claude plugin update mp-ported-skills@mp-ported-skills` through Bash, or copy it with a leading `! ` to this machine's clipboard. Running it comes first: the maintainer may be on a remote client, where `!` commands and `/plugin` do not run and the clipboard is out of reach. Write the command in both descriptions. Then the maintainer types `/reload-plugins`, which works from a remote client too, to load the new version in this session.

## Tests

Tests are `tests/*.test.sh`, run with `sh`. Every `git commit` a test makes in a scratch repo passes `-c commit.gpgsign=false`: the maintainer's global git config signs commits, and a signing prompt hangs a test that has no terminal.

A check that two files match tests `cmp -s`'s exit status, as `same` in `tests/status-line-copy.test.sh` does. `cmp` reports a file that is a prefix of the other on stderr, so a check on its captured stdout reads empty, and passes, for files that differ.

Each test sets or unsets every environment variable the scripts it runs read, so it gives the same result in any session. The maintainer's sessions set `MP_SESSION_TITLE=1`, which changes what the status line prints, and one test failed only there.

A live test that starts `claude` in a pane runs it in a folder inside this repo's parent. The maintainer's shell picks the Claude Code config from a marker file in a parent folder, so a scratch folder elsewhere starts the session under the default config and at the folder-trust prompt, and the test observes a setup no real launch has.

A live test that needs a particular model starts the session with `claude --model <id>`. Typing `/model` in a running session also saves the model to the profile's `settings.json` as the default, so it changes every later session on that profile.

## jq in scripts

Build a JSON value from a shell string with `jq -n --arg`, as `fixed_nums` in `resuming`'s `state.sh` does. `jq -R` on empty stdin prints nothing, so a later `--argjson` of that value fails, and a script that goes on after the failure reports empty results as if they were real.

## Checking what a hook did

The terminal and a screenshot show a session's title and state, not what set them. To learn whether a `SessionStart` hook ran and what it printed, read the session's transcript, `$CLAUDE_CONFIG_DIR/projects/<cwd with / as ->/<session id>.jsonl`. Each hook run is an `attachment` record carrying `hookName` (`SessionStart:<source>`), `command` and `stdout`, and the title in force is the last `custom-title` record. A forked or branched session's transcript opens with copies of its parent's records, timestamps included, so a hook run belongs to the new session only when its timestamp is after the fork.
