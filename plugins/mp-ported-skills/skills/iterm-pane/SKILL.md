---
name: iterm-pane
description: Open, drive, read and close iTerm2 split panes through AppleScript. Use when a command needs a real terminal (sudo, a password, biometrics), or to run and watch a process or a Claude Code session beside this one.
---

The Bash tool has no TTY, so anything that prompts (sudo, a password, a biometric check, an installer that escalates) fails there. A split pane beside this session is a real terminal: open one, send it text and keys, read its contents back, and close it. For a prompt, open the pane first rather than trying Bash and failing.

Needs macOS and iTerm2, with no tmux around this session.

## Open

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-open.sh" --direction vertical </dev/null
```

It prints the new pane's coordinates, `SESSION_ID WINDOW_ID TAB_NUM`, for example `F1C3A2B4-0D6E-4A7B-9C1D-2E3F4A5B6C7D 1234 1`. Every other script takes them as `--session`, `--window` and `--tab`. Shell variables do not survive between Bash calls, so write the three values into each later command, as the examples below do with `S`, `W` and `T`.

- `--direction` names the **divider**, not where the pane goes: `vertical` (the default) puts the new pane to the right, `horizontal` puts it below. When the user asks for a pane "below" or "underneath", pass `horizontal`.
- `--command "cmd"` types a first command into the new pane. `--profile "Name"` uses an iTerm2 profile.
- It splits the pane on this session's TTY, so it lands in the right window whichever one is in front.

## Launch a Claude Code session

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-launch.sh" --dir /path/to/project --permission-mode acceptEdits --message "Run the tests" </dev/null
```

It opens a pane, changes into `--dir` and starts plain `claude` there, and prints the pane's coordinates as `pane-open.sh` does. `--dir` is required; a missing one, or one that is not a directory, exits 1 before any pane opens. `--permission-mode`, `--message` (the session's first message) and `--direction` are optional. The values are single-quoted in the pane's shell, so a message holding `!`, `$`, backticks or either quote reaches `claude` as written. It writes no state file, and it does not wait for the session to come up: read the pane to see that it has.

- **A folder Claude Code has not trusted stops at the trust prompt.** `claude` opens on "Is this a project you created or one you trust?" with `No, exit` selected, and `--message` waits behind it, so the session looks started but idle. After a launch, `pane-wait.sh --state waiting,asking`, then `pane-classify.sh --detail`: on `trust`, tell the user which folder the pane is asking about and leave the prompt for them. Never answer it: trusting a folder changes the user's config, and a Return sent to the pane confirms `No, exit`.

## Send

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --text "ls -la" </dev/null  # text, then Return
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --key return </dev/null     # Return alone; also tab, or any key (no Return)
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --control c </dev/null      # Ctrl-C; also z, d, l
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --escape </dev/null
```

- **Claude Code can hold pasted text without submitting it.** After sending text to a Claude Code session, send `--key return` as well, or the message sits at its prompt.
- **Never send a heredoc.** Text is typed into the pane's shell line by line, so each line is interpreted as it arrives, and zsh's `!` history expansion fires before quoting takes effect: a body line holding `<!DOCTYPE` or any unquoted `!` breaks the heredoc. Write the content to a file with the Write tool, then send one line that uses the file.

## Slash command

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-slash.sh" --session S --window W --tab T compact keep the plan </dev/null
```

It types `/compact keep the plan` through `pane-send.sh`, then sends Return as a separate key. The leading `/` is optional and never doubled. The arguments are joined with spaces and reach the pane as written, `!`, `$`, backticks and quotes included. Put `--` before a command whose arguments start with `-`. A missing command name exits 1 and sends nothing.

- **It types after anything already at the prompt.** A draft left in the input box becomes part of the command, so check that the pane is `waiting` with an empty prompt first.
- **One Return may not submit.** Read the pane afterwards. If the text is still in the input box, send `--key return` again. Slash commands have submitted on the first Return. Prose messages sent the same way have needed a second one.
- **`/model X` saves X as the default model** in the profile's `settings.json`, which changes every later session on that profile, not just this one.

