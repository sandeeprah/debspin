---
name: write-tests
description: Use when adding tests for a change or defining a test strategy — covers behavior, boundaries, and failure modes in the repo's existing framework and style, and actually runs them.
---

# Write tests

1. **Identify the contract** — what behavior are we pinning down? Inputs, outputs, and side effects.
2. **Match the repo** — find an existing test first; copy its framework, structure, fixtures, and naming. Don't introduce a new test style.
3. **Cover what matters** — happy path, boundaries (empty/zero/max/off-by-one), error and failure cases, and any ordering/concurrency. Skip trivial getters.
4. **Test behavior, not implementation** — assert on observable contracts so refactors don't break the tests spuriously.
5. **Run them** — the tests must genuinely pass, and fail if the behavior regresses. Don't assert on state you didn't set up, and don't write a test that can't fail.
