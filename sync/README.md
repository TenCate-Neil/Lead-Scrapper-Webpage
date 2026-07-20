# Supabase sync

Pushes the pipeline's durable stores into the shared Supabase tables the Retool
BDM UI reads. This is the only component that talks to Supabase; the pipeline
stages themselves stay file-based and decoupled.

- `../sql/schema.sql` — the table definitions (run once per project).
- `push_to_supabase.py` — reads the durable stores + run manifests and upserts them.
- `.env.example` — copy to `.env` and fill in your Supabase URL + service_role key.

## Environments

Each environment is a **separate Supabase project** with its own URL and keys.
Two are supported: `staging` (the default) and `production` (the data the Retool
BDM UI reads). The target is chosen with `--env` (or the `SUPABASE_ENV` variable)
and defaults to `staging`, so the safe target is the one you get by forgetting to
set it. Credentials load from `sync/.env.<env>`.

"Promoting" a run is **not** a database-to-database copy. The local durable
stores are the source of truth, so you push to staging first, verify, then re-run
the same idempotent sync against production. Production writes are gated behind
`--confirm-production` so they can never happen by accident.

## One-time setup

1. Create the tables in **each** Supabase project: open its SQL editor, paste
   `../sql/schema.sql`, run it. (Re-running is safe — every statement is
   `create ... if not exists`.)
2. Fill in credentials per environment (Supabase dashboard → Project Settings → API):

   ```bash
   cp .env.staging.example    .env.staging     # then edit
   cp .env.production.example .env.production  # then edit
   ```

   `sync/.env*` are gitignored (only the `*.example` files are tracked). A legacy
   single-project `sync/.env` is still read as a fallback for any key an
   environment file does not set.

## Run

```bash
# From the repo root. Dry run first — transforms and prints, no network:
python3 sync/push_to_supabase.py --dry-run

# Push to staging (the default):
python3 sync/push_to_supabase.py

# Push a subset (still applied in dependency order):
python3 sync/push_to_supabase.py --tables lead,source

# Promote to production once staging looks right (both flags required):
python3 sync/push_to_supabase.py --env production --confirm-production
```

`--dry-run` needs no credentials, so it is a safe way to check the transforms.
Reading `search_area` requires `pyyaml` (already a pipeline prerequisite).

## What it guarantees

- **Idempotent.** Every table upserts on its stable key (`external_id`, `id`,
  `organization_id`, `location_id`, …), so re-running only refreshes rows.
- **Lifecycle-safe.** The sync never sends the Supabase-only lead columns
  (`status`, `rejected_reason`, `assigned_bdm`). A BDM's edits in Retool survive
  every re-sync — an upsert only touches the columns in the payload.
- **Decoupled.** It reads the durable stores after a run; it does not call
  `/discover` or `/scrape`. Run it manually, or wire it in as a post-run step.

## Not yet built: the staging layer

The comparison-before-promote flow (`staging_lead` + a diff against `lead`) is
described in `docs/SCHEMAS.md` and is intentionally deferred. This sync upserts
straight into the live tables for now, which is safe because upserts are
idempotent and lifecycle fields are preserved.
