---
name: source-discovery
description: Build or refresh a verified turf data-source inventory for one location_id drawn from locations/registry.yaml. Trigger on requests like "discover sources for us-tx-austin-msa", "refresh the source inventory for <location>", "find turf procurement/bid/bond sources for <place>", or the /discover command. Runs a location-driven, goal-based autonomous loop (scope, discover, validate, review, refine) and writes output/<location_id>/<run-timestamp>/sources.json and run_manifest.json. Do NOT use to extract leads (use lead-extraction) or for non-turf procurement.
---

# Source Discovery

Build a verified, machine-readable source inventory for one location, driven by a
`location_id` from the registry, not by any hardcoded source list. The run is an
autonomous goal loop: it keeps discovering, validating, reviewing, and re-trying
gaps until a measured coverage and quality bar is met or a budget cap is hit.

## Inputs
- One `location_id` slug, e.g. `us-tx-austin-msa`. Read its definition from
  `locations/registry.yaml` (name, type, scope.counties, priority, cadence). If
  the id is absent from the registry, stop and report it — do not invent scope.
- Current pipeline state for the location from `locations/state.json`.

## Conventions (shared across the pipeline)
- Output path: `output/<location_id>/<run-timestamp>/` where `<run-timestamp>` is
  UTC `YYYYMMDDTHHMMSSZ`. Files this stage writes: `sources.json`,
  `run_manifest.json`. Never overwrite a prior run — each run is a new folder.
- Contracts in `contracts/` are authoritative. Conform `sources.json` to
  `contracts/source.schema.json` (an array of Source objects) and
  `run_manifest.json` to `contracts/run_manifest.schema.json` (`stage: discovery`).
  Read both before writing so field names and enums match exactly.
- Keyword filters live ONLY in `config/keyword_filters.yaml`. Reference that path;
  never copy the lists into this skill, a source, or a sub-agent prompt.
- Sub-agents (defined in `.claude/agents/`): `scout` finds candidates, `validator`
  checks URL liveness + relevance, `reviewer` scores confidence independently.
  Dispatch them via the Task tool; each runs in an isolated context and returns
  only JSON.

## Goal metrics and default thresholds (tunable per run)
- `coverage` = entities with >= 1 confident source / total enumerated entities.
- `run_quality` = mean `confidence` of confident sources (reviewer-accepted).
- Defaults: `coverage_target = 0.90`, `quality_threshold = 0.60`,
  `saturation_floor = 1` new confident source, `K = 2` iterations,
  `max_iterations = 6`, `tool_calls_budget = 400`, `wall_time_budget = 1800s`.
- A confident source is one with `validation_status = "verified"` AND reviewer
  `accept = true` AND `confidence >= quality_threshold`.

## The loop

Set state `status` as you progress: `scoping` -> `discovering` -> `validating`
-> `review` -> (`ready_for_scrape` on goal, else `stale`/`blocked`/`failed`).

### Phase A — Scope (`scoping`)
Enumerate every public entity whose boundary overlaps the location's scope:
school districts, incorporated cities, counties, regional bid aggregators
(BidNet, DemandStar, Bonfire, etc.), purchasing cooperatives (BuyBoard, TIPS,
Choice Partners, etc.), and the state procurement portal. Confirm each entity's
homepage exists. This entity list is the coverage denominator; record it.

### Phase B — Discover (`discovering`)
Fan out one `scout` sub-agent per entity still lacking a confident source. Pass
each scout `{ name, entity_type, homepage }` and the `location_id`. Scouts return
arrays of candidate source objects (without ids or validation fields). Cap
concurrency in batches; hold candidates in the orchestrator.

### Phase C — Validate (`validating`)
Fan out one `validator` sub-agent per candidate URL. Validators return
`{ url, resolved_url, validation_status, validation_tier, evidence }`. Apply the
liveness loop rules the validator enforces: follow 301/302 redirects (adopt
`resolved_url` as the source `url`), retry transient failures up to 3 times, and
require real procurement/planning content — HTTP 200 alone is not `verified`.
Keep only candidates that reach `verified`.

### Phase D — Review (`review`)
Fan out one `reviewer` sub-agent per verified candidate (generator/critic
separation: the reviewer is never the scout that found it). Reviewers return
`{ url, confidence, accept, rubric, rationale }`. Set `confidence`, `reviewed:
true`. Accepted + `confidence >= quality_threshold` become confident sources.
A rejected source (`accept: false`) does NOT enter the inventory — re-queue its
entity for Phase E.

