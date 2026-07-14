# Turf Lead Pipeline — Architecture & Scaling Guidance

> **Update (July 2026, platform consolidation).** This document predates the
> decision to consolidate this pipeline with the meeting-minutes repo into one
> platform (Supabase store + Retool UI) for a 3-month BDM trial. Where it says
> *region*, read *location*; where it says *Salesforce*, read *Supabase* —
> Salesforce comes only after the trial proves value. Since then the repo has
> also gained three durable stores that implement the "incremental, not full
> re-scrape" guidance in §5: `sources/registry.json` (registry-first
> discovery), `organizations/registry.json` (leads anchor on organizations,
> with many-to-many geography), and `leads/ledger.json` (scrapes skip known
> `external_id`s). The lead contract is now two-tier (flat BDM-readable core +
> nested evidence detail) — see `docs/SCHEMAS.md`, which is authoritative for
> data shapes. The rest of this document remains valid design rationale.

This document responds to five questions about the lead-scraping tool:

1. Overall repository and agent structure
2. How the Source Finder agent should be designed and organised
3. How to implement an iterative search and validation process
4. How the output structure should be organised for scalability
5. Architectural considerations for expanding from a single district to a national rollout

It is written as guidance and a recommended target state, not a finished
implementation. Where the current repo already does something well, that is
noted so it is kept rather than rebuilt.

---

## 0. Where the pipeline stands today

The tool is two cooperating agents plus a shared data contract:

```
Source Finder  ──►  turf_lead_data_sources.md  ──►  Lead Scraper  ──►  leads JSON
(source_finder/SKILL.md)      (the contract)        (lead_scraper_agent.md)
```

Three issues are worth fixing before scaling, because scaling multiplies them:

- **The committed source list is out of sync with the output.**
  `turf_lead_data_sources.md` contains SRC-001–004, but
  `output/austin_turf_leads.json` cites sources up to SRC-041. The source list
  that actually produced the leads is not in the repo, so the run is not
  reproducible.
- **The agent-to-agent contract is unpinned.** The two output files disagree on
  schema: one has `Project_Name__c` and an `id` field (holding source ids), the
  other does not. Downstream (Salesforce) needs one stable schema with a version.
- **Configuration is duplicated.** The keyword filters live both in the skill
  body and in every source file. Duplicated config drifts; it should have one home.

These are the reasons the recommendations below lean on explicit schemas, a
single config source, and per-region reproducible runs.

---

## 1. Repository and agent structure

The pipeline has four kinds of thing, and they change for different reasons.
Separating them is the main structural recommendation:

- **Agent definitions** — the instructions (change when we improve the agents)
- **Shared contracts and config** — schemas and keyword filters (change rarely, break everyone when they do)
- **Region inputs** — which places to cover (grow as the rollout expands)
- **Run outputs** — generated artifacts (append-only, ideally not in git history)

### Recommended layout

```
lead-scraper/
├── agents/
│   ├── source_finder/
│   │   ├── SKILL.md              # the discovery skill (moved here already)
│   │   ├── README.md             # what it consumes / produces
│   │   └── references/           # aggregator + cooperative registries, entity taxonomy
│   └── lead_scraper/
│       ├── SKILL.md              # scraper agent instructions (from lead_scraper_agent.md)
│       └── README.md
├── contracts/
│   ├── source.schema.json        # one source entry (Source Finder output)
│   ├── lead.schema.json          # one lead (Lead Scraper output)
│   ├── region.schema.json        # a region definition (input)
│   └── run_manifest.schema.json  # per-run metadata
├── config/
│   └── keyword_filters.yaml       # single source of truth — turf/sport/procurement/exclusion
├── regions/                       # inputs: what to cover
│   └── us-tx-austin-msa/
│       ├── region.yaml            # scope, counties, priority, cadence
│       └── sources.json           # Source Finder output for this region (the contract)
├── output/                        # generated; git-ignored, archived elsewhere
│   └── us-tx-austin-msa/
│       └── 2026-07-01T184158Z/
│           ├── sources.json
│           ├── leads.json
│           └── run_manifest.json
└── docs/
    ├── ARCHITECTURE.md
    └── RUNBOOK.md
```

