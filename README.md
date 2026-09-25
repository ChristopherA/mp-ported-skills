# mp-ported-skills

A Claude Code plugin of skills designed to be compatible with, and to supplement, [Matt Pocock's skills](https://github.com/mattpocock/skills) (installed as the `mattpocock-skills` plugin). They do not replace any of his skills. Each one fills a gap beside them, and follows his conventions: short trigger descriptions, shortcut skills that hand off to the real one, and his vocabulary of design trees, frontiers and rounds.

## Install

This repository is its own plugin marketplace.

```
/plugin marketplace add ChristopherA/mp-ported-skills
/plugin install mp-ported-skills@mp-ported-skills
```

Install `mattpocock-skills` as well: these skills hand work to his where one already does the job.

## Skills

- **`clarifying`**: settles a mixed list of open items, or a single decision, one question at a time. It sorts the items into settled, facts, frontier, blocked and elsewhere; looks facts up rather than asking; asks each frontier decision with a recommendation; and ends with a summary and a completeness word (full, partial or minimal), taking no action. Use it on the list a `grilling` round, spec or triage hands back.
- **`clarify`**: user-invoked shortcut for `clarifying`, as `grill-me` is for `grilling`.
- **`capturing`**: checks a session at a phase boundary, before `/clear` or `/compact`. It routes whatever is not yet durable to its home (ADR or `CONTEXT.md`, ticket, `clarifying`, `to-questionnaire`), fixes claims the session made stale, asks whether anything should become a rule, commits, and reports one next step, "safe to clear" only when that is true, and a recommendation from Matt's five boundary options.
- **`capture`**: user-invoked shortcut for `capturing`.
- **`install-statusline`**: user-invoked. Installs a status line into the current profile whose second line reads `[Model] 62k / 150k`, tokens used against the ~150k-token smart zone, coloured green, yellow, then red past it. It reports first (in sync, behind, or locally modified, per file), sets `statusLine` only if none is set, and replaces an existing one or an edited copy only on an explicit yes. `capturing` reads the same number through `status-line.sh --context`.

## Credits

`capturing` is learned from Peter Kaminski's `wrap-up-this-session` skill, published under the MPL-2.0 license, and not copied from it.

`install-statusline` ships `status-line-base.sh` unmodified from [claude-workstream-kit](https://github.com/ChristopherA/claude-workstream-kit) (BSD-2-Clause-Patent), and wraps it.

## Layout

```
.claude-plugin/marketplace.json            the marketplace
plugins/mp-ported-skills/
  .claude-plugin/plugin.json               the plugin
  skills/<skill>/SKILL.md                  one folder per skill
tests/                                     test scripts, run with sh
```

## License

[BSD-2-Clause-Patent](LICENSE).
