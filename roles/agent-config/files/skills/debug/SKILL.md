---
name: debug
description: Use when tracking down a bug, test failure, or unexpected behavior — a systematic reproduce → isolate → root-cause → fix → verify workflow instead of guessing at changes.
---

# Debug

Resist changing code until you understand *why* it fails.

1. **Reproduce** — get a reliable repro and capture the exact error/behavior. If you can't reproduce it, you can't fix it.
2. **Isolate** — shrink to the smallest failing case. Bisect the space: input, code path, or git history.
3. **Root-cause** — explain *why* it happens, confirmed by evidence (a log, a probe, a failing assertion) — not a hunch. State the mechanism.
4. **Fix the cause, not the symptom** — and check what else shares that cause.
5. **Verify** — the repro now passes, neighbors still pass, and add a **regression test** so it can't silently return.

If a fix doesn't hold after two tries, stop and re-examine the root-cause assumption.
