---
name: source-discoverer
description: "Use this skill when the user wants to build a verified data source inventory for artificial turf lead generation in any US location. Triggers include: any request to find procurement sources, bid portals, bond programs, or capital improvement plans related to football, soccer, or baseball/softball turf fields for a specific city, county, metro area, or school district. Also triggers when the user says 'find turf leads', 'build a source list', 'monitor bids for turf', 'scrape turf opportunities', or references the lead scraper agent, turf data sources file, or GovSpend sync pipeline. Do NOT use for general web scraping, non-turf procurement, meeting agendas/minutes (handled by a separate workflow), or tasks unrelated to artificial turf field opportunities."
---

# Turf Lead Data Source Discovery

Build a verified, machine-readable inventory of public data sources for artificial turf lead generation, scoped to any user-specified US location.

## When to use

- User asks to find turf procurement sources for a city, county, metro, or school district
- User asks to build or update a `turf_lead_data_sources.md` file for a new region
- User wants to expand an existing source list to a new geography
- User asks to validate or re-verify URLs in an existing source list

## Required user input

The user **must** specify a geographic scope before this skill runs. Prompt if missing:

> Which location should I build the source list for? Give me one or more of:
> - A city (e.g. "Dallas, Texas")
> - A county (e.g. "Harris County, Texas")
> - A metro area (e.g. "San Antonio metro")
> - A school district (e.g. "Cy-Fair ISD")

The location determines which public entities are researched. The skill does not assume a default.

---

## Phase 1 — Scope the geography

From the user's location input, identify every public entity that could issue turf-related procurement or planning documents.

### Entity types to identify

| Entity type | What to find |
|---|---|
| School districts | Every ISD / CISD whose boundaries overlap the stated geography |
| Cities | Every incorporated city within the area |
| Counties | Every county that touches the area |
| Aggregators | Regional bid aggregators active in the state (BidNet, DemandStar, Bonfire, IonWave, etc.) |
| Cooperatives | Purchasing cooperatives the entities may use (BuyBoard, TASB, Choice Partners, TIPS/TAPS, etc.) |
| State portals | The state's central procurement portal if one exists (e.g. Texas ESBD) |

### How to build the entity list

1. **Web search** for `"[location] school districts map"`, `"cities in [county]"`, `"[metro area] counties"`.
2. For each school district found, confirm it exists by fetching its homepage.
3. For cities, confirm incorporation status; skip unincorporated CDPs unless they have their own procurement.
4. List every entity with its name, type, and confirmed homepage URL before proceeding.

---

## Phase 2 — Discover sources for each entity

For every entity from Phase 1, locate up to two source categories. Not every entity will have both.

> **Note:** Meeting agendas, board packets, and meeting minutes are excluded from this skill. Those are handled by a separate workflow.

### Source categories

**1. Procurement portals**
- Search the entity's website for: Purchasing, Bids, Solicitations, RFPs, Vendor Registration.
- Common URL patterns: `/purchasing/`, `/bids/`, `/departments/finance/purchasing/`, `/business/bids-rfps/`.
- Identify the underlying portal platform (Bonfire, IonWave, BidNet Direct, DemandStar, OpenGov, custom).
- Record the direct URL to the active-solicitations page, not the department landing page.

**2. Planning and funding documents**
- Bond program pages (especially school district bonds with athletics components).
- Capital Improvement Program (CIP) documents.
- Parks master plans.
- Athletic facility plans or stadium construction update pages.
- Search for: `site:[entity domain] bond`, `site:[entity domain] capital improvement`, `site:[entity domain] athletics`.

### Search strategy per entity

Run these searches in order. Stop when you have the best available URL for each source category.

```
"[entity name]" purchasing bids site:[entity domain]
"[entity name]" solicitations RFP site:[entity domain]
"[entity name]" bond program athletics
"[entity name]" capital improvement plan
"[entity name]" parks master plan
```

If the entity's own site yields nothing, search for the entity on known aggregator platforms:
```
"[entity name]" site:bidnetdirect.com
"[entity name]" site:demandstar.com
"[entity name]" site:bonfirehub.com
```

---

## Phase 3 — Validate every URL (loop until clean)

Every URL in the source list must be tested before inclusion. This is the verification loop.

### Validation procedure

