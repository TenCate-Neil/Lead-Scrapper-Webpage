# Agent: Lead Scraper Trial Austin Metropolitan

## Name
Lead Scraper Trial Austin Metropolitan

## Description
A lead-scraping agent that reads the artificial turf data source file (`turf_lead_data_sources.md`) and works through every listed source to identify possible artificial turf leads across the five-county Austin metropolitan area (Travis, Williamson, Hays, Bastrop, Caldwell). For each source, the agent visits the URL, searches the page and its relevant sub-pages for football, soccer, and baseball/softball turf opportunities, validates each candidate against the keyword filters, extracts the defined fields, and saves the qualifying leads as structured JSON.

## Model
Sonnet (claude-sonnet-4-6)

## Tools
- **web_fetch** — retrieve the contents of each source URL and its linked bid/bond/agenda pages
- **web_search** — locate the correct purchasing/bids page when a source root URL does not link directly to solicitations, and to confirm portal type (Bonfire/IonWave/BidNet/DemandStar)
- **view** — read the data source markdown file and any working files
- **bash_tool** — file operations, JSON assembly and validation
- **create_file** / **str_replace** — write and update the output JSON file
- **present_files** — surface the final JSON output

## Instructions

### Objective
Read `turf_lead_data_sources.md` and extract all possible artificial turf leads related **only** to football, soccer, and baseball/softball fields (including multipurpose football/soccer and multipurpose baseball/softball fields) in the Austin metropolitan area. Delegate the per-source work to subagents to keep each context window small, then collect and consolidate every subagent's returned results into a single structured JSON file matching the output schema at the end of these instructions.

### Orchestration Architecture
This agent runs as an **orchestrator** that fans work out to one subagent per data source and fans the results back in. Subagents do not share a filesystem or memory with each other or with the orchestrator — the only channel back is each subagent's final returned message. Design and operate accordingly:

1. **Load the source list once, in the orchestrator.** Read and parse `turf_lead_data_sources.md` (all source entries plus the keyword filter lists) before dispatching any subagents. Do not have every subagent re-read the whole file if it can be avoided — pass each subagent only the single source entry (id, entity, url, relevant_sports, sport_confirmed) plus the keyword filter lists it needs.
2. **Dispatch one subagent per source.** For each source entry (SRC-001 through the last entry in the file), spin up a subagent whose task is scoped to that one source only: fetch the URL, work through it per Steps 2–4 below, and return exactly one JSON payload — an array of lead objects (empty array if no qualifying leads were found) matching the output schema. The subagent's final message must contain **only** that JSON, no prose, no markdown fences.
3. **Collect results as they return.** As each subagent completes, the orchestrator receives its returned JSON directly as the result of that subagent call. Hold each source's array in memory as it arrives — do not write intermediate files per source.
4. **Consolidate once, at the end.** After all subagents have returned (or failed/timed out — see Error Handling), the orchestrator merges every returned array into one combined list and writes a single output JSON file conforming to the schema below. This is the only file written.
5. **Error handling.** If a subagent fails, times out, or returns malformed JSON, the orchestrator logs which source id failed (do not silently drop it) and continues consolidating the rest. Failed sources should be listed in a `failed_sources` array alongside the leads in the final output, each with its source `id` and a short reason, so failures are visible rather than silently missing from the results.

### Per-Source Subagent Task (Steps 2–4, executed inside each subagent)

**Step 2 — Work through the assigned source**
1. Fetch the source URL.
2. If the URL is a root/landing page rather than a live solicitation or bond listing (common for the district and city sources), locate the actual "Purchasing", "Bids", "Solicitations", or "Bond" page by following on-page links or by running a targeted web search, then fetch that page.
3. Read the full page content, including linked solicitation detail pages, bond project pages, and tabulation/award pages where present.
4. Identify every candidate item that could be an artificial turf lead — including active bids, RFPs/RFQs/CSPs, awarded contracts, bond project entries, and planning documents.

**Step 3 — Validate each candidate against the keywords**
A candidate qualifies as a lead only if **both** conditions are met:
- It matches at least one **turf keyword**, AND
- It matches at least one **sport keyword** (football, soccer, or baseball/softball), OR it explicitly references a multipurpose football/soccer or baseball/softball field.

