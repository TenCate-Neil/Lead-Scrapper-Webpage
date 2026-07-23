-- ============================================================================
-- Turf Lead Pipeline — STAGING schema  (Supabase / Postgres)
-- ============================================================================
-- Role: LANDING ZONE + TRIAGE + ENTITY RESOLUTION.
--
-- This is the project both scrape pipelines write to (web-search agent via
-- Claude Code, meeting-minutes workflow via GitHub Actions). Nothing here is a
-- system of record for sales work. The only human decisions made against this
-- database are TRIAGE decisions (is this real? which opportunity is it about?),
-- expressed as `review_status` and `lead_id` on lead_entry.
--
-- What lives here and why:
--   * Reference/registry tables (search_area, organization, source, run, ...)
--     are unchanged from the original single-DB schema. They are shared PIPELINE
--     INPUTS, not lifecycle data, so they belong on the write side.
--   * `lead_entry` is one row per SCRAPE (what the pipelines actually produce).
--     This replaces the old single `lead` table on the ingestion side.
--   * `lead` here is thin: one row per RESOLVED opportunity, created by the
--     dedup/entity-resolution step so that entries have something to attach to.
--   * `review_status` (triage) lives ONLY here. `lifecycle_status` does NOT
--     exist in this database — that field is owned exclusively by production.
--
-- What is deliberately absent:
--   * No sales lifecycle (New/Contacted/Opportunity...). That is production's.
--   * No assigned_bdm, no status log. Triage only.
--
-- `create table if not exists` makes this file safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- SECTION A — Reference / registry tables (shared pipeline inputs)
-- Unchanged from the original schema. These feed discovery + scraping.
-- ----------------------------------------------------------------------------

-- A1. search_area  <- locations/registry.yaml
create table if not exists search_area (
    location_id      text primary key
                     check (location_id ~ '^us-[a-z]{2}-[a-z0-9-]+$'),
    name             text not null,
    type             text not null check (type in ('city','county','metro','district','state')),
    priority         text check (priority in ('high','medium','low')),
    cadence          text check (cadence in ('weekly','monthly','quarterly')),
    coverage_target  numeric check (coverage_target between 0 and 1),
    scope            jsonb,
    tags             text[],
    added_date       date,
    schema_version   text,
    synced_at        timestamptz not null default now()
);

-- A2. organization  <- organizations/registry.json
--     This is also the BLOCKING KEY for entity resolution: a new entry is only
--     ever compared against existing leads for the SAME organization_id.
create table if not exists organization (
    organization_id  text primary key check (organization_id ~ '^[a-z0-9-]+$'),
    name             text not null,
    type             text not null check (type in
                        ('school_district','city','county','university','college','state_agency','other')),
    website          text,
    state            text not null check (state ~ '^[A-Z]{2}$'),
    primary_county   text not null,
    location_ids     text[],
    first_seen       timestamptz,
    notes            text,
    synced_at        timestamptz not null default now()
);

-- A3. organization_geography  <- organization.geography[]
create table if not exists organization_geography (
    organization_id  text not null references organization(organization_id) on delete cascade,
    kind             text not null check (kind in ('county','place')),
    value            text not null,
    primary key (organization_id, kind, value)
);

-- A4. source  <- sources/registry.json
create table if not exists source (
    id                text primary key check (id ~ '^SRC-[0-9]{3,}$'),
    location_id       text not null,
    location_ids      text[],
    entity            text not null,
    entity_type       text not null check (entity_type in
                         ('school_district','city','county','state','cooperative','aggregator')),
    source_type       text not null check (source_type in
                         ('procurement','bond_program','cip','budget','parks_plan',
                          'athletic_facility_plan','construction_updates')),
    name              text not null,
    url               text not null,
    normalized_url    text unique,
    contains          text,
    relevant_sports   text[],
    lead_stage        text[],
    searchability     text check (searchability in ('good','medium','poor')),
    monitor_frequency text check (monitor_frequency in ('weekly','monthly','quarterly')),
    sport_confirmed   boolean not null,
    validation_status text not null check (validation_status in
                         ('verified','needs_redirect','broken','retry','not_found')),
    validation_tier   text[],
    confidence        numeric check (confidence between 0 and 1),
    reviewed          boolean,
    last_validated    timestamptz,
    first_seen        timestamptz,
    last_checked      timestamptz,
    last_result       text,
    synced_at         timestamptz not null default now()
);
create index if not exists source_location_id_idx on source (location_id);

-- A5. run  <- output/**/run_manifest.json
create table if not exists run (
    location_id     text not null,
    run_timestamp   text not null check (run_timestamp ~ '^[0-9]{8}T[0-9]{6}Z$'),
    stage           text not null check (stage in ('discovery','scrape')),
    agent_versions  jsonb,
    counts          jsonb,
    coverage        numeric,
    run_quality     numeric,
    budget          jsonb,
    failed_sources  jsonb,
    gaps            jsonb,
    schema_version  text,
    synced_at       timestamptz not null default now(),
    primary key (location_id, run_timestamp)
);

