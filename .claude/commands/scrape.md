---
description: Extract turf leads for a location from its verified source inventory.
argument-hint: <location_id>
---
Extract turf leads for location_id `$ARGUMENTS`.

First, confirm a ready-for-scrape inventory exists. REFUSE and stop if either
condition fails:
- the location's `status` in `locations/state.json` is not `ready_for_scrape`
  (or a later state such as `scraped`), OR
- no verified source covers `$ARGUMENTS` — check `sources/registry.json`
  (entries whose `location_ids` include the slug with
  `validation_status: "verified"`) and the latest
  `output/$ARGUMENTS/<latest-run>/sources.json`.

If refusing, explain what is missing and suggest running `/discover $ARGUMENTS`
first.

Otherwise, invoke the `lead-extraction` skill for `$ARGUMENTS`: fan out one
scraper-worker per verified source (each told which project labels are already
known so it skips them), consolidate, dedup by `external_id` against
`leads/ledger.json`, write only NEW leads to
`output/$ARGUMENTS/<run-timestamp>/leads.json`, and append them to the ledger.

When done, report: leads found (new vs already-known duplicates), leads flagged
`needs_review`, and any `failed_sources` with their reasons.
