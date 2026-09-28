# Pane state captures

Full `pane-read.sh` output from live Claude Code sessions in iTerm2 panes, for testing the pane state classifier. Each file is named `<state>-<variant>.txt`, so a test can loop over `<state>-*.txt` and check that every file classifies as its state.

| State | What the pane shows |
|---|---|
| `working` | Claude is thinking (spinner above the prompt) or streaming a reply. While a reply streams, no spinner is on screen; the text above the prompt grows between reads. |
| `waiting` | Claude is idle at its input prompt: fresh, after a reply, with a background shell still running, or with a draft typed but not sent (`waiting-unsent-text`). |
| `asking` | A question (`asking-question-*`), a tool permission prompt (`asking-permission-*`), or the folder-trust prompt shown before a session starts (`asking-trust`). |
| `shell` | Claude has exited and the pane is at a shell prompt. After `/exit` the scrollback keeps only the launch command and the resume hint, not the session's text. |
| `gone` | The pane was closed. `gone.txt` is `pane-read.sh`'s stderr; it also exits 1. |

The `-narrow` files come from a pane about 27 columns wide, where lines wrap and the status line is cut off. The `-fable` files come from Fable 5.1; the rest are Opus 5.5. The `[Model|effort] N% of zone` line is this plugin's status line.

Usernames, hostnames, local paths, tty names and the plan name were replaced with placeholders (`user`, `workstation`, `/Users/user/src/project`, `ttys000`, `Claude Pro`). Where a replacement changed a string's length, the separator rule was padded to keep its width, and wrapped paths were joined onto one line.