### Why this shape

- **`source_finder/SKILL.md` now lives in its own agent folder** (done). Give
  `lead_scraper_agent.md` the same treatment so the two agents are symmetric and
  each folder is self-describing.
- **`contracts/` holds machine-readable JSON Schemas.** These are the API between
  the agents. Pin them, version them (`schema_version` field), and validate
  output against them at the end of every run. This is what stops the schema
  drift seen between the two current output files.
- **`config/keyword_filters.yaml` is the one place filters live.** Both agents
  read it. The Source Finder stops embedding a copy in each source file; the
  scraper stops carrying its own copy. One edit, both agents updated.
- **`regions/` is input, `output/` is generated.** Region definitions are small,
  reviewed, and versioned in git. Run outputs are large, append-only, and belong
  in object storage or a `.gitignore`d directory — not in git history, where they
  bloat the repo as the rollout grows.

### The source contract should be JSON, not Markdown

The Source Finder currently writes Markdown that the scraper parses by hand
(`### SRC-XXX` blocks). Hand-parsed Markdown is brittle and will break silently
as formatting drifts. Recommendation: **JSON is the canonical contract**
(`sources.json`, validated against `source.schema.json`); optionally render a
human-readable `sources.md` from it. Machines read the JSON; people read the
Markdown; they never disagree because one is generated from the other.

---

## 2. Source Finder agent design

Keep the phased structure in `SKILL.md` — the phases (scope → discover →
validate → classify → write → rank) are sound. The changes are about making it
goal-driven and moving shared concerns out of the agent.

Recommended responsibilities, unchanged in spirit:

1. **Scope** — enumerate every public entity in the region (districts, cities,
   counties, aggregators, cooperatives, state portal).
2. **Discover** — for each entity, find procurement portals and planning/funding
   docs.
3. **Validate** — verify each URL is live *and* relevant (Phase 3 loop).
4. **Classify** — populate the source fields.
5. **Emit** — write `sources.json` (contract) + optional `sources.md` (readable).

Design changes:

- **Fan out one sub-agent per entity for discovery**, mirroring the pattern the
  scraper already uses. Discovery of Round Rock ISD is independent of discovery
  of Hays CISD; running them in isolated contexts keeps each context small and
  makes the run parallelisable. The orchestrator holds the entity list and
  merges results.
- **Read filters from `config/`, don't embed them.** The "Standard keyword filter
  block" in Phase 5 should be a reference to the shared file, not a copy pasted
  into every output.
- **Make coverage explicit.** The agent should know its denominator (all
  enumerated entities) and its numerator (entities with ≥1 verified source).
  This coverage ratio is what drives the loop in section 3.
- **Attach a confidence score to every source** (see the quality rubric in
  section 3), so downstream monitoring and the run's quality gate have something
  to threshold on.
- **Persist a run-state object** (frontier of entities/queries to try, visited
  set, results with status). This makes the run resumable and idempotent rather
  than a single throwaway pass.

---

## 3. Iterative search and validation

This is the core request: move from a single pass to a goal-based loop that keeps
refining and validating until a defined quality bar is met or returns diminish.

Think of it as **two nested loops with explicit exit conditions**.

### Inner loop — validate each source (already specified, keep it)

Phase 3 of the skill is already the right idea: fetch each URL, follow redirects,
retry transient failures, search for a replacement when broken, and confirm the
page actually contains procurement/planning content — not just HTTP 200. Keep
this. The only addition is to record a **validation tier** per source so the
outer loop can reason about quality:

| Tier | Meaning |
|---|---|
| `live` | URL returns 200 |
| `relevant` | page contains procurement or planning keywords |
| `fresh` | page shows a listing dated within the monitor window |
| `sport_confirmed` | a target sport is explicitly named |

### Outer loop — discovery until the goal is met

This is what is missing today. Wrap discovery in a goal loop:

