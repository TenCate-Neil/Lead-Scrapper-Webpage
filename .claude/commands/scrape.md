---
description: Extract turf leads for a location from its verified sources.json.
argument-hint: <location_id>
---
Extract turf leads for location_id `$ARGUMENTS`.

First, confirm a ready-for-scrape inventory exists. REFUSE and stop if either
condition fails:
- the location's `status` in `locations/state.json` is not `ready_for_scrape`
  (or a later state such as `scraped`), OR
- no `output/$ARGUMENTS/<latest-run>/sources.json` exists with at least one
  source whose `validation_status` is `"verified"`.

If refusing, explain what is missing and suggest running `/discover $ARGUMENTS`
first.

Otherwise, invoke the `lead-extraction` skill for `$ARGUMENTS`: fan out one
scraper-worker per verified source, consolidate, dedup by `external_id`, and
write output to `output/$ARGUMENTS/<run-timestamp>/leads.json`.

When done, report: leads found, leads flagged `needs_review`, and any
`failed_sources` with their reasons.
