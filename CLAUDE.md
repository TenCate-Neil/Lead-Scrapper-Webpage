# Turf Lead Pipeline

A location-driven pipeline that discovers public procurement/planning data
sources for artificial-turf field opportunities (football, soccer,
baseball/softball) across US regions, then extracts sales leads from them for
Salesforce.

## Pipeline stages

```
locations/registry.yaml          # 1. what to cover (add a location = one entry)
        │
        ▼
Source Finder (skill: source-discovery)   # 2. discover → validate → review, in a loop
        │  writes output/<location_id>/<run>/sources.json  (contract: contracts/source.schema.json)
        ▼
Lead Scraper (skill: lead-extraction)     # 3. read sources, extract leads
        │  writes output/<location_id>/<run>/leads.json    (contract: contracts/lead.schema.json)
        ▼
Salesforce upsert (external_id keyed)
```

Stages are decoupled through shared storage + the location state machine in
`locations/state.json` — no stage calls another directly.

## Directory map

- `contracts/` — JSON Schemas. The API between stages. **All agent output is validated against these.** Do not change a schema without bumping `schema_version` and updating `docs/SCHEMAS.md`.
- `config/keyword_filters.yaml` — the ONLY home for turf/sport/procurement/exclusion keywords. Reference it; never copy it into a prompt.
- `locations/registry.yaml` — the central location list (input, versioned).
- `locations/state.json` — per-location processing state (the work queue).
- `.claude/agents/` — sub-agents: `scout`, `validator`, `reviewer`, `scraper-worker`.
- `.claude/skills/` — procedures: `source-discovery`, `lead-extraction`.
- `.claude/commands/` — entry points: `/discover`, `/scrape`, `/status`.
- `.claude/hooks/` — schema-validation hook run on file writes.
- `output/` — generated run artifacts. **Never commit** (gitignored) except the one tracked example run.
- `docs/` — `ARCHITECTURE.md` (design), `SCHEMAS.md` (fields + Salesforce mapping), `RUNBOOK.md` (operations).

## How to run

- Discover sources for a location: `/discover <location_id>` (e.g. `us-tx-austin-msa`).
- Extract leads for a discovered location: `/scrape <location_id>`.
- Check pipeline state across all locations: `/status`.

## Conventions

- **`location_id`** is a stable slug `us-<state>-<area>` (e.g. `us-tx-austin-msa`), used identically in inputs, state, and output paths.
- **Output path**: `output/<location_id>/<run-timestamp>/` where the timestamp is UTC `YYYYMMDDTHHMMSSZ`. Never overwrite a prior run.
- **Every record carries `schema_version`.** Every lead carries a stable `external_id` for idempotent Salesforce upserts.
- **Definition of done for a location**: coverage ≥ target AND run quality ≥ threshold, or the discovery budget is exhausted — then state flips to `ready_for_scrape`. See `docs/ARCHITECTURE.md`.

## Ground rules

- Do not fabricate sources, contacts, dates, or solicitation numbers. Missing data stays empty. Resolving a named facility's real address is retrieval, not fabrication.
- Only football, soccer, and baseball/softball turf. Exclude other sports unless the source also covers a target sport.
- Only official public sources; deep-link, don't link to homepages.
- Validate against the contracts before writing; the hook will reject non-conforming output.
