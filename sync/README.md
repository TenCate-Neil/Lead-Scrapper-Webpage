# Supabase sync

Pushes the pipeline's durable stores into the **staging** Supabase project.
This is the only pipeline component that talks to Supabase; the pipeline stages
themselves stay file-based and decoupled.

- `../sql/staging_schema.sql` — the staging tables (run once in the staging project).
- `../sql/production_schema.sql` — the production tables (run once in the production project).
- `push_to_supabase.py` — reads the durable stores + run manifests and upserts them into staging.
- `.env.staging.example` / `.env.production.example` — copy to `.env.<env>` and fill in each project's URL + service_role key.

## The two databases

Each is a **separate Supabase project** with a different role and a different
schema (see the headers in `../sql/`):

- **Staging** — landing zone + triage + entity resolution. Both scrape pipelines
  write here: each scrape mention lands as a `lead_entry` row
  (`entry_id` = the pipeline's `external_id`). A BDM triages entries
  (`review_status`); the resolution step links them to a thin `lead` row keyed
  by `dedup_key` (hash of `organization_id` + normalized project descriptor —
  no URL, assigned by resolution, never the scraper).
- **Production** — system of record for sales work (`lifecycle_status`,
  `assigned_bdm`, status log). **This sync never writes it.** The only pipeline
  writer is the promotion job (not yet built), which moves accepted+resolved
  entries out of staging keyed on `dedup_key` / `source_entry_id`.

## One-time setup

1. Create the tables: staging project → SQL editor → run
   `../sql/staging_schema.sql`; production project → run
   `../sql/production_schema.sql`. (Re-running is safe — `if not exists`.)
2. Fill in staging credentials (Supabase dashboard → Project Settings → API):

   ```bash
   cp .env.staging.example .env.staging     # then edit
   ```

   `sync/.env*` are gitignored (only the `*.example` files are tracked). A
   legacy single-project `sync/.env` is still read as a fallback.
   `.env.production` is for the future promotion job only.

## Run

```bash
# From the repo root. Dry run first — transforms and prints, no network:
python3 sync/push_to_supabase.py --dry-run

# Push to staging:
python3 sync/push_to_supabase.py

# Push a subset (still applied in dependency order):
python3 sync/push_to_supabase.py --tables lead_entry,source
```

`--dry-run` needs no credentials, so it is a safe way to check the transforms.
Reading `search_area` requires `pyyaml` (already a pipeline prerequisite).

## What it guarantees

- **Idempotent.** Every table upserts on its stable key (`entry_id`, `id`,
  `organization_id`, `location_id`, …), so re-running only refreshes rows.
- **Triage-safe.** The sync never sends `lead_entry`'s triage/resolution
  columns (`review_status`, `rejected_reason`, `reviewed_by`, `lead_id`,
  `observation_type`, `match_confidence`) — an upsert only touches the columns
  in the payload, so BDM triage decisions and resolution linkage survive every
  re-sync. It also never writes the staging `lead` table (resolution owns it)
  or anything in production.
- **Decoupled.** It reads the durable stores after a run; it does not call
  `/discover` or `/scrape`. Run it manually, or wire it in as a post-run step.

## Not yet built: the promotion job

A GitHub Actions cron with the production service key that inserts
accepted+resolved staging entries into production `lead` (upsert on
`dedup_key`, refreshing only ingestion fields — never `lifecycle_status`,
`rejected_reason`, or `assigned_bdm`) and appends `lead_observation` rows
(upsert on `source_entry_id`). The contract is spelled out in
`../sql/production_schema.sql`.
