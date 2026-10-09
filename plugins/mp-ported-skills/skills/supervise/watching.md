# Watching

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

With `--watch tmux`, the maintainer can watch the worker in tmux. Open a viewer once after `launch.sh` succeeds and once after each `resume.sh` that printed `resumed ID`:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --id ID --dir "<project folder>" </dev/null
```

It opens a window in the tmux session `mp-supervise` whose own command is `claude attach ID`, so the window closes by itself when the worker is stopped, and the session ends with its last window. It prints the window and the watch command. Pass both lines on in the next message to the maintainer, with the rule below. Exit 1: no viewer opened, for the reason it names. Report it and go on: the run does not depend on the viewer.

With `--watch iterm`, the viewer is an iTerm2 split pane beside this session, opened at the same times, with nothing to attach by hand:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --iterm --id ID --dir "<project folder>" </dev/null
```

It splits this session's pane through `iterm-pane`'s `pane-open.sh`, and the pane's first command changes into the folder and runs `exec env CLAUDE_CONFIG_DIR=<this profile> <claude> attach ID`, since the pane's login shell does not inherit the profile. The pane's shell ends with the viewer, so under a profile that closes a session when it ends (iTerm2's default profile does) the pane closes by itself within a few seconds of the worker's stop (seen live on Claude Code 2.1.288, #102). `SKILL.md`'s Report step closes it in any case, since run within a second of the stop it can still find the pane open. It prints `viewer iterm pane <session> <window> <tab> runs claude attach ID` and the `close:` command; keep the coordinates for that command, and pass both lines on to the maintainer. Exit 1: no pane opened, with one line naming why: this session runs inside tmux, is not in iTerm2, or was started by the `claude remote-control` server from the app (its terminal is the server's own pane), or `pane-open.sh` failed. Report that line and go on without a viewer.

Never open a viewer at any other time, and never in a loop. Attaching wakes a stopped session, so a viewer opened between `resume.sh`'s stop and its resume makes the resume start a copy and splits the worker (#55).

Tell the maintainer, with the watch command (`tmux attach -t mp-supervise`, or `tmux -CC attach -t mp-supervise` in iTerm2) or the pane:

- the viewer is live: what they type there reaches the worker as a prompt, and answering a permission prompt there is fine;
- attaching to the worker by hand (`claude attach ID`, or a viewer of their own) between a stop and a resume splits the worker. Leaving the tmux session (`Ctrl+B d`) is always safe; with `--watch iterm`, leave the pane for the supervisor to close.

## Closing the viewer

With `--watch tmux`, once the worker is stopped or gone, remove the tmux session too, so the run leaves none behind:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --close </dev/null
```

It prints `closed mp-supervise`, or `no tmux session mp-supervise` when the window already closed with the worker. With `--watch iterm`, close the pane instead, with the coordinates `view.sh` printed when it opened it:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/view.sh" --close --pane '<session> <window> <tab>' </dev/null
```

It prints `closed pane <session>`, or `pane <session> already closed` when iTerm2 closed it with the viewer. It closes the pane whatever runs there, so never call it while the worker runs.
