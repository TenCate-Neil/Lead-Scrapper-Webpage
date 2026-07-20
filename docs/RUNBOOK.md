# Operator Runbook (RUNBOOK.md)

This guide is for operators running the turf-lead pipeline: adding locations,
running discovery and extraction, reading run output, and handling the common
failure modes. It is practical and example-driven; the running example is the
Austin metro location, `us-tx-austin-msa`.

For the design, read `docs/ARCHITECTURE.md`. For the field-level data contracts
and the Supabase mapping, read `docs/SCHEMAS.md`. For the directory map, read
`CLAUDE.md`.

The pipeline has two stages joined by shared storage and the location state
machine. The Source Finder discovers and validates sources; the Lead Scraper
reads those sources and extracts leads. Neither stage calls the other directly.

Three durable stores make re-runs cheap — consult them before doing anything
from scratch:

- `sources/registry.json` — every source ever discovered (deduped on
  `normalized_url`). Discovery re-checks these first; web search only tops up.
- `organizations/registry.json` — the entities leads anchor on, with primary
  county and many-to-many geography.
- `leads/ledger.json` — every lead ever recorded, keyed by `external_id`.
  Scrape runs skip known ids, so nothing is paid for twice.

## Prerequisites

- **Python 3** for the validation hook and manual checks.
- **`jsonschema` and `pyyaml`.** Install with:

  ```bash
  python3 -m pip install jsonschema pyyaml
  ```

  `jsonschema` validates records against the contracts in `contracts/`. `pyyaml`
  lets the tooling read `locations/registry.yaml` and `config/keyword_filters.yaml`.

- The hook degrades gracefully. If `jsonschema` or `pyyaml` is missing, the
  PostToolUse hook logs a warning and skips validation rather than blocking a
  write. A missing dependency will not halt a run, but you lose the schema safety
  net until you install it, so treat a "validation skipped" warning as something
  to fix.
- Claude Code with this repo's `.claude/` commands available (`/discover`,
  `/scrape`, `/status`).

## Add a new location

Locations are input. Add one to `locations/registry.yaml` as a single entry that
conforms to `contracts/location.schema.json` (see the field table in
`docs/SCHEMAS.md`).

Example entry for the Austin metro:

```yaml
- schema_version: "1.0"
  location_id: us-tx-austin-msa
  name: Austin Metro (5-county MSA)
  type: metro
  priority: high
  cadence: monthly
  added_date: "2026-07-01"
  scope:
    state: TX
    counties: [Travis, Williamson, Hays, Bastrop, Caldwell]
  tags: [texas, tier-1]
```

Required fields: `schema_version`, `location_id`, `name`, `type`, `priority`,
`cadence`, `added_date`. `scope` and `tags` are optional.

Once added, the location appears in `locations/state.json` with `status: pending`.
Its `next_due` is derived from `cadence`. It is now in the work queue and ready
for discovery.

## Run discovery for a location

```bash
/discover us-tx-austin-msa
```

This runs the Source Finder (the `source-discovery` skill). It is
**registry-first**: it enumerates the public entities in the location (upserting
`organizations/registry.json`), re-checks every known source in
`sources/registry.json` that covers the location, and only then discovers new
candidate procurement and planning sources for the entities still uncovered. New
finds are validated (live, relevant, fresh, sport-confirmed), scored, reviewed,
and merged into the registry (deduped on `normalized_url` — nothing is ever
deleted, broken sources just record their failure in `last_result`). The loop
repeats until it meets its coverage and quality target or hits a budget cap.

A re-run of a location is therefore mostly "re-check known sources + look for
new ones", never "search the entire web again".

Output lands in a new timestamped run folder (a snapshot; the registry is the
durable store):

```
output/us-tx-austin-msa/20260701T184158Z/
    sources.json        # wrapper of Source records (contract: source.schema.json)
    run_manifest.json    # stage: "discovery"; counts.sources_new vs sources_known_rechecked
```

The timestamp is UTC `YYYYMMDDTHHMMSSZ`. Prior runs are never overwritten.

State moves along the discovery path, roughly:
`pending → scoping → discovering → validating → review → ready_for_scrape`.
On success the location lands on `ready_for_scrape`; the definition of done is
coverage at or above target and run quality at or above threshold, or the
discovery budget exhausted (see `CLAUDE.md` and `docs/ARCHITECTURE.md`). The run
updates `last_run`, `next_due`, `coverage`, `quality_score`, `counts`, and
`latest_run` in the state store. Off-ramp states are `blocked` and `failed`.

## Run extraction for a location