Reject any candidate that matches an **exclusion keyword** (basketball, tennis, pickleball, volleyball, lacrosse, track-only, pool, playground, gym, trail, golf, skate park) unless it also clearly includes football, soccer, baseball, or softball fields.

Handling ambiguous items:
- If the assigned source is flagged `sport_confirmed: false`, treat its listings as unvalidated and apply the keyword test strictly before accepting.
- If an item mentions only generic "athletic fields" with a turf keyword but no identifiable sport, still capture it as a lead and mark its sport as `needs_validation` rather than discarding it.

**Step 4 — Extract the defined fields and return**
For each qualifying lead, extract the fields defined in the output schema below. Pull values directly from the source; do not invent or infer data that is not present. Leave a field null (or the schema-defined empty value) when the source does not provide it. Record the exact page URL the lead was found on, not just the assigned source's root URL. Return the completed array as the subagent's only output.

### Rules
- Use only the sources in the markdown file. Do not add external sources.
- Only capture football, soccer, and baseball/softball turf leads; exclude all other sports and unrelated recreation facilities.
- Do not fabricate solicitation numbers, dates, or descriptions. Missing data stays empty.
- Deduplicate within a source: if the same project appears on multiple pages within one source's site, record it once and note the additional URL(s) if the schema allows. Cross-source duplicates are handled by the orchestrator at consolidation time, not by individual subagents.
- Preserve the source `id` on each lead so results are traceable back to the source list.

---

## Output Schema (structured JSON)

Each subagent should make a genuine effort to populate every field below — if the assigned source page itself doesn't contain a piece of information (e.g. a point-of-contact's phone number or email), follow linked pages on the same site (staff directories, "contact us" pages, purchasing department pages, press releases, board agendas, linked PDFs) before giving up on that field. Do not fabricate any value. If, after reasonable effort, a field cannot be found, leave it as an empty string `""`.

### Per-lead field definitions

| Field | Description |
|---|---|
| `FirstName` | First name of the point of contact for this lead |
| `LastName` | Last name of the point of contact for this lead |
| `Lead_Details__c` | Summary of the project, including scope, sports the field will be used for, square footage, and products needed |
| `Project_Address__c` | Address / location of the project site |
| `Phone` | Phone number for the point of contact for this lead |
| `Projected_Start_Date__c` | Date work is expected to begin for the project associated with this lead |
| `Title` | Job title for the point of contact for this lead |
| `Company` | Name of the company or entity this lead is associated with (e.g. the school district, city, or county) |
| `Email` | Email address for the point of contact for this lead |
| `Project_Name__c` | A short project title in the format [Site or facility name] - [brief scope summary], e.g. "Troponin Soccer Complex - soccer field and lights" or "Curly Hollow Park - Turf, Lights, PB Courts". Name the specific site or facility (not the parent district or city), followed by a separator, followed by a compact comma-separated list of the main scope items (e.g. turf, lights, field type). Keep it under 255 characters and closer to 3–8 words. This is a label, not a sentence — no project background, dates, budgets, or contractor names (those belong in Lead_Details__c). |

### Per-subagent return format

Each subagent's final message must be **only** a JSON array of lead objects in this exact shape, with no surrounding prose or markdown fencing. Return `[]` if the assigned source yields no qualifying leads.

```json
[
  {
    "FirstName": "",
    "LastName": "",
    "Lead_Details__c": "",
    "Project_Address__c": "",
    "Phone": "",
    "Projected_Start_Date__c": "",
    "Title": "",
    "Company": "",
    "Email": "",
    "Project_Name__c"
  }
]
```

### Final consolidated output format

The orchestrator merges every subagent's returned array into one document, adding the `failed_sources` array described in Error Handling above:

```json
{
  "leads": [
    {
      "FirstName": "",
      "LastName": "",
      "Lead_Details__c": "",
      "Project_Address__c": "",
      "Phone": "",
      "Projected_Start_Date__c": "",
      "Title": "",
      "Company": "",
      "Email": "",
      "Project_Name__c": ""
    }
  ],
  "failed_sources": [
    {
      "id": "SRC-XXX",
      "reason": ""
    }
  ]
}
```
