---
name: lead-extraction
description: Extract artificial-turf leads for a location from its verified sources.json. Trigger on requests like "scrape leads for us-tx-austin-msa", "extract turf leads for <location>", "run the scraper", or the /scrape command, once source-discovery has produced a ready_for_scrape inventory. Orchestrator fans out one scraper-worker per verified source, consolidates and dedups, assigns a stable external_id, and writes output/<location_id>/<run-timestamp>/leads.json and run_manifest.json (stage=scrape). Do NOT use to discover or verify sources (use source-discovery).
---

# Lead Extraction

Read a location's verified source inventory and extract artificial-turf leads
(football, soccer, baseball/softball only) into Salesforce-shaped records. This
skill is the orchestrator: it fans work out to one `scraper-worker` sub-agent per
source and fans the results back in.

## Inputs
- One `location_id` slug, e.g. `us-tx-austin-msa`.
- The location's latest source inventory: the most recent run folder under
  `output/<location_id>/` that contains a `sources.json` (use `state.latest_run`
  from `locations/state.json` as a hint). Read that `sources.json` once, in the
  orchestrator.
- Only sources with `validation_status == "verified"` are scraped. If none exist,
  stop and report that discovery has not produced a ready inventory.

## Conventions (shared across the pipeline)
- Output path: `output/<location_id>/<run-timestamp>/` where `<run-timestamp>` is
  a NEW UTC `YYYYMMDDTHHMMSSZ` folder for this scrape run. Files: `leads.json`,
  `run_manifest.json`. Never overwrite a prior run.
- Contracts in `contracts/` are authoritative. Conform `leads.json` to
  `contracts/lead.schema.json` (an array of Lead objects) and `run_manifest.json`
  to `contracts/run_manifest.schema.json` (`stage: scrape`). Read both first.
- Keyword filters live ONLY in `config/keyword_filters.yaml`. Reference that path;
  never copy the lists here or into a worker prompt.
- Sub-agent `scraper-worker` (in `.claude/agents/`) does the per-source
  extraction. Dispatch via the Task tool.

## Orchestration
1. Load `sources.json` once. Filter to verified sources.
2. Dispatch one `scraper-worker` per verified source. Pass each worker the source
   fields `{ id, entity, url, relevant_sports, sport_confirmed }` plus its
   `location_id`, and point it at `config/keyword_filters.yaml`. Cap concurrency
   in batches to respect rate limits and tool-call budget.
3. Each worker returns a JSON array of lead objects (empty `[]` if none), WITHOUT
   `external_id`. It sets `location_id`, `source_ids` (the source id it was
   given), `source_urls` (exact pages), `confidence`, and `needs_review`. Hold
   each array in memory as it returns; do not write per-source files.
4. If a worker fails, times out, or returns malformed JSON, record its source
   `id` and a short reason in a `failed_sources` list and continue. Do not
   silently drop it.

## Keyword qualification (enforced by the worker, verified here)
A candidate qualifies as a lead only if it matches at least one turf keyword AND
at least one sport keyword (or an explicit multipurpose football/soccer or
baseball/softball field). Reject candidates matching only exclusion keywords
unless a target sport is also clearly present. The canonical lists are in
`config/keyword_filters.yaml` — do not restate them.

## Field resolution (no fabrication)
- A NAMED facility is a resolvable address, not a missing value. If a source names
  a specific campus, stadium, park, complex, or field but not its street address,
  resolving that real address via search is retrieval, not fabrication — record
  it in `Project_Address__c`. Constrain the query with the entity and its
  county/city so the right facility matches; leave it "" if it cannot be
  confidently resolved or there is no named site.
- Never fabricate solicitation numbers, dates, costs, or contacts. Unknown string
  fields are `""`; unknown arrays stay empty.
- `Project_Name__c` is a label: `[Site or facility name] - [compact scope]`,
  3-8 words, max 255 chars — not a sentence.

## Consolidate and deduplicate
1. Merge every worker's array into one list.
2. Compute a stable `external_id` for each lead: a hash (e.g. SHA-1 hex) of
   `Company + "|" + Project_Name__c + "|" + primary_source_url`, where
   `primary_source_url` is the lead's first `source_urls` entry (fall back to the
   source `url`). Normalize inputs (trim, lowercase) before hashing so the id is
   stable across runs. This maps to the Salesforce External Id so upserts are
   idempotent. Length must be >= 8; a full SHA-1 hex satisfies this.
3. Deduplicate by `external_id` across all sources: leads sharing an id are the
   same project. Merge them — union `source_ids` and `source_urls`, prefer
   non-empty field values, keep the highest `confidence`, and set `needs_review`
   true if any copy was flagged.
4. Set `needs_review: true` on any lead missing a required field, with an
   unconfirmed sport, or below the review confidence threshold.

## Output
1. Write `output/<location_id>/<run-timestamp>/leads.json` — a wrapper document
   `{ "schema_version": "1.0", "location_id": "<slug>", "leads": [ ... ] }` whose
   `leads` array holds the deduplicated Lead objects (now WITH `external_id`), each
   valid against `contracts/lead.schema.json`. Each lead keeps `location_id` and at
   least one `source_ids` entry so it traces back to the inventory.
2. Write `output/<location_id>/<run-timestamp>/run_manifest.json` with
   `schema_version: "1.0"`, `location_id`, `run_timestamp`, `stage: "scrape"`,
   `agent_versions` (e.g. `{ "lead_extraction": "1.0", "scraper_worker": "1.0" }`),
   `counts.leads`, `counts.leads_needs_review`, and the `failed_sources` array
   (each `{ id, reason }`). Populate `budget` if tracked.
3. Update `locations/state.json` for this location: set `counts.leads`,
   `latest_run` (this scrape run folder), `last_run`, and `status: "scraped"`.

The PostToolUse hook validates every written `leads.json` and `run_manifest.json`
against `contracts/`. If it reports errors, fix the data and rewrite.

## Execution checklist
```
[ ] location_id given; latest sources.json located and read once
[ ] verified sources filtered (>= 1 present, else stop)
[ ] one scraper-worker dispatched per verified source
[ ] every worker result collected; failures logged to failed_sources
[ ] arrays merged; stable external_id assigned to each lead
[ ] cross-source dedup by external_id (source_ids/source_urls unioned)
[ ] needs_review flags set
[ ] leads.json written and schema-valid
[ ] run_manifest.json (stage=scrape) written with failed_sources
[ ] locations/state.json updated (status=scraped, counts.leads, latest_run)
```

## Rules
- Use only the sources in the inventory; do not add external sources here.
- Capture only football, soccer, and baseball/softball turf leads; exclude other
  sports and unrelated recreation facilities.
- Preserve each lead's `source_ids` for traceability.
- Cross-source deduplication is the orchestrator's job; workers dedup only within
  their single source.
