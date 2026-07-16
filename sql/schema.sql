-- Turf Lead Pipeline — Supabase (Postgres) schema
-- ============================================================================
-- This DDL implements the "Supabase mapping" table in docs/SCHEMAS.md. Each
-- table mirrors a data contract in contracts/ and the durable JSON store that
-- is its local mirror. Run it once against your Supabase project (SQL editor or
-- `psql`), then push data with sync/push_to_supabase.py.
--
-- Design notes:
--   * Enums are modelled as text + CHECK constraints (not Postgres ENUM types)
--     so that adding an allowed value — an additive, backward-compatible change
--     per docs/SCHEMAS.md — is a one-line ALTER instead of an ENUM migration.
--   * The nested lead `evidence` block is a single JSONB column, not a separate
--     table: it is detail-on-demand, never queried in the BDM grid.
--   * Upsert keys match the durable stores' dedup keys: external_id (lead),
--     id (source, also unique on normalized_url), organization_id, location_id,
--     (location_id, run_timestamp). Re-syncing is idempotent.
--   * Lifecycle columns on `lead` (status, rejected_reason, assigned_bdm) are
--     Supabase-only mutable UI state. The pipeline sync never writes them, so a
--     BDM's edits in Retool survive every re-sync (see sync/push_to_supabase.py).
--   * Row Level Security is intentionally NOT configured here. service_role (used
--     by the sync and, typically, Retool) bypasses RLS. Add policies before you
--     expose any table through the anon/public key.
--
-- `create table if not exists` makes this file safe to re-run.
-- ============================================================================

-- 1. search_area  <- locations/registry.yaml  (contract: location.schema.json)
create table if not exists search_area (
    location_id      text primary key
                     check (location_id ~ '^us-[a-z]{2}-[a-z0-9-]+$'),
    name             text not null,
    type             text not null check (type in ('city','county','metro','district','state')),
    priority         text check (priority in ('high','medium','low')),
    cadence          text check (cadence in ('weekly','monthly','quarterly')),
    coverage_target  numeric check (coverage_target between 0 and 1),
    scope            jsonb,          -- counties / state / parent
    tags             text[],
    added_date       date,
    schema_version   text,
    synced_at        timestamptz not null default now()
);

-- 2. organization  <- organizations/registry.json  (contract: organization.schema.json)
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

-- 3. organization_geography  <- organization.geography[]  (many-to-many coverage)
--    Composite natural key = the upsert target. Geography only grows in practice
--    (docs/SCHEMAS.md: "filled opportunistically"), so upsert-on-conflict is enough;
--    a removed coverage row upstream would leave a stale row here, which is acceptable.
create table if not exists organization_geography (
    organization_id  text not null references organization(organization_id) on delete cascade,
    kind             text not null check (kind in ('county','place')),
    value            text not null,
    primary key (organization_id, kind, value)
);

-- 4. source  <- sources/registry.json  (contract: source.schema.json)
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
    normalized_url    text unique,   -- dedup key from the durable registry
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

-- 5. lead  <- leads/ledger.json + run leads.json  (contract: lead.schema.json)
--    Core columns are written by the pipeline sync. The lifecycle columns below
--    the divider are Supabase-only and are never touched by the sync.
create table if not exists lead (
    external_id     text primary key check (char_length(external_id) >= 8),
    source          text not null check (source in ('web-search','meeting-minutes')),
    organization    text not null,
    organization_id text references organization(organization_id) on delete set null,
    state           text not null check (state ~ '^[A-Z]{2}$'),
    county          text not null default '',
    summary         text not null check (char_length(summary) <= 400),
    evidence_quote  text not null default '',
    source_url      text not null,
    discovered_at   timestamptz not null,
    location_id     text,
    evidence        jsonb,          -- the optional detail tier, verbatim

    -- ---- Supabase-only lifecycle state (managed in Retool, not by the sync) ----
    status          text not null default 'New'
                    check (status in ('New','Reviewing','Qualified','Contacted','Opportunity','Rejected')),
    rejected_reason text,
    assigned_bdm    text,
    created_at      timestamptz not null default now(),
    synced_at       timestamptz not null default now(),

    -- A rejected lead must carry a reason (docs/SCHEMAS.md lifecycle rule).
    constraint lead_rejected_needs_reason
        check (status <> 'Rejected' or coalesce(rejected_reason, '') <> '')
);
create index if not exists lead_source_idx        on lead (source);        -- pipeline comparison
create index if not exists lead_status_idx        on lead (status);
create index if not exists lead_location_id_idx   on lead (location_id);
create index if not exists lead_organization_idx  on lead (organization_id);

-- 6. lead_status_log  (Supabase-only)  — the audit trail that makes the
--    3-month trial quantifiable per source pipeline: when each lead moved
--    between lifecycle stages. Populated automatically by the trigger below.
create table if not exists lead_status_log (
    id           bigint generated always as identity primary key,
    external_id  text not null references lead(external_id) on delete cascade,
    from_status  text,
    to_status    text not null,
    changed_by   text,          -- set by the app (Retool) when known; else NULL
    reason       text,
    changed_at   timestamptz not null default now()
);
create index if not exists lead_status_log_external_id_idx on lead_status_log (external_id);

-- 7. run  <- output/**/run_manifest.json  (contract: run_manifest.schema.json)
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

-- 8. location_state  <- locations/state.json  (contract: location_state.schema.json)
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

-- ---------------------------------------------------------------------------
-- Automatic status-change logging. Every time a lead's status changes, record
-- the transition so time-in-stage can be measured per pipeline (lead.source).
-- The app can also insert richer rows directly (e.g. with changed_by set).
-- ---------------------------------------------------------------------------
create or replace function log_lead_status_change() returns trigger
language plpgsql as $$
begin
    if new.status is distinct from old.status then
        insert into lead_status_log (external_id, from_status, to_status, changed_by, reason)
        values (new.external_id, old.status, new.status, new.assigned_bdm, new.rejected_reason);
    end if;
    return new;
end;
$$;

drop trigger if exists lead_status_change_log on lead;
create trigger lead_status_change_log
    after update on lead
    for each row execute function log_lead_status_change();