```bash
/scrape us-tx-austin-msa
```

This runs the Lead Scraper (the `lead-extraction` skill). It is
**ledger-first**: it loads the verified sources for the location, tells each
scraper-worker which project labels are already known from its source, and
dedups every extracted lead against `leads/ledger.json` by `external_id`.
Only genuinely NEW leads are written and appended to the ledger — money is not
spent re-extracting leads already recorded.

```
output/us-tx-austin-msa/20260701T184158Z/
    leads.json          # wrapper of NEW Lead records (contract: lead.schema.json)
    run_manifest.json    # stage: "scrape"; counts.leads_new vs leads_duplicate
```

Only `verified` sources are consumed. Each lead is two-tier: a flat core (what a
BDM reads: organization, state/county, one-line summary, best evidence quote,
deep `source_url`) plus a nested `evidence` block with the extraction detail. A
lead whose confidence is below the review threshold, or that is missing a core
field, or whose sport is unconfirmed, carries `evidence.needs_review: true` so
it can be held for a human.

State moves `ready_for_scrape → scraped`, and `counts.leads`, `last_scraped`,
and `latest_scrape_run` are updated.

## Push to Supabase

The pipeline writes to local files; a separate step pushes those files into the
shared Supabase tables that the Retool BDM UI reads. Nothing in a run calls
Supabase — you run the sync yourself after discovery/scrape (or wire it in as a
post-run step later). The mapping from files to tables is in `docs/SCHEMAS.md`.

**One-time setup.** Create the tables and set credentials:

```bash
# 1. Create the tables: Supabase dashboard -> SQL editor -> paste and run:
sql/schema.sql            # safe to re-run (every statement is `if not exists`)

# 2. Credentials for the sync (Supabase dashboard -> Project Settings -> API):
cp sync/.env.example sync/.env    # then edit sync/.env
#   SUPABASE_URL=https://<project>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=<service-role key>   # secret; bypasses RLS
```

`sync/.env` is gitignored — never commit real credentials.

**Run the sync** from the repo root:

```bash
python3 sync/push_to_supabase.py --dry-run          # transform + print, no network
python3 sync/push_to_supabase.py                    # push everything
python3 sync/push_to_supabase.py --tables lead,source   # push a subset
```

`--dry-run` needs no credentials and prints a row count plus a sample row per
table — use it to sanity-check the transforms. Reading `search_area` uses
`pyyaml` (already a prerequisite above).

What the sync guarantees:

- **Idempotent.** Each table upserts on its stable key (`external_id`, `id`,
  `organization_id`, `location_id`, …), so re-running only refreshes rows.
- **Lifecycle-safe.** The lead columns a BDM edits in Retool (`status`,
  `rejected_reason`, `assigned_bdm`) are never sent, so those edits survive every
  re-sync. An upsert only touches the columns in the payload.
- **Run manifests.** It pushes every `run_manifest.json` under `output/`. Most
  run folders are gitignored, so on a fresh clone it typically finds only the
  tracked example run — that is expected.

Comparing a run against existing data before promoting it (a `staging_lead`
table + a diff) is planned but not built yet; see the "Staging layer" note in
`docs/SCHEMAS.md`. For now the sync upserts straight into the live tables, which
is safe for the reasons above.

## Check status

```bash
/status
```

This reads `locations/state.json` and prints the per-location work-queue view:
`status`, `coverage`, `quality_score`, `counts`, `last_discovered`,
`last_scraped`, and `next_due`, plus totals from the durable stores. Use it to
see which locations are due, which are `stale`, and which are `blocked` or
`failed`. "When did we last cover us-tx-austin-msa, and what did we get" is
answered here (state + the run manifests) without opening output files.

## Understand a run

Every run writes `run_manifest.json`. Read it to understand what happened.

```bash
cat output/us-tx-austin-msa/20260701T184158Z/run_manifest.json
```

The fields to look at:

- **`coverage`** — fraction of enumerated entities with at least one verified
  source. Low coverage means many entities were not covered.
- **`run_quality`** — aggregate per-source confidence. A run below threshold is
  flagged rather than shipped downstream.
- **`budget.stop_reason`** — why the goal loop ended: `goal_met` (the healthy
  case), or `diminishing_returns`, `max_iterations`, `budget_exhausted` (the run
  was capped or gave up short of the goal).
- **`failed_sources[]`** — sources that could not be validated or scraped, each
  with a `reason`. These are recorded, not silently dropped.
- **`gaps[]`** — entities that ended discovery with no confident source, and the
  `strategies_tried`. These are your follow-up targets.
