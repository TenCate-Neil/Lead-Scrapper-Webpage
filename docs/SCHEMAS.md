# Data Contracts (SCHEMAS.md)

This is the human reference for the data contracts in `contracts/`. Those JSON
Schemas are the API between pipeline stages: the Source Finder and the Lead
Scraper agree on shape through them, and every record written to `output/` or
`locations/` is validated against them.

Read `docs/ARCHITECTURE.md` for the design and `CLAUDE.md` for the directory map.
This document explains each field and how the contracts are enforced.

A note on terminology: `ARCHITECTURE.md` was written earlier and calls a
geographic scope a *region*. The current contracts and `CLAUDE.md` call the same
thing a *location* (`location_id`, `locations/registry.yaml`). This document uses
*location* throughout; when you read *region* in `ARCHITECTURE.md`, read it as
*location*.

## Conventions used by all contracts

- Schemas are JSON Schema draft 2020-12, currently at contract version `1.0`.
- Objects are strict: `additionalProperties: false`. An unexpected or misspelled
  field is a validation error, not a silent extra. The two exceptions are noted
  where they occur (`location.scope` allows extra keys; `run_manifest.agent_versions`
  is an open string map).
- `location_id` is a stable slug matching `^us-[a-z]{2}-[a-z0-9-]+$`, for example
  `us-tx-austin-msa`. It is identical across inputs, state, and output paths.
- Timestamps are UTC. Record fields use ISO date-time; run-folder names use the
  compact form `YYYYMMDDTHHMMSSZ`, for example `20260701T184158Z`.

## The five contracts at a glance

| Contract | File | Produced by | Consumed by |
|---|---|---|---|
| Location | `contracts/location.schema.json` | Operator (`locations/registry.yaml`) | Source Finder, scheduler |
| LocationState | `contracts/location_state.schema.json` | Pipeline (`locations/state.json`) | `/status`, scheduler |
| Source | `contracts/source.schema.json` | Source Finder (`sources.json`) | Lead Scraper |
| Lead | `contracts/lead.schema.json` | Lead Scraper (`leads.json`) | Salesforce upsert |
| RunManifest | `contracts/run_manifest.schema.json` | Both stages (`run_manifest.json`) | Operators, rollups |

---

## Location

A geographic scope the Source Finder processes. This is static input, versioned
in `locations/registry.yaml`. One entry per location.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | `string`, const `"1.0"` | Yes | Contract version. Bump on breaking changes. |
| `location_id` | `string`, pattern `^us-[a-z]{2}-[a-z0-9-]+$` | Yes | Stable slug used across inputs, state, and outputs. Example: `us-tx-austin-msa`. |
| `name` | `string` | Yes | Human-readable name. Example: `Austin Metro (5-county MSA)`. |
| `type` | `string` enum | Yes | Kind of geography. One of: `city`, `county`, `metro`, `district`, `state`. |
| `scope` | `object` | No | Optional structured detail that bounds the location. Extra keys allowed. Recognized keys: `counties` (array of strings), `state` (string), `parent` (string). |
| `priority` | `string` enum | Yes | Drives ordering of the work queue. One of: `high`, `medium`, `low`. |
| `cadence` | `string` enum | Yes | How often the location is re-discovered. Sets `next_due` in the state store. One of: `weekly`, `monthly`, `quarterly`. |
| `tags` | `array` of `string` | No | Free-form labels for filtering, e.g. `texas`, `tier-1`. |
| `added_date` | `string`, format `date` | Yes | ISO date the location was added to the registry. |

---

## LocationState

