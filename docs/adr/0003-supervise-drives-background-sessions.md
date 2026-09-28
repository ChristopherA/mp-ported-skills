# `/supervise` drives Claude Code background sessions, one ticket at a time

The maintainer builds by hand in a loop: `/next`, `/implement #N`, `/capturing`, `/clear`, repeat. `/supervise` automates that loop. It launches each step as a Claude Code background session (`claude --bg '<command>'`), reads state from `claude agents --json` and the session transcript, sends follow-ups with `--resume`, and starts a new session where the loop would `/clear`. A session can neither clear itself nor start a user-invoked skill, so something outside it has to do both. A command given as a background session's first prompt enters through the human's door, so every ticket gets the full `/implement`, with its TDD and its own `/code-review`. The supervisor may drive build-loop defaults and stops for anything that changes the spec. Standing grants for push and other shared actions are recorded explicitly in each Project's `docs/agents/supervision.md`, and with no grant every shared action stops for approval.

## Considered Options

- **Port mattpocock-skills' `implement-spec`.** Parallel subagents in worktrees, with one `/code-review` over the whole branch. Rejected: a subagent cannot invoke a user-invoked skill (anthropics/claude-code#43809), so its workers skip `/implement`, and each ticket loses its TDD and its own review. Its workers also have no capture-and-clear loop.
- **Drive sessions in iTerm2 panes.** Built on `iterm-pane`: type commands into a pane and classify the screen. Rejected once a spike showed background sessions do the same through the human's door, with a JSON status API and no iTerm2, AppleScript or screen classifier. `iterm-pane` stays for work that needs a real terminal.

## Consequences

- Tickets run one after another. Running them in parallel worktrees (`--bg` with `-w`) is untested, and would bring in the branch-first session title (#43).
- A permission prompt the session cannot clear stops it until a human opens it with `claude attach <id>`, so sessions launch with `--permission-mode auto`.
- There is no command that sends input to a running background session, so a follow-up means `stop`, then `--resume`, and a resume issued before the stop finishes starts a copy under a new id.
- The supervisor depends on the plain `claude` CLI and on Claude Code's background-session commands, which may change between releases.
