---
name: code-review
description: Use to review a diff or PR before merging — checks correctness, security, simplicity, and performance, ranked by severity, each backed by a concrete failure scenario.
---

# Code review

Review the change (`git diff`), reporting most-severe first. Every finding needs a concrete failure scenario — inputs/state → wrong result — or it's not a finding.

1. **Correctness** — logic errors, off-by-one, null/undefined, unhandled errors, race conditions, wrong edge-case behavior.
2. **Security** — injection, missing authz, exposed secrets, unsafe deserialization, unvalidated input.
3. **Simplicity & reuse** — duplication, dead code, or a simpler/existing approach the change ignored.
4. **Performance** — needless work, N+1 queries, allocations or IO in hot paths.

Rules: skip style nits unless they hide a bug. Don't invent problems to seem thorough — if the code is fine, say so. Be specific: `file:line` + the concrete fix.