```
REPEAT:
  For each source entry where status ≠ "verified":
    1. web_fetch the URL
    2. Check the HTTP response:
       - 200 with relevant content → mark "verified"
       - 200 but content is a generic homepage / login wall / empty page → mark "needs_redirect"
       - 301/302 redirect → follow redirect, record new URL, re-test
       - 403/404/5xx → mark "broken"
       - Timeout or unreachable → mark "retry" (up to 3 attempts)
    3. For "needs_redirect" entries:
       - Run a web_search to find the correct deep-link
       - Replace the URL and re-test
    4. For "broken" entries after 3 retries:
       - Run a web_search for an alternative URL
       - If found, replace and re-test
       - If no alternative exists, mark "not_found" and add a note
    5. For "verified" entries:
       - Confirm the page contains procurement or planning content
         (not just a staff directory or general "about" page)
       - If content is wrong, mark "needs_redirect" and loop again

  EXIT when every entry is either "verified" or "not_found"
```

### What counts as verified

The fetched page must contain at least one of these content indicators:

- Procurement: words like "bid", "solicitation", "RFP", "RFQ", "CSP", "proposal", "vendor", "purchasing"
- Planning/funding: words like "bond", "capital improvement", "CIP", "master plan", "project tracker"

If none of these appear, the URL is not verified even if it returns HTTP 200.

---

## Phase 4 — Classify each source

For every verified source, determine the following fields by reading the page content.

### Field definitions

| Field | How to determine |
|---|---|
| `id` | Auto-assign sequentially: SRC-001, SRC-002, … |
| `entity` | The public entity name (e.g. "Round Rock ISD", "City of Austin") |
| `entity_type` | One of: `school_district`, `city`, `county`, `state`, `cooperative`, `aggregator` |
| `source_type` | One of: `procurement`, `bond_program`, `cip`, `budget`, `parks_plan`, `athletic_facility_plan`, `construction_updates` |
| `name` | A short descriptive name for the source (e.g. "Purchasing / Bids (Bonfire)", "2024 Bond Tracker") |
| `url` | The verified direct URL |
| `contains` | Brief description of what the page actually contains, written from observation |
| `relevant_sports` | Array from: `[football, soccer, baseball_softball, multipurpose, needs_validation]` |
| `lead_stage` | Array from: `[early_planning, funding, active_bid, awarded, historical_reference]` |
| `searchability` | `good` (keyword search available), `medium` (browsable list), `poor` (PDF-only or minimal) |
| `monitor_frequency` | `weekly` (procurement portals), `monthly` (bond/CIP pages), `quarterly` (master plans) |
| `sport_confirmed` | `true` if the source explicitly names football, soccer, or baseball/softball fields; `false` if it says only "athletic fields" or "stadium" without naming a sport |

### Sport classification rules

- If the page mentions football, soccer, baseball, or softball explicitly → set `sport_confirmed: true` and list the sports.
- If the page mentions only "athletic fields", "stadium", or "sports complex" without naming a sport → set `sport_confirmed: false` and set `relevant_sports: [needs_validation]`.
- Procurement portals that list many bid types (not specific to athletics) → `sport_confirmed: false`, `relevant_sports: [needs_validation]`.
- Bond program pages that list specific stadium or field projects with sport names → `sport_confirmed: true`.

---

## Phase 5 — Write the output file

### Output format

Write a single markdown file named `turf_lead_data_sources.md` in the working directory. Follow this exact structure:

```markdown
# [Location Name] Artificial Turf Lead — Data Sources

Scope: Football, soccer, and baseball/softball artificial turf opportunities
in [full geographic description as confirmed in Phase 1].

Each source is listed with fields intended for programmatic consumption.
`sport_confirmed: false` means listings typically say "athletic fields" /
"stadium" without naming a sport, so the lead requires sport validation
against the keyword filters listed at the end of this file.

---

## Sources

### SRC-001
- id: SRC-001
- entity: [entity name]
- entity_type: [entity_type]
- source_type: [source_type]
- name: [name]
- url: [verified URL]
- contains: [what it contains]
- relevant_sports: [array]
- lead_stage: [array]
- searchability: [good/medium/poor]
- monitor_frequency: [weekly/monthly/quarterly]
- sport_confirmed: [true/false]

[... repeat for every source ...]

---

## Keyword Filters (for the extraction step)

[Include the standard keyword filter block — see below]
```

### Standard keyword filter block

Always append this block verbatim at the end of the output file. These keywords are not location-specific.

