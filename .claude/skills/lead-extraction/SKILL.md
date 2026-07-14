---
name: lead-extraction
description: Extract artificial-turf leads for a location from its verified source inventory. Trigger on requests like "scrape leads for us-tx-austin-msa", "extract turf leads for <location>", "run the scraper", or the /scrape command, once source-discovery has produced a ready_for_scrape inventory. Orchestrator fans out one scraper-worker per verified source, consolidates and dedups against leads/ledger.json by stable external_id (never re-extracts known leads), and writes new leads to output/<location_id>/<run-timestamp>/leads.json + the ledger. Do NOT use to discover or verify sources (use source-discovery).
---

# Lead Extraction

Read a location's verified source inventory and extract artificial-turf leads
(football, soccer, baseball/softball only) as two-tier records: a flat core a
BDM can read at a glance, plus an optional nested `evidence` block with the
extraction detail. This skill is the orchestrator: it fans work out to one
`scraper-worker` sub-agent per source and fans the results back in.

**Ledger-first: never pay twice for the same lead.** `leads/ledger.json` holds
every lead ever recorded, keyed by `external_id`. A scrape run skips leads
already in the ledger and appends only new ones, so re-runs extract only what is
genuinely new.

## Inputs
- One `location_id` slug, e.g. `us-tx-austin-msa`.
- The source inventory: verified sources for this location from the durable
  registry `sources/registry.json` (entries whose `location_ids` include the
  slug), cross-checked against the latest run snapshot under
  `output/<location_id>/` (use `state.latest_discovery_run` from
  `locations/state.json` as a hint). Read once, in the orchestrator.
- The lead ledger `leads/ledger.json` (known `external_id`s and project labels).
- The organization registry `organizations/registry.json` (for
  `organization_id`, `state`, primary `county` on each lead).
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
1. Load the verified sources for the location once. Load the ledger once and
   index known leads by `external_id`; also collect, per source, the known
   project labels (`evidence.project_name`) already recorded from it.
2. Dispatch one `scraper-worker` per verified source. Pass each worker the source
   fields `{ id, entity, url, relevant_sports, sport_confirmed }`, its
   `location_id`, the list of ALREADY-KNOWN project labels for that source (so
   the worker skips re-extracting them and reports only new or changed
   projects), and point it at `config/keyword_filters.yaml`. Cap concurrency in
   batches to respect rate limits and tool-call budget.
3. Each worker returns a JSON array of lead objects (empty `[]` if none), WITHOUT
   `external_id`. It fills the core fields (`organization`, `summary`,
   `evidence_quote`, `source_url`, `location_id`) and the `evidence` block
   (project_name, details, contact, source_ids, source_urls, confidence,
   needs_review). Hold each array in memory as it returns; do not write
   per-source files.
4. If a worker fails, times out, or returns malformed JSON, record its source
   `id` and a short reason in a `failed_sources` list and continue. Do not
   silently drop it. Update the source's `last_checked`/`last_result` in
   `sources/registry.json` either way (e.g. "scraped: 2 new leads" or the
   failure reason).

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
  it in `evidence.project_address`. Constrain the query with the entity and its
  county/city so the right facility matches; leave it "" if it cannot be
  confidently resolved or there is no named site.
- Never fabricate solicitation numbers, dates, costs, or contacts. Unknown string
  fields are `""`; unknown arrays stay empty.
- `evidence.project_name` is a label: `[Site or facility name] - [compact scope]`,
  3-8 words, max 255 chars — not a sentence. It feeds the `external_id` hash.
- Core fields the orchestrator completes from the registries: `organization_id`,
  `state`, and `county` (the organization's PRIMARY county — never guess a
  county onto a multi-county district), `source: "web-search"`,
  `discovered_at` (UTC now for new leads).

## Consolidate and deduplicate
1. Merge every worker's array into one list.
2. Compute a stable `external_id` for each lead: a hash (e.g. SHA-1 hex) of
   `organization + "|" + evidence.project_name + "|" + source_url`. Normalize
   inputs (trim, lowercase) before hashing so the id is stable across runs. The
   recipe is unchanged from v1 (organization was `Company`, project_name was
   `Project_Name__c`), so ids stay stable across the schema bump. Length must be
   >= 8; a full SHA-1 hex satisfies this.
3. Deduplicate by `external_id` across all sources: leads sharing an id are the
   same project. Merge them — union `evidence.source_ids` and
   `evidence.source_urls`, prefer non-empty field values, keep the highest
   `confidence`, and set `needs_review` true if any copy was flagged.
4. **Dedup against the ledger:** a lead whose `external_id` is already in
   `leads/ledger.json` is NOT new — count it as `leads_duplicate` and do not
   re-append it (if the source shows a material change, update the existing
   ledger entry's evidence in place instead). Leads with unseen ids are
   `leads_new`.
5. Set `evidence.needs_review: true` on any lead missing a core field, with an
   unconfirmed sport, or below the review confidence threshold.

## Output
1. Write `output/<location_id>/<run-timestamp>/leads.json` — a wrapper document
   `{ "schema_version": "2.0", "location_id": "<slug>", "leads": [ ... ] }` whose
   `leads` array holds this run's NEW (and materially changed) Lead objects, each
   valid against `contracts/lead.schema.json`, with `evidence.run_timestamp` set
   to this run folder.
2. Append the new leads to `leads/ledger.json` (same record shape; keyed by
   `external_id`; never delete an entry).
3. Write `output/<location_id>/<run-timestamp>/run_manifest.json` with
   `schema_version: "1.1"`, `location_id`, `run_timestamp`, `stage: "scrape"`,
   `agent_versions` (e.g. `{ "lead_extraction": "2.0", "scraper_worker": "2.0" }`),
   `counts.leads`, `counts.leads_new`, `counts.leads_duplicate`,
   `counts.leads_needs_review`, and the `failed_sources` array
   (each `{ id, reason }`). Populate `budget` if tracked.
4. Update `locations/state.json` for this location: set `counts.leads` (ledger
   total for the location), `latest_run` and `latest_scrape_run` (this scrape
   run folder), `last_run`, `last_scraped` (UTC now), and `status: "scraped"`.
   Update `sources/registry.json` `last_checked`/`last_result` for every source
   touched.

The PostToolUse hook validates every written `leads.json` and `run_manifest.json`
against `contracts/`. If it reports errors, fix the data and rewrite.

## Execution checklist
```
[ ] location_id given; verified sources loaded (registry + latest snapshot)
[ ] leads/ledger.json loaded; known project labels indexed per source
[ ] verified sources filtered (>= 1 present, else stop)
[ ] one scraper-worker dispatched per verified source (with known-lead labels)
[ ] every worker result collected; failures logged to failed_sources
[ ] arrays merged; stable external_id assigned to each lead
[ ] cross-source dedup by external_id (evidence source lists unioned)
[ ] ledger dedup: known ids counted as leads_duplicate, not re-appended
[ ] core fields completed from registries (organization_id, state, county)
[ ] needs_review flags set
[ ] leads.json (new leads only) written and schema-valid
[ ] new leads appended to leads/ledger.json
[ ] run_manifest.json (stage=scrape) written with new/duplicate counts
[ ] locations/state.json updated (status=scraped, last_scraped, latest_scrape_run)
[ ] sources/registry.json last_checked/last_result updated
```

## Rules
- Use only the sources in the inventory; do not add external sources here.
- Capture only football, soccer, and baseball/softball turf leads; exclude other
  sports and unrelated recreation facilities.
- Preserve each lead's `source_ids` for traceability.
- Cross-source deduplication is the orchestrator's job; workers dedup only within
  their single source.
