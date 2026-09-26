# mp-ported-skills

A Claude Code plugin of skills designed to be compatible with, and to supplement, [Matt Pocock's skills](https://github.com/mattpocock/skills) (installed as the `mattpocock-skills` plugin). They do not replace any of his skills. Each one fills a gap beside them, and follows his conventions: short trigger descriptions, shortcut skills that hand off to the real one, and his vocabulary of design trees, frontiers and rounds.

## Install

This repository is its own plugin marketplace.

```
/plugin marketplace add https://github.com/ChristopherA/mp-ported-skills.git
/plugin install mp-ported-skills@mp-ported-skills
```

The full HTTPS URL clones with no SSH step. The short `ChristopherA/mp-ported-skills` form makes Claude Code test `ssh git@github.com` first, which raises an approval prompt when your GitHub SSH key is hardware-backed (Secure Enclave, a security key).

Install `mattpocock-skills` as well: these skills hand work to his where one already does the job.

## Skills

- **`clarifying`**: settles a mixed list of open items, or a single decision, one question at a time. It sorts the items into settled, facts, frontier, blocked and elsewhere; looks facts up rather than asking; asks each frontier decision with a recommendation; and ends with a summary and a completeness word (full, partial or minimal), taking no action. Use it on the list a `grilling` round, spec or triage hands back.
- **`clarify`**: user-invoked shortcut for `clarifying`, as `grill-me` is for `grilling`.
- **`capturing`**: checks a session at a phase boundary, before `/clear` or `/compact`. It routes whatever is not yet durable to its home (ADR or `CONTEXT.md`, ticket, `clarifying`, `to-questionnaire`), fixes claims the session made stale, asks whether anything should become a rule, commits, and reports one next step, "safe to clear" only when that is true, and a recommendation from Matt's five boundary options.
- **`capture`**: user-invoked shortcut for `capturing`.
- **`resuming`**: recommends one next step, its reason and a runner-up, read from the tracker and git, never by asking the user what they were doing. The first of six cases wins: work in flight, a `ready-for-agent` ticket whose blockers are all closed, lowest number first (`/implement #N`, the step `capturing` leaves), incoming work (`/triage`), an open ticket a commit on the default branch already closes, an open `wayfinder:map`, or nothing in motion. It says which sources it reached, and writes nothing.
- **`next`**: user-invoked shortcut for `resuming`. Not `resume`, which is Claude Code's built-in session picker.
- **`setup-mp-ported-skills`**: user-invoked. Turns each of three profile features on or off, one question per feature, after reporting each as on, off, or modified: Remote Control at startup (`remoteControlAtStartup`), the status line (`statusLine`, the profile's copy and its install stamp), and session titles (`MP_SESSION_TITLE=1`, which also drives status line 1). A plugin cannot set these itself, so they are written into the profile's `settings.json`, backed up first. It replaces another command's `statusLine`, or an edited copy, only on an explicit yes, and never replaces a copy from a later release. After the first copy, the `SessionStart` hook below keeps the status line current.

  The status line's second line reads `[Opus 5.5|medium] 41% of zone`: the model, its effort level, and tokens in context as a percentage of the ~150k-token smart zone, coloured green through 100%, yellow past it, and red from 200%. The bands run past mattpocock-skills' advice to stop at ~150k rather than push on in a degraded session; issue #14 records the evidence and why red starts at 200%. With `MP_SESSION_TITLE=1` in the profile's `env` settings, where the session title already names the project, line 1 shows only what is unusual: a branch other than the default, a detached HEAD, a workstream, or an `--agent` persona, and is left out otherwise. `capturing` reads the same number through `status-line.sh --context`, and `status-line.sh --zone` prints its short form, `41% of zone`.
- **`glance`**: user-invoked. Prints this session's zone reading, `41% of zone`, into the conversation, for claude.ai/code and the Claude app, which show no status line. It runs the plugin's own `status-line.sh --zone`, so a status line installed from an older release still gives a reading. With no reading it says why: no status line in this profile (and that `/setup-mp-ported-skills` turns one on), or none written yet, which happens before the first response or in a session with no terminal.

## Hooks

A `SessionStart` hook runs on startup, `/clear` and `/compact` in repos that have `docs/agents/issue-tracker.md`, and nowhere else. It loads the state `resuming` reads (branch and sync, uncommitted and unpushed counts, open PRs, issues per triage label, ready tickets with closed blockers, the winning case) into Claude's context, with an instruction to open the first reply with a recommendation. It gives up after four seconds (`MP_RESUME_BUDGET`), and prints nothing when the tracker is unreachable, so a slow or offline `gh` never delays or clutters a session.

A second `SessionStart` hook titles the session `<project> · <profile> · <host>` (for example `mp-ported-skills · mattpocock-hub · chryseikori`) when the profile sets `MP_SESSION_TITLE=1` in its `env` settings, and does nothing otherwise. Remote Control pushes the title to claude.ai/code and the Claude app on the first message. The project comes first because claude.ai/code lists sessions without grouping them by project and cuts long titles off at the end. It runs on startup, `/clear` and fork, never on resume or `/compact`, so a `/rename` survives both.

A third `SessionStart` hook keeps the profile's copy of the status line current, in profiles that have one installed (the install stamp, `scripts/status-line.source`, is the opt-in). A copy from an earlier release that has not been edited is replaced from the plugin and restamped. An edited copy is left alone, and the session's startup context gains one line pointing to `/setup-mp-ported-skills`. A copy from a later release than the session's plugin is left alone silently, so a session started before an update never downgrades it. Without `jq` it does nothing. It runs on startup, `/clear` and `/compact`, and never fails a session start.

## Credits

`capturing` is learned from Peter Kaminski's `wrap-up-this-session` skill, published under the MPL-2.0 license, and not copied from it.

`resuming` takes its weighing order, its one step with a runner-up, and its rule of never asking from `cowork-where-was-i` in [claude-cowork-kit](https://github.com/ChristopherA/claude-cowork-kit), and its status and staleness checks from [claude-workstream-kit](https://github.com/ChristopherA/claude-workstream-kit). The problem it solves was met first in [pkai-starter-kit#18](https://github.com/peterkaminski-ai/pkai-starter-kit/issues/18).

The status line ships `scripts/status-line-base.sh` unmodified from [claude-workstream-kit](https://github.com/ChristopherA/claude-workstream-kit) (BSD-2-Clause-Patent), and wraps it.

## Layout

```
.claude-plugin/marketplace.json            the marketplace
plugins/mp-ported-skills/
  .claude-plugin/plugin.json               the plugin
  skills/<skill>/SKILL.md                  one folder per skill
  hooks/hooks.json                         the SessionStart hooks
  scripts/                                 the status line and the title and refresh hooks
tests/                                     test scripts, run with sh
```

## License

[BSD-2-Clause-Patent](LICENSE).
