# Shared agent instructions (managed by debspin)

Deployed fleet-wide to every coding agent — **Claude Code** (`~/.claude/CLAUDE.md`),
**opencode** (`~/.config/opencode/AGENTS.md`), and **Codex** (`~/.codex/AGENTS.md`).
Edit `roles/agent-config/files/AGENTS.md`, `git push`, and every machine + agent
picks it up on the next pull.

> This file is the single source of truth for standing instructions across all
> agents. Replace the sections below with your own conventions.

## Conventions
- Match the surrounding code's style, naming, and structure.
- Prefer small, verifiable changes; run tests/build before declaring done.
- Ask before destructive or irreversible actions.

## Project defaults
- (add your coding standards, stack preferences, do/don't here)
