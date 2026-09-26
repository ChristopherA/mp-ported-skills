# A plugin hook refreshes the profile's copy of the status line

A profile's `statusLine` can't come from a plugin: in Claude Code 2.1.283 a plugin's `settings.json` keeps only `agent` and `subagentStatusLine`, and `${CLAUDE_PLUGIN_ROOT}` is available in plugin hooks but not in settings. The plugin's cache path also changes on every update, so the setting has to name a stable copy inside the profile. We keep that copy current with the plugin's own SessionStart hook: when the profile has opted in to the status line, the hook replaces an out-of-date copy from the plugin. `/setup-mp-ported-skills` only writes settings and makes the first copy.

## Considered Options

- **The installer copies, and you re-run it after each update** (the original `install-statusline`). Rejected: copies go stale silently, and `/glance` had already been designed around that staleness.
- **`statusLine` runs a command that finds the newest cached copy on each refresh.** Rejected: it depends on the plugin cache layout, which isn't a public contract, and pays for that lookup on every status line refresh.

## Consequences

- The hook writes files into the profile, so it must never overwrite a copy that has been edited since it was installed. It tells edited copies apart from out-of-date ones with the install stamp (`scripts/status-line.source`). An edited copy is left alone, with one line in the session's startup context. A copy newer than the session's plugin is left alone silently, so a session started before an update never downgrades it. A copy whose release cannot be ordered against the plugin's (a pre-release) is left alone too, with one line, because neither is known to be older.
- The stamp file doubles as the status line's opt-in marker.