```
STATE:
  entities        = enumerated public entities (the denominator)
  frontier        = queue of (entity, search_strategy) tasks to try
  sources         = verified sources found so far
  iterations      = 0

LOOP:
  1. Take the next batch of tasks off the frontier.
  2. Fan out one sub-agent per task; each returns candidate sources.
  3. Run every candidate through the inner validation loop.
  4. Keep validated sources; score each (quality rubric below).
  5. Recompute goal metrics:
       - coverage      = entities with >=1 verified source / total entities
       - new_verified  = verified sources added this iteration
       - run_quality   = aggregate of per-source confidence scores
  6. For entities still with zero verified sources, enqueue the NEXT
     escalation strategy (own site -> aggregators -> cooperatives ->
     state portal -> news/press), so gaps are retried a different way
     rather than abandoned.

EXIT when ANY stopping condition is true:
  - coverage >= target (e.g. 0.9 of entities have >=1 verified source), AND
    run_quality >= threshold                         # goal met
  - new_verified < saturation_floor for K iterations  # diminishing returns
  - iterations >= max_iterations                      # budget cap
  - tool_calls / wall_time >= budget                  # cost cap

ALWAYS emit a gap report: entities that ended with zero verified sources,
with the strategies already tried.
```

The three ideas that make this work:

- **A goal, not a pass.** The loop ends on a measured coverage/quality target,
  not after one sweep. Entities with no source get retried with a *different*
  strategy each iteration (own site → aggregator → cooperative → state portal →
  press), which is exactly where the current single pass gives up.
- **A saturation check.** When an iteration adds almost nothing new, keep
  searching stops being worthwhile. `new_verified < saturation_floor for K
  iterations` is the "returns have diminished" signal — this prevents both
  premature stopping and endless searching.
- **Hard budget caps.** `max_iterations`, tool-call, and time caps guarantee
  termination even when a region is unusually sparse or noisy.

### Quality rubric (per-source confidence score)

Score each verified source so the run has an objective quality measure and so
low-confidence sources can be flagged for review:

| Signal | Higher score when… |
|---|---|
| Deep-link specificity | direct solicitation/bond page, not a department landing page |
| Freshness | listing dated within the monitor window |
| Sport confirmation | a target sport is explicitly named (`sport_confirmed: true`) |
| Searchability | keyword search available vs. PDF-only |
| Corroboration | the same project appears in a second independent source |

The **run quality score** is an aggregate (e.g. mean confidence of verified
sources). It becomes a gate: a run below threshold is flagged rather than shipped
to the scraper.

### Applying the same loop to the Lead Scraper

The scraper benefits from the same discipline: validate each extracted lead (does
it match a turf keyword *and* a sport keyword; is the address resolvable; is it a
duplicate), score its completeness, and only accept leads above a confidence
threshold — routing the rest to review. The `failed_sources` array the scraper
already emits is the right instinct; formalise it as part of the run manifest.

---

## 4. Output structure for scalability

The current single flat JSON per run does not scale to many regions and many
repeated runs. Partition it.

### Partition by region, then by run

```
output/<region-slug>/<run-timestamp>/
    sources.json         # Source Finder output (validated against contract)
    leads.json           # Lead Scraper output
    run_manifest.json    # metadata: see below
    raw/                 # optional: fetched evidence for audit
```

- `<region-slug>` is a stable identifier, e.g. `us-tx-austin-msa`. Use it in both
  inputs (`regions/`) and outputs so a region is traceable end to end.
- `<run-timestamp>` is the existing `YYYYMMDDTHHMMSSZ` convention — keep it. It
  already preserves prior runs instead of overwriting, which is correct.

### A run manifest per run

Every run writes `run_manifest.json` capturing what happened, so runs are
comparable and auditable:

```json
{
  "schema_version": "1.0",
  "region": "us-tx-austin-msa",
  "run_timestamp": "2026-07-01T184158Z",
  "agent_versions": { "source_finder": "…", "lead_scraper": "…" },
  "counts": { "entities": 0, "sources_verified": 0, "leads": 0 },
  "coverage": 0.0,
  "run_quality": 0.0,
  "failed_sources": [],
  "gaps": []
}
```

