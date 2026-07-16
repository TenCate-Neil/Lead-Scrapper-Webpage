# Supabase sync

Pushes the pipeline's durable stores into the shared Supabase tables the Retool
BDM UI reads. This is the only component that talks to Supabase; the pipeline
stages themselves stay file-based and decoupled.

- `../sql/schema.sql` — the table definitions (run once per project).
- `push_to_supabase.py` — reads the durable stores + run manifests and upserts them.
- `.env.example` — the two variables the script needs; copy to `.env` only for a
  local machine that has no other way to set them.

## Credentials

The script reads two variables **from the environment**:

```
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-role key>   # secret; bypasses RLS
```

Get both from the Supabase dashboard → Project Settings → API. Provide them
wherever the sync runs — never commit the service-role key:

- **Claude Code (web/session):** set them as environment variables on the
  environment (Settings → environment variables). This is how the session picks
  them up; no file is involved.
- **CI:** stored as repo secrets and passed as `env:` in
  `../.github/workflows/sync-supabase.yml`.
- **A local dev machine:** either `export` them in your shell, or
  `cp .env.example .env` and fill it in. `sync/.env` is gitignored and read only
  as a fallback — any variable already set in the environment wins over it.

## One-time setup

1. Create the tables: open Supabase → SQL editor, paste `../sql/schema.sql`, run it.
   (Re-running is safe — every statement is `create ... if not exists`.)
2. Make the two credentials above available in the environment (see **Credentials**).

## Run

```bash
# From the repo root. Dry run first — transforms and prints, no network:
python3 sync/push_to_supabase.py --dry-run

# Push everything:
python3 sync/push_to_supabase.py

# Push a subset (still applied in dependency order):
python3 sync/push_to_supabase.py --tables lead,source
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
