# Data Contracts (SCHEMAS.md)

This is the human reference for the data contracts in `contracts/`. Those JSON
Schemas are the API between pipeline stages and every record written to
`output/`, `locations/`, `sources/`, `organizations/`, or `leads/` is validated
against them.

Read `docs/ARCHITECTURE.md` for the design and `CLAUDE.md` for the directory map.
This document explains each field, the durable stores, and how the contracts are
enforced.

Two notes on terminology:

- `ARCHITECTURE.md` was written earlier and calls a geographic scope a *region*.
  The current contracts call it a *location* (`location_id`,
  `locations/registry.yaml`); read *region* as *location*.
- There are **two different "locations"** and they are deliberately separate.
  A **search area** (the `location` contract) is search *input*: where the agent
  looks, curated by a human. A lead's *geography* anchors on its
  **organization** (the `organization` contract), because school districts are
  independent, can span multiple counties, and a city can contain several
  districts. Do not conflate them.

## Conventions used by all contracts

- Schemas are JSON Schema draft 2020-12. Current versions: `lead` and `source`
  are **2.0**; `organization` is **1.0**; `location`, `location_state`, and
  `run_manifest` are **1.1** (their `schema_version` accepts any `1.x`).
- Objects are strict: `additionalProperties: false`. An unexpected or misspelled
  field is a validation error, not a silent extra. The two exceptions are noted
  where they occur (`location.scope` allows extra keys; `run_manifest.agent_versions`
  is an open string map).
- `location_id` is a stable slug matching `^us-[a-z]{2}-[a-z0-9-]+$`, for example
  `us-tx-austin-msa`. It is identical across inputs, state, and output paths.
- Timestamps are UTC. Record fields use ISO date-time; run-folder names use the
  compact form `YYYYMMDDTHHMMSSZ`, for example `20260701T184158Z`.

## The six contracts at a glance

| Contract | File | Produced by | Consumed by |
|---|---|---|---|
| Location (search area) | `contracts/location.schema.json` | Operator (`locations/registry.yaml`) | Source Finder, scheduler |
| LocationState | `contracts/location_state.schema.json` | Pipeline (`locations/state.json`) | `/status`, scheduler |
| Source | `contracts/source.schema.json` | Source Finder (`sources/registry.json` + run `sources.json`) | Lead Scraper |
| Organization | `contracts/organization.schema.json` | Both stages (`organizations/registry.json`) | Lead Scraper, Supabase |
| Lead | `contracts/lead.schema.json` | Lead Scraper (`leads/ledger.json` + run `leads.json`) | Supabase / Retool |
| RunManifest | `contracts/run_manifest.schema.json` | Both stages (`run_manifest.json`) | Operators, rollups |

## The durable stores (why re-runs are cheap)

Three tracked JSON files persist across runs so a re-run never starts from
scratch:

- **`sources/registry.json`** — every source ever discovered, deduplicated on
  `normalized_url`. Discovery consults this FIRST and re-checks known sources;
  web search only tops up gaps. Entries are updated, never deleted.
- **`organizations/registry.json`** — every public entity seen, with primary
  county always populated and many-to-many geography filled opportunistically.
- **`leads/ledger.json`** — every lead ever recorded, keyed by `external_id`.
  A scrape run skips ids already present, so money is not spent re-extracting
  known leads. Per-run `leads.json` files contain only what was NEW that run.

Each is a wrapper document `{ "schema_version": "<ver>", "description": "...",
<key>: [ ...records... ] }` whose records validate against the matching
contract. They are the local mirrors of the future Supabase tables.

---

## Lead (v2.0)

One artificial-turf lead, in **two tiers**: a flat core a BDM can read at a
glance (and which maps 1:1 onto a Supabase row), plus an optional nested
`evidence` block holding the richer extraction detail — demoted, not deleted.
Both pipelines (this repo and the meeting-minutes repo) emit the same core.

### Core fields (all required except `organization_id` and `evidence`)

