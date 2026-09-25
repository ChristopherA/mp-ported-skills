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

None yet.

## Layout

```
.claude-plugin/marketplace.json            the marketplace
plugins/mp-ported-skills/
  .claude-plugin/plugin.json               the plugin
  skills/<skill>/SKILL.md                  one folder per skill
```

## License

[BSD-2-Clause-Patent](LICENSE).
