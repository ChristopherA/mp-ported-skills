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

## Send

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --text "ls -la" </dev/null  # text, then Return
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --key return </dev/null     # Return alone; also tab, or any key (no Return)
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --control c </dev/null      # Ctrl-C; also z, d, l
sh "${CLAUDE_SKILL_DIR}/scripts/pane-send.sh" --session S --window W --tab T --escape </dev/null
```

- **Claude Code can hold pasted text without submitting it.** After sending text to a Claude Code session, send `--key return` as well, or the message sits at its prompt.
- **Never send a heredoc.** Text is typed into the pane's shell line by line, so each line is interpreted as it arrives, and zsh's `!` history expansion fires before quoting takes effect: a body line holding `<!DOCTYPE` or any unquoted `!` breaks the heredoc. Write the content to a file with the Write tool, then send one line that uses the file.

## Read

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-read.sh" --session S --window W --tab T --lines 20 </dev/null
```

It prints the pane's contents with the terminal's trailing blank lines removed, and `--lines N` keeps the last N. Leave it off only when the whole scrollback is needed.

When polling for a command to finish, the pane shows the command itself as well as its output. Three traps follow:

- **The echoed command matches its own marker.** In `make && echo DONE`, the prompt line already holds `DONE` before `make` starts, so a poll for `DONE` passes at once.
- **A string built at runtime matches too.** `bash -c 'work; echo "=== done ==="'` shows `=== done ===` on the prompt line even though no echo has run yet. Poll a result instead: a file the work writes, its size, or a value only success produces, such as a marker generated fresh for each poll.
- **`tee` hides an interactive prompt.** In `script | tee out.log`, `tee` buffers the output, so a later `Password:` or `[y/N]` never reaches the pane, and the pane looks hung. Write to a file instead (`script > out.log 2>&1`), or run `sudo -v` first.

## Close

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-close.sh" --session S --window W --tab T --force </dev/null
```

Without `--force`, `pane-close.sh` refuses (exit 2), because it cannot yet tell whether a session in the pane is busy. Read the pane, and pass `--force` only when nothing there should keep running. Close a pane when its work is done: a pane left open is a stale session, and for SSH a stale connection.

## Find a pane again

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/pane-find.sh" --session 2E3F4A </dev/null   # any part of the session id
sh "${CLAUDE_SKILL_DIR}/scripts/pane-tty.sh" S </dev/null                   # the pane's TTY
```

`pane-find.sh` prints the pane's coordinates, or one line per match, with the pane's name, when several match. `pane-tty.sh` prints the pane's TTY, or nothing when no pane has that id.

## Errors

Each script exits non-zero with a message on stderr when its arguments are wrong. The scripts that take coordinates also say so plainly when the pane no longer exists: `no pane with session ... (closed, or wrong coordinates)`.