Dynamic processing state for one location, updated every run. Stored in
`locations/state.json` (JSON at small scale; the schema notes a migration to
SQLite for a national rollout). This is the work queue.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | `string`, const `"1.0"` | Yes | Contract version. |
| `location_id` | `string`, pattern `^us-[a-z]{2}-[a-z0-9-]+$` | Yes | Foreign key to a location in the registry. |
| `status` | `string` enum | Yes | Position in the pipeline state machine. One of: `pending`, `scoping`, `discovering`, `validating`, `review`, `ready_for_scrape`, `scraped`, `stale`, `blocked`, `failed`. See `ARCHITECTURE.md` for transitions. |
| `last_run` | `string` (date-time) or `null` | No | UTC timestamp of the most recent discovery run. |
| `next_due` | `string` (date-time) or `null` | No | When this location should next be processed (derived from `cadence`). |
| `coverage` | `number` 0–1 or `null` | No | Fraction of enumerated entities with at least one confident source. |
| `quality_score` | `number` 0–1 or `null` | No | Aggregate confidence across verified sources for the latest run. |
| `counts` | `object` | No | Rollup counts. Keys (all integers, ≥ 0): `entities`, `sources_verified`, `leads`. |
| `latest_run` | `string` or `null` | No | Run-timestamp folder name of the current run, e.g. `20260701T184158Z`. Points into `output/<location_id>/`. |
| `lease` | `object` or `null` | No | Concurrency lock so two runs cannot grab the same location at once. Keys: `owner` (string), `acquired_at` (date-time), `expires_at` (date-time). |
| `notes` | `string` | No | Free text, e.g. why the location is blocked. |

---

## Source

One verified data source produced by the Source Finder. The array of these is the
`sources.json` contract consumed by the Lead Scraper. Note: this record has no
inline `schema_version` field (see Enforcement).

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | `string`, pattern `^SRC-[0-9]{3,}$` | Yes | Sequential id within a location run: `SRC-001`, `SRC-002`, … |
| `location_id` | `string`, pattern `^us-[a-z]{2}-[a-z0-9-]+$` | Yes | Which location this source belongs to. |
| `entity` | `string` | Yes | Public entity name, e.g. `Round Rock ISD`, `City of Austin`. |
| `entity_type` | `string` enum | Yes | One of: `school_district`, `city`, `county`, `state`, `cooperative`, `aggregator`. |
| `source_type` | `string` enum | Yes | One of: `procurement`, `bond_program`, `cip`, `budget`, `parks_plan`, `athletic_facility_plan`, `construction_updates`. |
| `name` | `string` | Yes | Short descriptive name, e.g. `Purchasing / Bids (Bonfire)`. |
| `url` | `string`, format `uri` | Yes | The verified deep-linked URL. |
| `contains` | `string` | No | What the page actually contains, written from observation. |
| `relevant_sports` | `array` of enum | No | Values: `football`, `soccer`, `baseball_softball`, `multipurpose`, `needs_validation`. |
| `lead_stage` | `array` of enum | No | Values: `early_planning`, `funding`, `active_bid`, `awarded`, `historical_reference`. |
| `searchability` | `string` enum | No | How easily the page can be searched vs. PDF-only. One of: `good`, `medium`, `poor`. |
| `monitor_frequency` | `string` enum | No | How often to re-check this source. One of: `weekly`, `monthly`, `quarterly`. |
| `sport_confirmed` | `boolean` | Yes | True only if a target sport (football, soccer, baseball/softball) is explicitly named. |
| `validation_status` | `string` enum | Yes | Result of the Phase 3 validation loop. Only `verified` sources are passed downstream. One of: `verified`, `needs_redirect`, `broken`, `retry`, `not_found`. |
| `validation_tier` | `array` of enum | No | Cumulative validation tiers the source cleared. Values: `live`, `relevant`, `fresh`, `sport_confirmed`. |
| `confidence` | `number` 0–1 | No | Reviewer sub-agent confidence score from the quality rubric. |
| `reviewed` | `boolean` | No | True once an independent reviewer sub-agent has scored it. |
| `last_validated` | `string` (date-time) | No | UTC timestamp of the last successful validation. |

---

## Lead

One artificial-turf lead produced by the Lead Scraper. The array of these is the
`leads.json` contract. Field names ending in `__c` mirror Salesforce custom field
API names, and the standard-named fields mirror standard Salesforce Lead fields,
so a record maps cleanly to a Salesforce Lead. Note: this record has no inline
`schema_version` field (see Enforcement).

