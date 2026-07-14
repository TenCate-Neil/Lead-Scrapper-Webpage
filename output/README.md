# output/

Generated run artifacts produced by the pipeline stages. Each discovery or
scrape run writes into its own timestamped folder, so runs never overwrite one
another and stay comparable and auditable.

## Layout

```
output/<location_id>/<run-timestamp>/
    sources.json        # verified sources this run (contract: contracts/source.schema.json)
    leads.json          # NEW leads this run        (contract: contracts/lead.schema.json)
    run_manifest.json   # per-run metadata           (contract: contracts/run_manifest.schema.json)
```

Run folders are point-in-time snapshots. The durable stores live outside
`output/`: `sources/registry.json` (all sources ever found),
`organizations/registry.json` (entities), and `leads/ledger.json` (all leads
ever recorded — a run's `leads.json` holds only what that run added).

- `location_id` is the stable slug from `locations/registry.yaml`, e.g.
  `us-tx-austin-msa`.
- `<run-timestamp>` is UTC `YYYYMMDDTHHMMSSZ`, e.g. `20260701T184158Z`.

## Not committed

These artifacts are large and append-only, so they are normally gitignored (see
the repo `.gitignore`) and archived in object storage rather than kept in git
history.

## Tracked example run

One run is checked in as a worked example of the layout:

```
output/us-tx-austin-msa/20260701T184158Z/
```

It was backfilled/migrated from an earlier flat output file
(`austin_turf_leads_20260701T184158Z.json`) into the per-location/per-run
structure above. Because it is a legacy backfill, some fields could not be
recomputed (for example `coverage` and `run_quality` were not measured), and
`run_manifest.json` records a gap: the leads trace to a wider set of source ids
than the four source records preserved in `sources.json`. See that run's
`run_manifest.json` for details. The run has since been migrated to the v2
two-tier lead shape (external_ids preserved); its `evidence_quote` fields are
empty because the legacy run kept no verbatim quotes.