## Read

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-read.sh" --session S --window W --tab T --lines 20 </dev/null
```

It prints the pane's contents with iTerm2's padding removed (trailing spaces on each line, blank lines at the end), so a whole-line match works, and `--lines N` keeps the last N. Leave it off only when the whole scrollback is needed.

When polling for a command to finish, the pane shows the command itself as well as its output. Three traps follow:

- **The echoed command matches its own marker.** In `make && echo DONE`, the prompt line already holds `DONE` before `make` starts, so a poll for `DONE` passes at once.
- **A string built at runtime matches too.** `bash -c 'work; echo "=== done ==="'` shows `=== done ===` on the prompt line even though no echo has run yet. Poll a result instead: a file the work writes, its size, or a value only success produces, such as a marker generated fresh for each poll.
- **`tee` hides an interactive prompt.** In `script | tee out.log`, `tee` buffers the output, so a later `Password:` or `[y/N]` never reaches the pane, and the pane looks hung. Write to a file instead (`script > out.log 2>&1`), or run `sudo -v` first.

## Session state

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-classify.sh" --session S --window W --tab T </dev/null
sh "${CLAUDE_SKILL_DIR}/scripts/pane-wait.sh" --session S --window W --tab T --state waiting,asking --timeout 600 </dev/null
```

`pane-classify.sh` prints exactly one state:

| State | The pane shows |
|---|---|
| `working` | Claude Code is thinking (a spinner above its prompt) or streaming a reply; or another program is running, since no shell prompt is last |
| `waiting` | Claude Code is idle at its input prompt, including with a draft typed but not sent |
| `asking` | a question, a tool permission prompt, or the folder-trust prompt |
| `shell` | Claude Code is not running and a shell prompt (a line ending in `%`, `$`, `#`, `>` or `❯`) is last |
| `gone` | the pane no longer exists |

It reads the bottom of the screen, never the model name, so it works on any model. `--file PATH` (`-` for stdin) classifies a saved `pane-read.sh` capture instead of a live pane.

`--detail` adds a second line when the state is `asking`, naming the open prompt: `trust` (the folder-trust prompt), `question` (a question the session asked), `permission` (a tool permission prompt) or `other`. Every other state prints alone, so the first line is always the state.

- **Streaming has no spinner.** While a reply streams, the screen has the same shape as a finished one. The difference is how the turn ended: a done line (`✻ Worked for 42s · done`), an `Interrupted` or an `API Error` under the message. A user message with none of these below it is still `working`. A slash command that starts no turn (`/model`) reads as `waiting`.

`pane-wait.sh` polls the state, not the pane's text, so an echoed command cannot satisfy it. It prints the state reached and exits 0, or on timeout prints the last state seen and exits 124. `--state` takes one state or several separated by commas; `--timeout` defaults to 300 seconds and `--interval` to 2.

## Close

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-close.sh" --session S --window W --tab T </dev/null
```

Without `--force`, `pane-close.sh` classifies the pane first. It closes a pane at `shell`, so a pane running a build or waiting at `Password:` stays open, prints `gone: the pane is already closed` and exits 0 for `gone`, and refuses (exit 2, naming the state) a pane that is `working`, `waiting` or `asking`. To close a Claude Code session, end it first (`pane-slash.sh ... exit`, then wait for `shell`), or pass `--force` when nothing there should keep running. Close a pane when its work is done: a pane left open is a stale session, and for SSH a stale connection.

## Find a pane again

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-find.sh" --session 2E3F4A </dev/null   # any part of the session id
sh "${CLAUDE_SKILL_DIR}/scripts/pane-tty.sh" S </dev/null                   # the pane's TTY
```

`pane-find.sh` prints the pane's coordinates, or one line per match, with the pane's name, when several match. `pane-tty.sh` prints the pane's TTY, or nothing when no pane has that id.

## Errors

Each script exits non-zero with a message on stderr when its arguments are wrong. The scripts that take coordinates also say so plainly when the pane no longer exists: `no pane with session ... (closed, or wrong coordinates)`.