### Phase E — Refine
For every entity still without a confident source, re-queue it with the NEXT
escalation strategy and loop back to Phase B:

    own site -> aggregator -> cooperative -> state portal -> news/press

Each entity advances one rung per iteration, so a gap is retried a different way
rather than abandoned. Track each entity's `strategies_tried`.

### Exit conditions (evaluate after each iteration)
Stop and set `budget.stop_reason` accordingly:
- `goal_met` — `coverage >= coverage_target` AND `run_quality >= quality_threshold`.
- `diminishing_returns` — `new_verified < saturation_floor` for `K` consecutive
  iterations.
- `max_iterations` — `iterations >= max_iterations`.
- `budget_exhausted` — `tool_calls` or `wall_time` cap reached.

Always emit a gap report regardless of stop reason.

## Assembling each Source object (orchestrator)
- `id`: assign sequentially per run, `SRC-001`, `SRC-002`, ...
- `location_id`: the run's slug (echoed by scouts; verify it).
- From scout: `entity`, `entity_type`, `source_type`, `name`, `url`, `contains`,
  `relevant_sports`, `lead_stage`, `searchability`, `monitor_frequency`,
  `sport_confirmed`.
- From validator: `validation_status`, `validation_tier`; set `last_validated` to
  the UTC time of successful validation.
- From reviewer: `confidence`, `reviewed: true`.

## Sport classification
- `sport_confirmed: true` ONLY when a target sport (football, soccer, or
  baseball/softball) is explicitly named on the page.
- Generic "athletic fields", "stadium", or "sports complex" with no named sport
  -> `sport_confirmed: false` and `relevant_sports: [needs_validation]`.
- Broad procurement portals listing many bid types -> `sport_confirmed: false`,
  `relevant_sports: [needs_validation]`.
- Qualification of specific projects uses the turf + sport rule in
  `config/keyword_filters.yaml`; do not restate the lists here.

## Output
1. Write `output/<location_id>/<run-timestamp>/sources.json` — a wrapper document
   `{ "schema_version": "1.0", "location_id": "<slug>", "sources": [ ... ] }` whose
   `sources` array holds the confident Source objects, each valid against
   `contracts/source.schema.json`.
2. Write `output/<location_id>/<run-timestamp>/run_manifest.json` with
   `schema_version: "1.0"`, `location_id`, `run_timestamp`, `stage: "discovery"`,
   `agent_versions` (e.g. `{ "source_discovery": "1.0", "scout": "1.0",
   "validator": "1.0", "reviewer": "1.0" }`), `counts.entities`,
   `counts.sources_verified`, `coverage`, `run_quality`, `budget`
   (iterations, tool_calls, wall_time_seconds, stop_reason), and `gaps`
   (each `{ entity, strategies_tried, note }`).
3. Update `locations/state.json` for this location: set `coverage`,
   `quality_score` (= run_quality), `counts`, `latest_run` (the run-timestamp
   folder), `last_run`, and `next_due` (derived from the registry `cadence`).
   Set `status: "ready_for_scrape"` only when the goal was met; otherwise
   `stale` (thin coverage), `blocked` (external barrier, note it), or `failed`.

The PostToolUse hook validates every written `sources.json` and
`run_manifest.json` against `contracts/`. If it reports errors, fix the data and
rewrite — do not ship an invalid artifact.

## Execution checklist
```
[ ] location_id resolved in locations/registry.yaml (scope read)
[ ] Phase A: full entity list enumerated (coverage denominator recorded)
[ ] Phase B: scout dispatched per uncovered entity; candidates collected
[ ] Phase C: validator dispatched per candidate; only verified kept
[ ] Phase D: reviewer dispatched per verified source; confident set decided
[ ] Phase E: uncovered entities re-queued with next escalation strategy
[ ] Exit condition met; budget.stop_reason set
[ ] sources.json written and schema-valid
[ ] run_manifest.json (stage=discovery) written with gaps report
[ ] locations/state.json updated (status, coverage, quality_score, next_due)
```

## Rules
- Only public sources. No fabricated entities, URLs, or dates; if nothing is
  found for an entity, record a gap rather than a guess.
- Provide deep-linked URLs over homepages whenever a specific page exists.
- Do not attack competing technologies or natural grass; describe what a source
  is and what it contains.
- For very large geographies (e.g. a whole state), suggest splitting into metros
  or counties and running once per sub-region.