| Field | Type | Meaning |
|---|---|---|
| `external_id` | `string`, minLength 8 | Stable content-derived id: hash of normalized `organization + "\|" + evidence.project_name + "\|" + source_url`. Recipe unchanged from v1, so ids are stable across the version bump. Dedup/upsert key everywhere. |
| `source` | enum `web-search` \| `meeting-minutes` | Which pipeline surfaced the lead. This repo always writes `web-search`. Kept on every lead so the trial can compare pipelines. |
| `organization` | `string` | Name of the entity the lead is about (district, city, county). |
| `organization_id` | `string` slug, optional | Key into `organizations/registry.json`, e.g. `leander-isd-tx`. |
| `state` | `string`, `^[A-Z]{2}$` | Two-letter state of the organization. |
| `county` | `string` | The organization's PRIMARY county. The full multi-county set lives on the organization record. `""` only when genuinely unresolved. |
| `summary` | `string`, ≤ 400 | One plain-language line: what the project is, which sports, where it stands. |
| `evidence_quote` | `string` | The single best verbatim quote from the source supporting the lead. `""` if the source is not quotable. |
| `source_url` | `string`, non-empty | One deep link to the page the lead was found on, so a BDM can open the source, validate the lead, and research further. |
| `discovered_at` | date-time | UTC timestamp the pipeline first recorded the lead. |
| `location_id` | slug | Which search area surfaced the lead (search input, not lead geography). |

### `evidence` (optional detail tier — never in the default BDM view)

| Field | Type | Meaning |
|---|---|---|
| `project_name` | `string`, ≤ 255 | Label: `[Site] - [compact scope]`, 3–8 words. Feeds the `external_id` hash. |
| `project_address` | `string` | Resolved site address, else `""`. |
| `projected_start_date` | `string` | ISO or free text, else `""`. |
| `details` | `string` | Full extracted narrative: scope, sports, funding, amounts, caveats. |
| `contact` | object | `first_name`, `last_name`, `title`, `phone`, `email` — only if stated on the source; else `""`. |
| `source_ids` | array of `SRC-NNN` | All sources the lead traces back to. |
| `source_urls` | array of `string` | All pages the lead was found on. |
| `matched_terms` | array of `string` | Keyword-filter terms that qualified the lead. |
| `confidence` | number 0–1 | Extraction confidence; below threshold routes to review. |
| `needs_review` | boolean | True if a core field is missing, sport unconfirmed, or confidence low. |
| `run_timestamp` | `string` | Run folder that produced the lead. |

Lifecycle/tracking fields (`status` New → Reviewing → Qualified → Contacted →
Opportunity, plus Rejected with a required reason; `assigned_bdm`; the status
change log) are **Supabase-only** — they are mutable UI state, not pipeline
output, so they live in the database and not in this file contract. See the
Supabase mapping below.

### What happened to the v1 Salesforce fields

v1's `Company`, `Project_Name__c`, `Lead_Details__c`, `Project_Address__c`,
`Projected_Start_Date__c` and the contact fields map to `organization`,
`evidence.project_name`, `evidence.details`, `evidence.project_address`,
`evidence.projected_start_date`, and `evidence.contact` respectively. A
Salesforce upsert is deferred until after the trial proves value; when it
happens it will read from Supabase, and the old field mapping can be recovered
from this file's git history.

---

## Source (v2.0)

One verified data source. Same shape in both homes: the durable registry
`sources/registry.json` and the per-run snapshot
`output/<location_id>/<run>/sources.json`.

Fields carried over from v1 (unchanged semantics): `id` (`SRC-NNN`, now assigned
registry-wide), `location_id`, `entity`, `entity_type`, `source_type`, `name`,
`url`, `contains`, `relevant_sports`, `lead_stage`, `searchability`,
`monitor_frequency`, `sport_confirmed`, `validation_status`, `validation_tier`,
`confidence`, `reviewed`, `last_validated`. Required: `id`, `location_id`,
`entity`, `entity_type`, `source_type`, `name`, `url`, `sport_confirmed`,
`validation_status`.

New registry fields (all optional in the schema, expected in the registry):

| Field | Type | Meaning |
|---|---|---|
| `normalized_url` | `string` | Dedup key: lowercase scheme+host, fragment/tracking params stripped, no trailing slash. Same `normalized_url` = same source. |
| `location_ids` | array of slug | All search areas the source covers (aggregators/state portals serve several). |
| `first_seen` | date-time | When the source first entered the registry. |
| `last_checked` | date-time | Most recent re-check (validation or scrape), whatever the outcome. |
| `last_result` | `string` | Short note on that check, e.g. `verified; 3 leads in run 20260701T184158Z` or `broken: 404`. |

