# Operator Runbook (RUNBOOK.md)

This guide is for operators running the turf-lead pipeline: adding locations,
running discovery and extraction, reading run output, and handling the common
failure modes. It is practical and example-driven; the running example is the
Austin metro location, `us-tx-austin-msa`.

For the design, read `docs/ARCHITECTURE.md`. For the field-level data contracts
and the Salesforce mapping, read `docs/SCHEMAS.md`. For the directory map, read
`CLAUDE.md`.

The pipeline has two stages joined by shared storage and the location state
machine. The Source Finder discovers and validates sources; the Lead Scraper
reads those sources and extracts leads. Neither stage calls the other directly.

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

This runs the Source Finder (the `source-discovery` skill). It enumerates the
public entities in the location, discovers candidate procurement and planning
sources, validates each URL (live, relevant, fresh, sport-confirmed), scores and
reviews them, and repeats until it meets its coverage and quality target or hits
a budget cap.

Output lands in a new timestamped run folder:

```
output/us-tx-austin-msa/20260701T184158Z/
    sources.json        # array of Source records (contract: source.schema.json)
    run_manifest.json    # stage: "discovery"
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

This runs the Lead Scraper (the `lead-extraction` skill). It reads the latest
`sources.json` for the location (via the `latest_run` pointer in state), extracts
leads, and writes:

```
output/us-tx-austin-msa/20260701T184158Z/
    leads.json          # array of Lead records (contract: lead.schema.json)
    run_manifest.json    # stage: "scrape"
```

Only `verified` sources are consumed. A lead whose confidence is below the review
threshold, or that is missing a required field, or whose sport is unconfirmed, is
written with `needs_review: true` so it can be held for a human before Salesforce.

State moves `ready_for_scrape → scraped`, and `counts.leads` is updated.

## Check status

```bash
/status
```

This reads `locations/state.json` and prints the per-location work-queue view:
`status`, `coverage`, `quality_score`, `counts`, `last_run`, `next_due`, and
`latest_run`. Use it to see which locations are due, which are `stale`, and which
are `blocked` or `failed`.

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
- **`counts`** — `entities`, `sources_verified`, `leads`, `leads_needs_review`.

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

Because each run writes a new timestamped folder and never overwrites a prior one,
you can diff runs to surface only what changed. Leads are keyed on `external_id`,
which is content-derived: an unchanged project produces the same id across runs,
so a diff by `external_id` shows genuinely new or changed leads and nothing else.
This is also what makes the Salesforce upsert idempotent.

```bash
# New/changed lead ids in the current run vs. the previous run
comm -13 \
  <(jq -r '.[].external_id' output/us-tx-austin-msa/20260601T090000Z/leads.json | sort) \
  <(jq -r '.[].external_id' output/us-tx-austin-msa/20260701T184158Z/leads.json | sort)
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
# Using the repo hook script (it infers the contract from the file):
python3 .claude/hooks/validate_schema.py output/us-tx-austin-msa/20260701T184158Z/leads.json
```

`sources.json` and `leads.json` are arrays, so each element is validated against
the per-record contract.

You can also use the `jsonschema` CLI directly against a single record:

```bash
# Validate one record against a contract
jsonschema -i one_lead.json contracts/lead.schema.json
```

To validate every element of an array file with the CLI, loop over the elements:

```bash
jq -c '.[]' output/us-tx-austin-msa/20260701T184158Z/leads.json | while read -r rec; do
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