| Field | Type | Required | Meaning |
|---|---|---|---|
| `external_id` | `string`, minLength 8 | Yes | Stable, content-derived id (hash of `Company` + `Project_Name__c` + primary source URL). Maps to a Salesforce External Id field so upserts are idempotent across runs. |
| `location_id` | `string`, pattern `^us-[a-z]{2}-[a-z0-9-]+$` | Yes | Which location this lead was discovered under. |
| `FirstName` | `string` | No | Point-of-contact first name. Empty string if unknown. |
| `LastName` | `string` | No | Point-of-contact last name. Empty string if unknown. |
| `Lead_Details__c` | `string` | Yes | Project summary: scope, sports, square footage, products needed. |
| `Project_Address__c` | `string` | No | Project site address. Empty string if unresolved. |
| `Phone` | `string` | No | Contact phone. Empty string if unknown. |
| `Projected_Start_Date__c` | `string` | No | Expected start date (free text or ISO). Empty string if unknown. |
| `Title` | `string` | No | Contact job title. Empty string if unknown. |
| `Company` | `string` | Yes | Entity name (school district, city, county). |
| `Email` | `string` | No | Contact email. Empty string if unknown. |
| `Project_Name__c` | `string`, maxLength 255 | Yes | Label: `[Site or facility name] - [compact scope]`. 3–8 words. Not a sentence. |
| `source_ids` | `array` of `string` (pattern `^SRC-[0-9]{3,}$`), minItems 1 | Yes | Source ids this lead traces back to. Pipeline metadata; not synced to Salesforce as-is. |
| `source_urls` | `array` of `string` | No | Exact page URL(s) the lead was found on. Pipeline metadata. |
| `confidence` | `number` 0–1 | No | Extraction/validation confidence. Below the review threshold routes to human review before Salesforce. |
| `needs_review` | `boolean` | No | True if any required field is missing, sport is unconfirmed, or confidence is below threshold. |

### Salesforce mapping

The Lead contract is shaped for a Salesforce Lead upsert. The mapping below shows
where each field goes.

- **Direct-mapping fields** carry Salesforce API names and map one-to-one:
  the `__c` fields are Salesforce custom fields; `FirstName`, `LastName`, `Phone`,
  `Email`, `Title`, and `Company` are standard Salesforce Lead fields.
- **The upsert key** is `external_id`, mapped to a Salesforce External Id field.
  Because the id is content-derived, the same project found again produces the
  same id, so the upsert updates the existing record instead of creating a
  duplicate.
- **Pipeline-only metadata** is provenance and gating data. It is not a native
  Lead field. Route it to an admin/custom field if you want it visible in
  Salesforce, or leave it unsynced.

| Lead field | Salesforce Lead field | Kind | Sync |
|---|---|---|---|
| `external_id` | External Id custom field (upsert key) | Custom (External Id) | Yes — idempotent upsert key |
| `Company` | `Company` | Standard (required) | Yes |
| `FirstName` | `FirstName` | Standard | Yes |
| `LastName` | `LastName` | Standard (required) | Yes |
| `Phone` | `Phone` | Standard | Yes |
| `Email` | `Email` | Standard | Yes |
| `Title` | `Title` | Standard | Yes |
| `Lead_Details__c` | `Lead_Details__c` | Custom | Yes |
| `Project_Name__c` | `Project_Name__c` | Custom | Yes |
| `Project_Address__c` | `Project_Address__c` | Custom | Yes |
| `Projected_Start_Date__c` | `Projected_Start_Date__c` | Custom | Yes |
| `location_id` | Region/market custom field (optional) | Pipeline metadata | Optional — routing key |
| `source_ids` | Admin/custom field (optional) | Pipeline metadata | Optional — provenance |
| `source_urls` | Admin/custom field (optional) | Pipeline metadata | Optional — provenance |
| `confidence` | Admin/custom field (optional) | Pipeline metadata | Optional — gate input |
| `needs_review` | Admin/custom field or gate (optional) | Pipeline metadata | Optional — governs whether the lead syncs |

Two constraints worth noting on the Salesforce side. Standard Lead requires both
`LastName` and `Company`; the contract allows `LastName` to be an empty string
when the contact is unknown, so the upsert layer must supply a placeholder for
`LastName` in that case. And `needs_review` is typically used as a gate: a lead
flagged for review is commonly held for a human before it reaches Salesforce
rather than upserted automatically.

