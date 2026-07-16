---
description: Run turf source-discovery for a location_id from the registry.
argument-hint: <location_id>
---
Run source discovery for location_id `$ARGUMENTS`.

First, confirm `$ARGUMENTS` is a real location in `locations/registry.yaml`. If it
is empty, malformed, or not present in the registry, REFUSE: print the valid
location_ids from the registry and stop without running discovery.

Otherwise, delegate the run to the `discovery-coordinator` sub-agent (Task tool),
passing `$ARGUMENTS`. It runs the full `source-discovery` loop in its own context
so the main session stays lean, then returns a compact summary. The run is
registry-first: known sources in `sources/registry.json` are re-checked before
any new web search, and web discovery only tops up gaps. The coordinator runs the
full goal loop (scope, recheck, discover, validate, review, refine) to its exit
condition, writes output to `output/$ARGUMENTS/<run-timestamp>/`, and upserts the
source and organization registries along the way.

When done, report: coverage, run_quality, entities enumerated, sources verified
(split into known-rechecked vs newly discovered), `budget.stop_reason`, and any
entities left in the gap report. State whether the location reached
`ready_for_scrape`.
