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

A change under `plugins/mp-ported-skills/` bumps `version` in its `.claude-plugin/plugin.json`, in its own commit titled `Bump plugin to X.Y.Z`, after the change's commit: the plugin cache is keyed by version, so installs fetch the change only under a new one. Tests, docs and this file ship outside the plugin and take no bump.

## Tests

Tests are `tests/*.test.sh`, run with `sh`. Every `git commit` a test makes in a scratch repo passes `-c commit.gpgsign=false`: the maintainer's global git config signs commits, and a signing prompt hangs a test that has no terminal.

Each test sets or unsets every environment variable the scripts it runs read, so it gives the same result in any session. The maintainer's sessions set `MP_SESSION_TITLE=1`, which changes what the status line prints, and one test failed only there.