---

## RunManifest

Per-run metadata written alongside `sources.json` / `leads.json` in each output
run folder. It makes runs comparable, auditable, and possible to roll up across
locations.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | `string`, const `"1.0"` | Yes | Contract version. |
| `location_id` | `string`, pattern `^us-[a-z]{2}-[a-z0-9-]+$` | Yes | Which location this run covered. |
| `run_timestamp` | `string`, pattern `^[0-9]{8}T[0-9]{6}Z$` | Yes | UTC run time, `YYYYMMDDTHHMMSSZ`. Also the run folder name. |
| `stage` | `string` enum | Yes | Which pipeline stage produced this manifest. One of: `discovery`, `scrape`. |
| `agent_versions` | `object` (string → string) | No | Open map of version tag per agent/skill involved, e.g. `{"source_discovery": "1.0"}`. |
| `counts` | `object` | No | Keys (all integers, ≥ 0): `entities`, `sources_verified`, `leads`, `leads_needs_review`. |
| `coverage` | `number` 0–1 | No | Fraction of entities with at least one verified source. |
| `run_quality` | `number` 0–1 | No | Aggregate of per-source confidence for the run. |
| `budget` | `object` | No | What the goal loop consumed. Keys: `iterations` (int ≥ 0), `tool_calls` (int ≥ 0), `wall_time_seconds` (number ≥ 0), `stop_reason` (enum: `goal_met`, `diminishing_returns`, `max_iterations`, `budget_exhausted`). |
| `failed_sources` | `array` of `object` | No | Sources that could not be validated or scraped. Each item requires `id` and `reason`. Visible, not silently dropped. |
| `gaps` | `array` of `object` | No | Entities that ended a discovery run with no confident source. Each item requires `entity`; optional `strategies_tried` (array of strings) and `note`. |

---

## Enforcement

Contracts are enforced in three layers so that non-conforming data cannot move
between stages unnoticed.

**1. The PostToolUse hook (`.claude/hooks/validate_schema.py`).** After a file is
written, the hook selects the matching contract for the file (by path and record
shape), validates the content, and blocks a write that does not conform. Array
files such as `sources.json` and `leads.json` are validated element by element.
The hook degrades gracefully: if `jsonschema` or `pyyaml` cannot be imported, it
logs a warning and skips validation rather than blocking work. Skipping means you
lose the safety net for that write, so keep the dependencies installed.

**2. Boundary validation in each stage.** Each stage validates its input before
consuming it and its output before writing it. The Source Finder validates
`sources.json` before writing; the Lead Scraper validates `sources.json` on read
and `leads.json` before writing. This runs whether or not the hook fired, so a
stage never acts on data it has not checked.

**3. A CI check.** Continuous integration validates the tracked example run and any
committed contracts or fixtures against the schemas. This catches drift in review,
before it reaches a consumer such as Salesforce.

**Versioning field.** Every record is versioned, but not every contract carries
the version inline. `location`, `location_state`, and `run_manifest` include an
explicit `schema_version` field fixed at `"1.0"` (const). `source` and `lead`
records do not include an inline `schema_version`, and because both contracts set
`additionalProperties: false`, a record must not add one; those two contracts are
versioned by their pinned schema file (`$id`) and by this document. Either way the
rule is the same: never change a schema without bumping its version and updating
this document.

## Versioning & compatibility

- **Additive, backward-compatible changes are minor.** Adding an optional field,
  or adding a value to an enum, does not break existing records. Existing consumers
  keep working.
- **Removing or renaming a field, making an optional field required, or tightening
  a type or pattern is breaking.** A breaking change requires a new major
  `schema_version`.
- **When you bump a version:** update the `const` in the schema (where the field
  exists), update the field tables in this document, and coordinate the consumers —
  the validation hook, the per-stage boundary checks, the CI check, and the
  Salesforce mapping. Because the contracts are the API between stages, an
  un-coordinated change breaks the stage on the other side.
