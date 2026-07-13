---
description: Show pipeline status, coverage, and cadence for every location.
---
Print a status overview for the whole pipeline.

Read `locations/state.json` and `locations/registry.yaml`. If `state.json` is
missing or empty, say so and list every registry location as effectively
`pending`.

Render one table with a row per location:

| location_id | status | coverage | quality | last_run | next_due |

- `coverage` and `quality` come from state (`coverage` and `quality_score`).
  Show them as percentages; show `—` when null.
- `last_run` and `next_due` come from state; show `—` when null.
- Sort by registry `priority` (high first), then by `next_due` ascending.

After the table, highlight:
- DUE NOW — locations whose `next_due` is on or before today, or whose `status`
  is `stale` or `pending`.
- BLOCKED / FAILED — locations with `status` `blocked` or `failed`; include the
  `notes` field so the reason is visible.

Use today's actual date to decide what is due. Do not modify any file.
