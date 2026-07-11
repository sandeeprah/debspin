---
name: plan-feature
description: Use before implementing a non-trivial change — turns a request into a concrete, ordered implementation plan grounded in the actual codebase (files to touch, steps, verification). For "implement / add / build X" that spans more than a couple of files.
---

# Plan a feature

Plan before you code; the plan is the anti-drift anchor.

1. **Clarify** — restate the goal and acceptance criteria. Ask only *blocking* questions; assume sensible defaults otherwise.
2. **Explore first** — find the relevant files, existing patterns, and utilities to **reuse**. Never propose new code where a suitable helper already exists.
3. **Order the work** — a numbered plan where each step says *what changes, which file(s), and why*. Prefer small, independently verifiable steps; do a thin end-to-end slice before breadth.
4. **De-risk** — name the edge cases and failure modes, and how each step is verified (test / build / run the flow).
5. Keep it scannable and reference **real file paths**. Don't enumerate every line — describe repeated patterns once.
