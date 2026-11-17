# agent-skills

Private collection of agent skills, each one a folder with `SKILL.md` at its root.

| Skill | What it does |
|---|---|
| [qa-evidence](qa-evidence/) | Records a browser test as real video with a drawn cursor, highlights and captions, plus GIF, contact sheet, step stills and SRT. Skill name: `browser-evidence-captions`. |

## Install a skill

Clone the repo and copy the folder you want into the place your harness reads skills from:

```bash
git clone git@github.com:rizalmuhammad/agent-skills.git /tmp/agent-skills
cp -r /tmp/agent-skills/qa-evidence ~/.openbot/skills/browser-evidence-captions
```

Keep the folder name matching the `name:` in that skill's `SKILL.md`. Each skill's own README covers requirements and usage.