```
turf_keywords: ["artificial turf", "synthetic turf", "turf replacement",
"turf installation", "field turf", "synthetic surface", "turf field",
"field resurfacing", "infield turf", "synthetic infield"]

football_keywords: ["football field", "football stadium", "stadium turf",
"practice field", "high school stadium", "football field renovation",
"football field replacement"]

soccer_keywords: ["soccer field", "soccer complex", "soccer park",
"youth soccer", "soccer field renovation", "soccer field replacement",
"football/soccer field"]

baseball_softball_keywords: ["baseball field", "softball field",
"baseball complex", "softball complex", "baseball/softball complex",
"ballfield", "baseball turf", "softball turf", "baseball field renovation",
"softball field renovation"]

procurement_keywords: ["bid", "RFP", "RFQ", "CSP",
"competitive sealed proposal", "invitation to bid", "awarded contract",
"notice to bidders", "construction services", "CMAR",
"vendor registration", "bond", "capital improvement program", "CIP"]

exclusion_keywords: ["basketball", "tennis", "pickleball", "volleyball",
"lacrosse", "track only", "pool", "playground", "gym", "trail", "golf",
"skate park"]
```

---

## Phase 6 — Summary and priority ranking

After the source entries, append a priority ranking section.

### Priority ranking format

```markdown
## Priority Ranking

### Tier 1 — Monitor weekly
[List procurement portals and aggregators. For each:]
- **[Source name]** ([entity])
  - Why: [1-sentence reason]
  - Sports: [which sports]
  - Stage: [active_bid / awarded]
  - Alerts available: [yes/no — note if vendor registration enables alerts]

### Tier 2 — Monitor monthly
[List bond programs and CIPs. For each:]
- **[Source name]** ([entity])
  - Why: [1-sentence reason]
  - Sports: [which sports]
  - Stage: [early_planning / funding]

### Tier 3 — Monitor quarterly
[List master plans, budgets, historical references]
```

---

## Downstream compatibility

The output file is designed to be consumed by a lead scraper agent (see `lead_scraper_agent.md`). The agent reads each `### SRC-XXX` block, fetches the URL, applies the keyword filters, and extracts leads into a Salesforce-compatible JSON schema.

### Lead output schema (for reference — produced by the scraper, not this skill)

The scraper agent produces leads with these fields:

| Field | Description |
|---|---|
| `FirstName` | Point-of-contact first name |
| `LastName` | Point-of-contact last name |
| `Lead_Details__c` | Project summary: scope, sports, square footage, products needed |
| `Project_Address__c` | Project site address |
| `Phone` | Contact phone |
| `Projected_Start_Date__c` | Expected start date |
| `Title` | Contact job title |
| `Company` | Entity name (school district, city, county) |
| `Email` | Contact email |

This skill's job is to produce the **source list** that feeds that scraper. Keep the output format stable so the scraper can parse it without modification.

---

## Rules

- Only include official public sources. No paywalled or login-required portals unless the public listing page itself is accessible.
- Provide deep-linked URLs, not homepage links, whenever a more specific page exists.
- Do not fabricate sources. If a source cannot be found after reasonable searching, omit it and note the gap.
- Do not include unrelated sports. Exclude basketball, tennis, pickleball, volleyball, lacrosse, track-only, pools, playgrounds, gyms, trails, golf, and skate parks — unless the source also clearly covers football, soccer, or baseball/softball fields.
- If a source mentions only "athletic fields" without naming a sport, include it but set `sport_confirmed: false` and `relevant_sports: [needs_validation]`.
- Every URL must pass the Phase 3 validation loop before appearing in the final output.
- The verification loop must run to completion. Do not skip validation or output unverified URLs.
- If the user provides a very large geography (e.g. an entire state), suggest breaking it into metro areas or counties and running the skill once per sub-region.

---

## Execution checklist

Use this to track progress during a run:

```
[ ] User specified location
[ ] Phase 1: Entity list complete (all school districts, cities, counties identified)
[ ] Phase 2: Source discovery complete (procurement portals and planning/funding docs found per entity)
[ ] Phase 3: URL validation loop — all entries verified or marked not_found
[ ] Phase 4: Classification complete (all fields populated)
[ ] Phase 5: Output file written to /mnt/user-data/outputs/turf_lead_data_sources.md
[ ] Phase 6: Priority ranking appended
[ ] File presented to user
```