-- A6. location_state  <- locations/state.json
create table if not exists location_state (
    location_id          text primary key references search_area(location_id) on delete cascade,
    status               text not null check (status in
                            ('pending','scoping','discovering','validating','review',
                             'ready_for_scrape','scraped','stale','blocked','failed')),
    last_run             timestamptz,
    next_due             timestamptz,
    coverage             numeric,
    quality_score        numeric,
    counts               jsonb,
    latest_run           text,
    last_discovered      timestamptz,
    last_scraped         timestamptz,
    latest_discovery_run text,
    latest_scrape_run    text,
    lease                jsonb,
    notes                text,
    schema_version       text,
    synced_at            timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- SECTION B — Entity resolution layer  (the new part)
-- ----------------------------------------------------------------------------

-- B1. lead  — one row per RESOLVED opportunity (thin, staging-side).
--     Created by the dedup/entity-resolution step. Its only job here is to give
--     lead_entry rows a stable parent to attach to. It carries NO lifecycle
--     state — the corresponding production.lead owns that.
--
--     dedup_key is the natural key used for record linkage and for the
--     promotion upsert into production. It is assigned by the RESOLUTION step,
--     never the scraper. Build it from normalized fields — hash of
--     organization_id + normalized project descriptor, deliberately NO URL
--     (the two pipelines find the same opportunity at different URLs) — so the
--     same opportunity always hashes to the same key across runs and pipelines.
create table if not exists lead (
    lead_id          text primary key check (char_length(lead_id) >= 8),
    organization_id  text references organization(organization_id) on delete set null,
    dedup_key        text not null unique,
    project_summary  text not null default '' check (char_length(project_summary) <= 400),
    -- denormalized from entries by resolution ('' until resolved)
    lead_value_estimation text,
    state            text not null default ''
                     check (state = '' or state ~ '^[A-Z]{2}$'),
    county           text not null default '',
    location_id      text,
    first_seen       timestamptz not null default now(),
    last_seen        timestamptz not null default now(),
    -- Promotion bookkeeping: set once this resolved lead has been pushed to prod.
    promoted_at      timestamptz,
    synced_at        timestamptz not null default now()
);
create index if not exists lead_org_idx        on lead (organization_id);
create index if not exists lead_promoted_idx   on lead (promoted_at);

-- B2. lead_entry  — one row per SCRAPE. What the two pipelines actually write.
--     This is the old `lead` table on the ingestion side, minus lifecycle.
--
--     Flow of the two key columns:
--       lead_id       null on arrival; set by intra-batch dedup + the agent
--                     (or a BDM in the triage tab). null after processing = the
--                     agent was not confident -> shows in the triage queue.
--       review_status pending on arrival; a BDM sets accepted / rejected.
--                     A rejected entry stays here forever (never promoted) and
--                     is checked against so the same mention doesn't re-surface.
--     entry_id reuses the pipelines' content-derived external_id (hash of
--     organization + project label + source_url) — already one id per mention.
create table if not exists lead_entry (
    entry_id        text primary key check (char_length(entry_id) >= 8),
    source          text not null check (source in ('web-search','meeting-minutes')),

    -- Resolution: which opportunity is this entry about?
    lead_id         text references lead(lead_id) on delete set null,
    observation_type text check (observation_type in ('new','update','result')),
    match_confidence numeric check (match_confidence between 0 and 1),

    -- Blocking / linkage context.
    organization    text not null,
    organization_id text references organization(organization_id) on delete set null,
    state           text not null check (state ~ '^[A-Z]{2}$'),
    county          text not null default '',
    location_id     text,

    -- The scraped payload.
    summary         text not null check (char_length(summary) <= 400),
    evidence_quote  text not null default '',
    source_url      text not null,
    normalized_url  text,               -- helps intra-batch dedup across pipelines
    discovered_at   timestamptz not null,
    bid_due_date    date,
    -- estimated project value: amount/range from the source, or 'uncertain'/'unknown'
    lead_value_estimation text,
    evidence        jsonb,

    -- Triage state (STAGING-ONLY — no lifecycle here).
    review_status   text not null default 'pending'
                    check (review_status in ('pending','accepted','rejected')),
    rejected_reason text,
    reviewed_by     text,
    reviewed_at     timestamptz,

    created_at      timestamptz not null default now(),
    synced_at       timestamptz not null default now(),

    -- A rejected entry must carry a reason.
    constraint entry_rejected_needs_reason
        check (review_status <> 'rejected' or coalesce(rejected_reason,'') <> ''),
    -- An accepted entry must be resolved to a lead before it can be promoted.
    constraint entry_accepted_needs_lead
        check (review_status <> 'accepted' or lead_id is not null)
);
create index if not exists entry_review_status_idx on lead_entry (review_status);
create index if not exists entry_org_idx           on lead_entry (organization_id);
create index if not exists entry_lead_id_idx       on lead_entry (lead_id);
create index if not exists entry_source_idx        on lead_entry (source);
-- Supports the promotion job's "what's ready and not yet promoted" scan.
create index if not exists entry_promote_ready_idx
    on lead_entry (review_status, lead_id)
    where review_status = 'accepted';
