---
name: shop-accounting-production
description: Maintain this live accounting web app with shared-workspace security, cautious CRUD changes, and mandatory real-site verification before delivery.
---

# Production workflow

- Treat the deployed accounting app and its Supabase data as live financial records. Never use real rows for destructive tests.
- Keep all authorized internal users in one Supabase workspace. Enforce membership, role, domain rules, and CRUD authorization in PostgreSQL RLS; UI hiding alone is not security.
- Record the authenticated editor and timestamps for financial mutations when the schema supports it. Success responses must always contain a human-readable message; never render an absent value such as `undefined`.
- For every change: inspect the current working tree, make the smallest scoped edit, run syntax/static checks, test the actual browser UI with a temporary uniquely named record, delete only that temporary record, verify totals and data are unchanged, then push/deploy.
- After deployment, reload the real site in an authenticated browser and repeat the relevant create/read/update/delete and authorization checks. If any operation, console error, permission check, or cleanup verification fails, keep working and do not report completion.
- Preserve unrelated user files and uncommitted changes. Do not expose the internal deployment URL or credentials in output.