- **`counts`** — `entities`, `sources_verified`, `sources_new`,
  `sources_known_rechecked`, `leads`, `leads_new`, `leads_duplicate`,
  `leads_needs_review`. A healthy re-run shows most sources under
  `sources_known_rechecked` and most leads under `leads_duplicate` — that is the
  registries doing their job.

Useful one-liners (require `jq`):

```bash
# Why did the loop stop, and how much did it cover?
jq '{stop: .budget.stop_reason, coverage, run_quality, counts}' \
  output/us-tx-austin-msa/20260701T184158Z/run_manifest.json

# Which entities came back empty, and what was tried?
jq '.gaps[]' output/us-tx-austin-msa/20260701T184158Z/run_manifest.json
```

## Re-run cadence and staleness

`next_due` is derived from the location's `cadence` (`weekly`, `monthly`,
`quarterly`). When the current time is past `next_due`, the location is due for
another discovery run; `/status` surfaces it, and its state may flip to `stale`.
A `stale` location has a last run older than its cadence window — re-run
`/discover` for it.

Because the ledger is deduped on content-derived `external_id`, a re-scrape's
`leads.json` already contains only what is new — the diff is done for you.
The same id is what makes the Supabase upsert idempotent.

```bash
# What did the latest scrape run add?
jq -r '.leads[].external_id + "  " + .leads[].summary' \
  output/us-tx-austin-msa/20260701T184158Z/leads.json

# How many leads have we ever recorded, per organization?
jq -r '.leads[].organization' leads/ledger.json | sort | uniq -c

# Which known sources cover a location, and when were they last checked?
jq -r '.sources[] | select(.location_ids | index("us-tx-austin-msa"))
       | .id + "  " + .last_checked + "  " + .url' sources/registry.json
```

## Handling blocked sources

Some aggregators are gated behind a login or render their listings with
JavaScript (for example DemandStar or BidNet). An unauthenticated fetch gets
nothing useful back. The pipeline records these rather than hiding them:

- The source does not reach `validation_status: verified` (it lands on
  `not_found`, `broken`, or similar) and is listed in the manifest's
  `failed_sources` with a reason.
- If discovery for a location is dominated by gated access, set that location's
  state to `blocked` and record why in `notes`, for example
  `"primary procurement portal is login-gated"`.

The action is to leave a clear note, plan an authenticated connector where
licensing allows, and treat the gated source as a known gap in the manifest
rather than a silent miss.

## Validate a file manually

To check a file against its contract without waiting for the hook:

```bash
# Using the repo hook script (it infers the contract from the file; accepts
# multiple paths):
python3 .claude/hooks/validate_schema.py \
  output/us-tx-austin-msa/20260701T184158Z/leads.json \
  sources/registry.json organizations/registry.json leads/ledger.json
```

`sources.json`, `leads.json`, and the durable stores are wrapper documents; the
hook checks the wrapper's `schema_version` and validates each inner record
against the per-record contract.

You can also use the `jsonschema` CLI directly against a single record:

```bash
# Validate one record against a contract
jsonschema -i one_lead.json contracts/lead.schema.json

# Validate every record in a wrapper file
jq -c '.leads[]' leads/ledger.json | while read -r rec; do
  echo "$rec" | jsonschema -i /dev/stdin contracts/lead.schema.json || echo "FAILED: $rec"
done
```

## Troubleshooting

**The hook did not fire.** Confirm `.claude/settings.json` registers
`validate_schema.py` as a PostToolUse hook and that it is invoked with `python3`.
Confirm the written path matches a path the hook recognizes as a contract file.
Run the validator manually (above) to check the file directly.

**A write was rejected by schema validation.** Read the validator error — it names
the failing record and field. Common causes:

- An unexpected or misspelled field. The contracts are strict
  (`additionalProperties: false`), so an extra key fails.
- An enum value that is not in the allowed set (for example a `status` or
  `source_type` typo).
- A pattern mismatch on `location_id`, a source `id`, or `run_timestamp`.
- A missing required field, or a `source_ids` array with fewer than one element.

Fix the record, not the schema. Changing a schema requires a version bump — see
the versioning rules in `docs/SCHEMAS.md`.

**"Validation skipped: dependency missing."** The hook could not import
`jsonschema` or `pyyaml` and skipped validation. Install them (see Prerequisites)
to restore enforcement.

**Empty results or low coverage.** Read `gaps` and `failed_sources` in the run
manifest to see which entities came back empty and why, then re-run `/discover`.
The discovery loop escalates its search strategy for entities that had no
confident source on the previous pass.
