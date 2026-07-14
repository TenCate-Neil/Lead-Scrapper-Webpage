---
description: Run turf source-discovery for a location_id from the registry.
argument-hint: <location_id>
---
Run source discovery for location_id `$ARGUMENTS`.

First, confirm `$ARGUMENTS` is a real location in `locations/registry.yaml`. If it
is empty, malformed, or not present in the registry, REFUSE: print the valid
location_ids from the registry and stop without running discovery.

Otherwise, invoke the `source-discovery` skill for `$ARGUMENTS`. It is
registry-first: known sources in `sources/registry.json` are re-checked before
any new web search, and web discovery only tops up gaps. Run the full goal loop
(scope, recheck, discover, validate, review, refine) to its exit condition and
write output to `output/$ARGUMENTS/<run-timestamp>/`, upserting the source and
organization registries along the way.

When done, report: coverage, run_quality, entities enumerated, sources verified
(split into known-rechecked vs newly discovered), `budget.stop_reason`, and any
entities left in the gap report. State whether the location reached
`ready_for_scrape`.
