---
name: design-fullstack
description: Use when designing a new feature or service end-to-end — data model, API contract, backend, and frontend, with the integration points and tradeoffs. For "design / architect X" questions that span the stack.
---

# Full-stack design

Design from the data outward — a wrong data model is the most expensive thing to change.

1. **Domain & data** — entities, key fields, relationships, and invariants. Note migrations/indexes needed.
2. **API contract** — endpoints/RPCs with request & response shapes, auth, pagination, and the error cases. This is the seam everything else builds against.
3. **Backend** — services/handlers, validation, side effects, transactions, and any background/async work.
4. **Frontend** — components, state ownership, data-fetching, and the loading / error / empty states (not just the happy path).
5. **Cross-cutting** — auth boundaries, caching, observability, idempotency, and failure/rollback behavior.

For each layer, state the main tradeoff and one alternative. Finish with an **ordered build sequence** that ships a thin vertical slice first, then widens.
