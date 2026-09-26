# mp-ported-skills

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `ChristopherA/mp-ported-skills`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, each label string equal to its role name, plus a `research` label and a priority line in the issue body. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Tests

Tests are `tests/*.test.sh`, run with `sh`. Every `git commit` a test makes in a scratch repo passes `-c commit.gpgsign=false`: the maintainer's global git config signs commits, and a signing prompt hangs a test that has no terminal.
