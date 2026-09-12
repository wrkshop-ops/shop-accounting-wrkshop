---
name: shop-accounting-production
description: Maintain a live shared-workspace application with cautious data changes, secure CRUD, and mandatory real-site verification before delivery.
---

# Production workflow

- Treat the deployed accounting app and its Supabase data as live financial records. Never use real rows for destructive tests.
- Keep authorized users in the configured shared workspace. Enforce membership, role, optional domain rules, and CRUD authorization in PostgreSQL RLS; UI hiding alone is not security. Never hard-code a person, email, domain, workspace slug, or provider as a universal rule; read them from the current project's configuration and confirm assumptions when absent.
- Record the authenticated editor and timestamps for financial mutations when the schema supports it. Success responses must always contain a human-readable message; never render an absent value such as `undefined`.
- For every change: inspect the current working tree, make the smallest scoped edit, run syntax/static checks, test the actual browser UI with a temporary uniquely named record, delete only that temporary record, verify totals and data are unchanged, then push/deploy.
- After deployment, reload the real site in an authenticated browser and repeat the relevant create/read/update/delete and authorization checks. If any operation, console error, permission check, or cleanup verification fails, keep working and do not report completion.
- Preserve unrelated user files and uncommitted changes. Do not expose the internal deployment URL or credentials in output.
- Treat GitHub as the portable source of truth when work must continue on another computer: commit only scoped changes, push to the agreed branch, and on the next machine clone or pull that branch before editing. Keep secrets in the hosting/CI provider, never in the repository or sync folders.
- For recovery of a live record, identify the exact row using immutable ID plus audit/editor/timestamp evidence before changing it. If the original value cannot be proven, stop and ask the user rather than guessing.