---

## Organization (v1.0)

A public entity a lead can be about. Leads anchor here — not on a county or
city — because districts span counties and cities contain multiple districts.
Durable store: `organizations/registry.json`.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `organization_id` | slug `^[a-z0-9-]+$` | Yes | Stable key, e.g. `leander-isd-tx`. Referenced by `lead.organization_id`. |
| `name` | `string` | Yes | Official name. |
| `type` | enum | Yes | `school_district`, `city`, `county`, `university`, `college`, `state_agency`, `other`. |
| `website` | uri | No | Official homepage. |
| `state` | `^[A-Z]{2}$` | Yes | Two-letter state. |
| `primary_county` | `string` | Yes | The one primary county. Always populated. |
| `geography` | array of `{kind, value}` | No | Many-to-many coverage: `kind` is `county` or `place`, `value` is its name. Filled opportunistically; the *structure* is the point. |
| `location_ids` | array of slug | No | Search areas whose scope overlaps this org. |
| `first_seen` | date-time | No | When the org entered the registry. |
| `notes` | `string` | No | Free text. |

---

## Location — the search area (v1.1)

Search *input*: a geographic scope the Source Finder processes, one YAML entry
per area in `locations/registry.yaml`. Maps to the Supabase `search_area` table.
Unchanged v1 fields: `schema_version`, `location_id`, `name`, `type`
(city/county/metro/district/state), `scope` (counties/state/parent; extra keys
allowed), `priority`, `cadence`, `tags`, `added_date`. New in 1.1:
`coverage_target` (number 0–1, optional) — per-area override of the discovery
coverage target.

## LocationState (v1.1)

Dynamic processing state per location in `locations/state.json` (the work
queue). Unchanged v1 fields: `schema_version`, `location_id`, `status` (state
machine: `pending` … `ready_for_scrape`, `scraped`, `stale`, `blocked`,
`failed`), `last_run`, `next_due`, `coverage`, `quality_score`, `counts`,
`latest_run`, `lease`, `notes`. New in 1.1 (all nullable):

| Field | Meaning |
|---|---|
| `last_discovered` | UTC time of the last completed discovery run — answers "when did we last look for sources here" without opening output files. |
| `last_scraped` | UTC time of the last completed scrape run. |
| `latest_discovery_run` | Run folder of the last discovery run. |
| `latest_scrape_run` | Run folder of the last scrape run. |

## RunManifest (v1.1)

Per-run metadata written alongside `sources.json` / `leads.json` in each output
run folder; together with the state fields above it forms the run log. Unchanged
v1 fields: `schema_version`, `location_id`, `run_timestamp`, `stage`
(`discovery`/`scrape`), `agent_versions`, `coverage`, `run_quality`, `budget`,
`failed_sources`, `gaps`. New `counts` keys in 1.1 (all optional integers):

| Field | Meaning |
|---|---|
| `counts.sources_new` | Sources added to the durable registry this run (web-discovery top-up). |
| `counts.sources_known_rechecked` | Registry sources re-checked instead of re-discovered. |
| `counts.leads_new` | Leads whose `external_id` was not yet in the ledger. |
| `counts.leads_duplicate` | Leads skipped because the ledger already had them. |

---

## Supabase mapping

Both pipelines write into shared Postgres tables in Supabase; Retool sits on
top as the BDM UI (filterable lead table + detail view + status buttons). The
file contracts here mirror those tables:

| Repo artifact | Supabase table | Notes |
|---|---|---|
| Core lead (ledger / run `leads.json`) | `lead` | One row per core lead; upsert on `external_id`. `source` distinguishes the two pipelines for the trial measurement. |
| `evidence` block | `lead_evidence` (or a JSONB column on `lead`) | Detail on demand, never in the default view. |
| — (Supabase-only) | `lead_status_log` + `status`, `rejected_reason`, `assigned_bdm` on `lead` | Lifecycle: New → Reviewing → Qualified → Contacted → Opportunity; Rejected requires a reason. The log records who changed status and when — this is what makes the 3-month trial quantifiable per source pipeline. |
| `organizations/registry.json` | `organization` | Primary state/county on the row. |
| `organization.geography[]` | `organization_geography` | Join rows org ↔ county and org ↔ place. |
| `locations/registry.yaml` | `search_area` | `location_id`, name, state, type, status, coverage_target. |
| `sources/registry.json` | `source` | Deduplicated on `normalized_url`. |
| `run_manifest.json` + state fields | `run` / `location_state` | The run log: what ran, when, and what it found. |