### Stable, versioned schemas and stable lead ids

- Add `schema_version` to source, lead, and manifest records. This is what lets
  Salesforce (or any consumer) evolve safely.
- **Give every lead a stable id** derived from its content (e.g. a hash of
  entity + site + scope). Today leads have no stable identifier, and the two
  output files even disagree on what `id` means. A stable id is what makes CRM
  upserts idempotent — the same project found next week updates the existing
  record instead of creating a duplicate.

### A "latest" pointer and a cross-region rollup

- Maintain a `latest` pointer (symlink or an index file) per region so downstream
  consumers can find the current run without scanning timestamps.
- Maintain a cross-region rollup (`index.json` / CSV) listing every region's
  latest run, counts, and quality — this is the national view of lead discovery.

---

## 5. Scaling from one district to a national rollout

The single-region run is the unit; the national rollout is orchestration over
many units. The following make that tractable and support the goal of surfacing
opportunities early.

### Region registry drives everything

Add a top-level registry (`regions/index.yaml`) listing every target region with
its status, priority, and cadence. Runs are launched from the registry, not by
hand. Expanding coverage becomes "add a region entry," not "write new code."

### Prioritise regions by opportunity signal

Not all regions are equal, and running them all at once is expensive. Rank by
signals that correlate with turf demand — enrollment growth, recent bond passage,
district size, known capital plans — and run high-value regions first and more
often. This directly serves "identify opportunities as early as possible":
attention goes where new opportunities are most likely.

### Cadence and change detection are what make it "early"

- The source records already carry `monitor_frequency` (weekly / monthly /
  quarterly). Promote this to a scheduler: procurement portals checked weekly,
  bond/CIP pages monthly, master plans quarterly. Runs are **incremental**, not
  full re-scrapes.
- **Diff each run against the previous run** for the same region. Surface only
  new or changed leads. A new bond solicitation detected the week it posts is the
  early signal the rollout is meant to catch; without diffing, it is buried in a
  full re-dump every time.

### Deduplication across time and across regions

Stable lead ids (section 4) make dedup mechanical: within a region over time, and
across adjacent regions whose boundaries overlap (the Austin MSA already spans
five counties with overlapping districts). Dedup before CRM upsert, not after.

### Known constraints to plan around

- **Login/JS-gated aggregators.** The existing `failed_sources` already show
  DemandStar and BidNet pages returning nothing to an unauthenticated fetch.
  At national scale this recurs constantly. Plan for authenticated connectors
  where licensing allows, and treat these as known gaps in the manifest rather
  than silent misses everywhere else.
- **Concurrency, politeness, and cost.** Fan-out has a real cost. Cap concurrency,
  batch sub-agents, respect robots and rate limits, and track tool-call/time
  budgets per run (the budget caps from section 3 apply per region).
- **Human-in-the-loop for low confidence.** Route leads and sources below the
  confidence threshold to review before they reach Salesforce. Precision matters
  more than volume when a human sales team acts on each lead.

### Observability

Persist per-run metrics (coverage, quality, counts, failures, gaps) and roll them
up across regions. This is how the rollout's health is monitored: which regions
are well-covered, which are stale, where discovery is failing, and how lead
volume trends over time.

---

## Suggested sequencing

If this is adopted incrementally, a low-risk order:

1. Pin the contracts: write `source.schema.json` and `lead.schema.json`, add
   `schema_version`, and reconcile the two divergent output schemas into one.
2. Move keyword filters to `config/keyword_filters.yaml`; point both agents at it.
3. Re-commit the Austin source list that actually produced the output, so the run
   is reproducible, and adopt the `regions/<slug>/` + `output/<slug>/<run>/` layout.
4. Add the Source Finder goal loop (coverage + saturation + budget caps) and the
   per-source confidence score.
5. Add the region registry, run manifest, stable lead ids, and run-to-run diffing.
6. Layer scheduling, cadence, and cross-region rollup for the national rollout.
