---
name: example-skill
description: Example debspin-managed skill — a template you replace with your own. Shows the SKILL.md format that debspin syncs to ~/.claude/skills on every machine.
---

# debspin-managed skill

This skill was deployed fleet-wide by **debspin** from the repo.

To manage skills across all your machines:
1. Add or edit `roles/agent-config/files/skills/<name>/SKILL.md`
2. List the folder name in `claude_skills:` in `group_vars/all.yml`
3. `git push` — every machine picks it up on its next pull.

Replace this text with real instructions for the skill.
