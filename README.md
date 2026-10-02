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
- **`capturing`**: checks a session at a phase boundary, before `/clear` or `/compact`. It routes whatever is not yet durable to its home (ADR or `CONTEXT.md`, ticket, `clarifying`, `to-questionnaire`), labels the `ready-for-human` ticket it worked on `in-motion`, fixes claims the session made stale, asks whether anything should become a rule, commits, reports one next step and "safe to clear" only when that is true, offers the before-clear jobs (push, ticket closes, a plugin update run through Bash) as one multi-select question, and recommends one of Matt's five boundary options. In a session nobody can answer, such as a `/supervise` worker resumed with `/mp-ported-skills:capturing`, it asks nothing: it runs the jobs `supervise`'s standing grants cover, lists the rest with their commands, and still ends with its report and recommendation (#89).
- **`capture`**: user-invoked shortcut for `capturing`.
- **`resuming`**: recommends one next step, its reason and a runner-up, read from the tracker and git, never by asking the user what they were doing, and asks it as one question whose pick starts the step or repeats a command for the user to type. The first of seven cases wins: work in flight (including the ticket `capturing` labelled `in-motion`, or that ticket's next open child with its blockers closed when it is a parent), a `ready-for-agent` ticket whose blockers are all closed, lowest number first (`/implement #N`, the step `capturing` leaves), incoming work (`/triage`), an open ticket a commit on the default branch already closes, an open `wayfinder:map`, a `ready-for-human` ticket whose blockers are all closed, highest priority line first, or nothing in motion. A ticket labelled `parked` is never the step. It says which sources it reached, and writes nothing.
- **`next`**: user-invoked shortcut for `resuming`. Not `resume`, which is Claude Code's built-in session picker.
- **`setup-mp-ported-skills`**: user-invoked. Turns each of three profile features on or off, one question per feature, after reporting each as on, off, or modified: Remote Control at startup (`remoteControlAtStartup`), the status line (`statusLine`, the profile's copy and its install stamp), and session titles (`MP_SESSION_TITLE=1`, which also drives status line 1). A plugin cannot set these itself, so they are written into the profile's `settings.json`, backed up first. It replaces another command's `statusLine`, or an edited copy, only on an explicit yes, and never replaces a copy from a later release. A copy from a release it cannot order against its own, such as a pre-release, it replaces only on an explicit yes. After the first copy, the second `SessionStart` hook below keeps the status line current.

  The status line's second line reads `[Opus 5.5|medium] 41% of zone`: the model, its effort level, and tokens in context as a percentage of the ~150k-token smart zone, coloured green through 100%, yellow past it, and red from 200%. The bands run past mattpocock-skills' advice to stop at ~150k rather than push on in a degraded session; issue #14 records the evidence and why red starts at 200%. With `MP_SESSION_TITLE=1` in the profile's `env` settings, where the session title already names the project, line 1 shows only what is unusual: a branch other than the default, a detached HEAD, a workstream, or an `--agent` persona, and is left out otherwise. `capturing` reads the same number through `status-line.sh --context`, and `status-line.sh --zone` prints its short form, `41% of zone`. `status-line.sh --pane-zone` reads that short form back from a pane's text, taking the last status line on screen, so a supervisor can read a session it runs in a pane.
- **`glance`**: user-invoked. Prints this session's zone reading, `41% of zone`, into the conversation, for claude.ai/code and the Claude app, which show no status line. It runs the plugin's own `status-line.sh --zone`, so a status line installed from an older release still gives a reading. With no reading it says why: no status line in this profile (and that `/setup-mp-ported-skills` turns one on), or none written yet, which happens before the first response or in a session with no terminal.
- **`supervise`**: user-invoked. `/supervise <project-folder>` runs that Project's next ticket end to end from another session, such as the Hub. It takes the step from `resuming`'s `state.sh` and, only when that step is `/implement #N` for a `ready-for-agent` ticket with nothing else in flight, starts `/mattpocock-skills:implement #N` as a Claude Code background session in auto mode, with the profile's config dir set explicitly. It then checks the job's state that the session runs under that profile, in the Project's folder rather than a worktree, and in auto mode, and stops it if not. It watches the session through `claude agents --json` until the session is done or blocked, and reports the ticket's commits, or what the session waits for with `claude attach <id>`. It answers no question or permission prompt, and performs no shared action: a push or PR the ticket reaches is reported as blocked. The one exception is a comment on the ticket holding the run's record: time to turn end, how late the report came, API calls, tokens and cost by model, the supervisor's own share, the peak zone reading, captures and clears, human interventions, shared actions and outcome. With those comments, runs can be compared in the tracker. With `--watch tmux`, it opens a tmux window running `claude attach <id>` after the launch and after each follow-up, which closes when the worker stops; watch it with `tmux attach -t mp-supervise`. One ticket, then it stops. ADR 0003 records the design.
- **`iterm-pane`**: opens, drives, reads and closes iTerm2 split panes through AppleScript, for anything that needs a real terminal (sudo, a password, biometrics), since the Bash tool has none, or to run and watch a process or a Claude Code session beside this one. Its scripts open a pane beside the caller's (`--direction` names the divider, so `horizontal` puts the pane below), send text, keys and control characters, read the contents with iTerm2's padding trimmed, find a pane again from part of its session id, and close it. A launcher opens a pane, changes into a directory and starts plain `claude` there, with an optional permission mode and first message. A slash-command sender types `/name args` into a Claude Code pane and submits it with a separate Return. A classifier reads the bottom of a pane and reports whether its Claude Code session is working, waiting at its prompt, asking a question, exited to a shell, or gone, without reading the model name, and on request which prompt is open, so a supervisor can report a folder-trust prompt instead of answering it; a wait script blocks until a pane reaches a given state, and the close refuses a pane with a live session unless given `--force`. `SKILL.md` documents the traps: Claude Code holding pasted text until a separate Return, heredocs broken by zsh `!` expansion, and polls fooled by the echoed command line or by `tee` buffering a prompt. Ported from the maintainer's own `iterm-pane` skill, with its agent-role launcher replaced and without its verifier. Needs macOS and iTerm2, with no tmux.

## Hooks

Three `SessionStart` hooks run. The first titles the session `<project> · <profile> · <host>` (for example `mp-ported-skills · mattpocock-hub · chryseikori`) when the profile sets `MP_SESSION_TITLE=1` in its `env` settings, and does nothing otherwise. Remote Control pushes the title to claude.ai/code and the Claude app on the first message. The project comes first because claude.ai/code lists sessions without grouping them by project and cuts long titles off at the end. It runs on startup, `/clear` and fork, never on resume or `/compact`. A `/rename`d name survives all of these: Claude Code keeps it over the hook's title, even on `/clear`. Neither `/branch` nor `claude -r <id> --fork-session` sends the fork event, so a session forked with `--fork-session` keeps its parent's title, and one made with `/branch` gets Claude Code's `<first prompt> (Branch N)`.

The second keeps the profile's copy of the status line current, in profiles that have one installed (the install stamp, `scripts/status-line.source`, is the opt-in). A copy from an earlier release that has not been edited is replaced from the plugin and restamped. An edited copy is left alone, and the session's startup context gains one line pointing to `/setup-mp-ported-skills`. A copy from a later release than the session's plugin is left alone silently, so a session started before an update never downgrades it. A copy from a release that cannot be ordered against the plugin's, such as a pre-release, is left alone too, with one line pointing to `/setup-mp-ported-skills`. Without `jq` it does nothing. It runs on startup, `/clear` and `/compact`, and never fails a session start.

The third acts only in a background session (`claude --bg`, as `/supervise` runs its workers). It puts `scripts/worker-bin` first on the PATH of every Bash command the session runs, so each `git` and `gh` it calls by name, including from inside a script, refuses a push, PR or issue close unless a standing grant in the Project's `docs/agents/supervision.md` covers it (docs/adr/0006). An interactive session is untouched. It runs on every session start.

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
  hooks/hooks.json                         the SessionStart and PreToolUse hooks
  scripts/                                 the status line, the hooks, and the worker-bin git and gh wrappers
tests/                                     test scripts, run with sh
tests/live/                                tests that need a live iTerm2, run by hand
```

## License

[BSD-2-Clause-Patent](LICENSE).
