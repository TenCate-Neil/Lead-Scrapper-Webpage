# Turf Lead Pipeline

A location-driven pipeline that discovers public procurement/planning data
sources for artificial-turf field opportunities (football, soccer,
baseball/softball) across US regions, then extracts sales leads from them.
Leads land in shared Postgres tables on Supabase (with a Retool UI for the
Sales BDMs); this is one of two pipelines feeding that store — the other is the
separate meeting-minutes repo — and every lead carries a `source` field so the
two can be compared.

## Pipeline stages

```
locations/registry.yaml          # 1. what to cover (search areas; add one = one entry)
        │
        ▼
Source Finder (skill: source-discovery)   # 2. registry-first: re-check known sources,
        │                                 #    then discover → validate → review to top up
        │  upserts sources/registry.json + organizations/registry.json
        │  writes  output/<location_id>/<run>/sources.json   (contract: contracts/source.schema.json)
        ▼
Lead Scraper (skill: lead-extraction)     # 3. ledger-first: extract only NEW leads
        │  appends leads/ledger.json
        │  writes  output/<location_id>/<run>/leads.json     (contract: contracts/lead.schema.json)
        ▼
Supabase upsert (external_id keyed) → Retool UI for BDMs
```

Stages are decoupled through shared storage + the location state machine in
`locations/state.json` — no stage calls another directly.

## Directory map

- `contracts/` — JSON Schemas. The API between stages. **All agent output is validated against these.** Do not change a schema without bumping `schema_version` and updating `docs/SCHEMAS.md`.
- `config/keyword_filters.yaml` — the ONLY home for turf/sport/procurement/exclusion keywords. Reference it; never copy it into a prompt.
- `locations/registry.yaml` — the central search-area list (input, versioned).
- `locations/state.json` — per-location processing state (the work queue), incl. `last_discovered` / `last_scraped`.
- `sources/registry.json` — **durable source registry**: every source ever found, deduped on `normalized_url`. Consult before any new web discovery; never rebuild from scratch.
- `organizations/registry.json` — **durable organization registry**: entities leads anchor on, with primary county + many-to-many county/place geography.
- `leads/ledger.json` — **durable lead ledger** keyed by `external_id`: every lead ever recorded. Scrapes skip known ids so nothing is extracted twice.
- `.claude/agents/` — sub-agents, in two tiers:
  - **Coordinators** (run one location's full loop in their own context, then return a compact summary so the main session never accumulates it): `discovery-coordinator` (drives scope→discover→validate→review, upserts the registries + state) and `scrape-coordinator` (fans out workers, consolidates + dedups leads by `external_id`, appends the ledger + state).
  - **Workers** (each does one narrow job, invoked by a coordinator): `scout` (discovers candidate sources for one entity), `validator` (checks one candidate URL's reachability + content), `reviewer` (scores a validated source against the quality rubric — must not be the agent that found it), `scraper-worker` (extracts new leads from one verified source).
- `.claude/skills/` — procedures: `source-discovery`, `lead-extraction`.
- `.claude/commands/` — entry points: `/discover`, `/scrape`, `/status`.
- `.claude/hooks/` — schema-validation hook run on file writes.
- `output/` — generated run artifacts. **Never commit** (gitignored) except the one tracked example run.
- `sql/` — `schema.sql`, the Supabase (Postgres) DDL for the tables the durable stores mirror. Run once per project.
- `sync/` — `push_to_supabase.py` upserts the durable stores into Supabase (idempotent; never writes BDM lifecycle fields). Environment-aware: `--env staging|production` (default `staging`) selects a separate Supabase project, reading credentials from `sync/.env.<env>`; production writes require `--confirm-production`. `.env*` are gitignored (only `*.example` tracked); see `sync/README.md`.
- `docs/` — `ARCHITECTURE.md` (design), `SCHEMAS.md` (fields + Supabase mapping), `RUNBOOK.md` (operations).

## How to run

- Discover sources for a location: `/discover <location_id>` (e.g. `us-tx-austin-msa`).
- Extract leads for a discovered location: `/scrape <location_id>`.
- Check pipeline state across all locations: `/status`.

## Conventions

- **`location_id`** is a stable slug `us-<state>-<area>` (e.g. `us-tx-austin-msa`), used identically in inputs, state, and output paths. It is search INPUT; a lead's geography anchors on its organization (see `contracts/organization.schema.json`).
- **Output path**: `output/<location_id>/<run-timestamp>/` where the timestamp is UTC `YYYYMMDDTHHMMSSZ`. Never overwrite a prior run. Run files are snapshots; the registries/ledger are the durable stores.
- **Leads are two-tier**: a flat core the BDMs read (organization, state/county, summary, evidence_quote, source_url, discovered_at) plus an optional nested `evidence` block with the extraction detail. Every lead carries a stable `external_id` (idempotent upsert key) and `source: "web-search"`.
- **Every wrapper document carries a top-level `schema_version`** (`lead`/`source` wrappers are `2.0`; `location`, `location_state`, `run_manifest` records carry `1.x` inline).
- **Definition of done for a location**: coverage ≥ target AND run quality ≥ threshold, or the discovery budget is exhausted — then state flips to `ready_for_scrape`. See `docs/ARCHITECTURE.md`.

## Ground rules

- Do not fabricate sources, contacts, dates, or solicitation numbers. Missing data stays empty. Resolving a named facility's real address is retrieval, not fabrication.
- Only football, soccer, and baseball/softball turf. Exclude other sports unless the source also covers a target sport.
- Only official public sources; deep-link, don't link to homepages. Every lead's `source_url` must let a BDM open the source and validate the lead.
- Consult the durable stores first: re-check known sources instead of re-searching the web; skip leads already in the ledger instead of re-extracting them.
- Validate against the contracts before writing; the hook will reject non-conforming output.