Salesforce is deliberately out of scope for the trial; it comes after proof of
value and will be fed from Supabase, keyed on the same `external_id`.

### Implementation

- **`sql/schema.sql`** is the DDL for the tables above. Run it once against the
  Supabase project (SQL editor or `psql`); it is safe to re-run. Enums are
  `text` + `CHECK` (so adding a value is a one-line change), the lead `evidence`
  block is one JSONB column, and the lead lifecycle columns are Supabase-only.
- **`sync/push_to_supabase.py`** reads the durable stores + run manifests and
  upserts them into these tables, keyed on the same dedup keys used locally.
  It is idempotent and never writes the lifecycle columns, so a BDM's edits in
  Retool survive every re-sync. See the RUNBOOK's "Push to Supabase" section and
  `sync/README.md`.

### Staging layer (planned, not yet built)

Comparing a run against existing data before promoting it is deferred. The
intended shape: land each run's leads in a `staging_lead` table (same columns as
`lead`, no lifecycle fields), then diff against `lead` on `external_id` — new
ids insert, existing ids refresh only pipeline-owned fields, and ids absent from
the run are left untouched. Because both pipelines share `lead` and carry a
`source` field, the same diff also yields the web-search vs meeting-minutes
trial comparison as a query. Until then, `sync/push_to_supabase.py` upserts
straight into the live tables, which is safe because upserts are idempotent and
lifecycle fields are preserved.

---

## Enforcement

Contracts are enforced in three layers so that non-conforming data cannot move
between stages unnoticed.

**1. The PostToolUse hook (`.claude/hooks/validate_schema.py`).** After a file is
written, the hook selects the matching contract for the file (by path), validates
the content, and blocks a write that does not conform. Routed files:

| File | Contract | Wrapper version |
|---|---|---|
| `output/**/sources.json` | source | `2.0` (+ `location_id` required) |
| `output/**/leads.json` | lead | `2.0` (+ `location_id` required) |
| `output/**/run_manifest.json` | run_manifest | — (whole object) |
| `sources/registry.json` | source | `2.0` |
| `organizations/registry.json` | organization | `1.0` |
| `leads/ledger.json` | lead | `2.0` |
| `locations/registry.yaml` | location | — (each record) |
| `locations/state.json` | location_state | — (each record) |

Wrapper documents are validated element by element. The hook degrades
gracefully: if `jsonschema` or `pyyaml` cannot be imported, it logs a warning
and skips validation rather than blocking work. It can also be run manually:
`python3 .claude/hooks/validate_schema.py <file> [...]`.

**2. Boundary validation in each stage.** Each stage validates its input before
consuming it and its output before writing it, whether or not the hook fired.

**3. A CI check.** Continuous integration validates the tracked example run,
registries, and contracts against the schemas, catching drift in review.

**Versioning field.** `location`, `location_state`, and `run_manifest` records
carry an inline `schema_version` (pattern `^1\.[0-9]+$`). `source`, `lead`, and
`organization` records carry none — they are versioned by their wrapper
document's `schema_version` and their pinned contract file. Either way the rule
is the same: never change a schema without bumping its version and updating this
document.

## Versioning & compatibility

- **Additive, backward-compatible changes are minor.** Adding an optional field,
  or adding a value to an enum, does not break existing records (this is why
  `source` gaining registry fields and the 1.1 bumps are safe).
- **Removing or renaming a field, making an optional field required, or tightening
  a type or pattern is breaking.** A breaking change requires a new major
  `schema_version` (this is why `lead` went to 2.0).
- **When you bump a version:** update the schema, the wrapper versions expected
  by the validation hook, the field tables in this document, and coordinate the
  consumers — the per-stage boundary checks, the CI check, and the Supabase
  mapping. The contracts are the API between stages; an un-coordinated change
  breaks the stage on the other side.
