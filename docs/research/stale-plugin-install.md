# Why the installed plugin stayed at 0.8.18 (#238)

On 2026-11-01 a supervisor loaded this plugin at 0.8.18 while `main` was at 0.8.111. Its profile's `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json` entry read `"version": "0.8.18"`, `"lastUpdated": "2026-10-02T00:40:51.946Z"`, and the cache held only `0.8.18`.

## What the transcripts show

The workers' updates did reach the profile. Every `claude plugin update mp-ported-skills@mp-ported-skills` call found in the profile's transcripts from 2026-10-20 to 2026-10-27 printed a one-step move under `scope user`, from `0.8.91 to 0.8.92` (2026-10-20) up to `0.8.108 to 0.8.109` (2026-10-27). The transcripts before 2026-10-20 have been cleaned up, so the 2026-10-02 to 2026-10-20 updates cannot be read.

The skill paths each session loaded (the `Base directory for this skill:` line of its first skill call) give the version it ran:

| Sessions | Config folder | Version loaded |
|---|---|---|
| up to 2026-10-27 21:02 UTC | the profile's old folder name | 0.8.100 rising to 0.8.111 |
| 2026-11-01 16:00 and 22:18 UTC | the new folder name | 0.8.18 |
| 2026-11-01 23:01 UTC on | the new folder name | 0.8.112 and up |

Between the two, on 2026-10-27 at 14:42 local time, the profile's config folder was renamed (the same folder: its birth time is unchanged, and a debug symlink inside it still points at the old name). The first sessions under the new name, five days later, ran 0.8.18. The install record went stale at the rename, not through failed updates. The 22:18 supervisor's `claude plugin update` moved it `from 0.8.18 to 0.8.111`, and later updates stepped one version at a time again.

## What is not known

Why the record under the renamed folder read the 2026-10-02 state is not recoverable. No debug log, backup of the record or Claude Code binary from that time is left on the machine. The current binary (2.1.329) holds a migration that renames `installed_plugins_v2.json` over `installed_plugins.json`, and file names for records it sets aside (`installed_plugins.set-aside.<date>.<hash>.json`). A record that Claude Code kept elsewhere from about 0.8.18 on, and that the first start under the new folder name did not carry over, fits the evidence, but this is not confirmed.

## What changed

Whatever the cause, a stale install is now reported at a session's start. `resuming`'s `state.sh` prints a `plugin:` line when the plugin running it is a cache version older than the `plugin.json` on the checkout's remote default branch, naming the update command and `/reload-plugins`, and `supervise`'s `step.sh` passes the line on on stderr. After renaming or moving a profile's config folder, run the plugin update once and check the installed version.
