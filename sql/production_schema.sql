-- ============================================================================
-- Turf Lead Pipeline — PRODUCTION schema  (Supabase / Postgres)
-- ============================================================================
-- Role: SYSTEM OF RECORD for everything a BDM touches after triage.
--
-- The scrapers NEVER write here. The ONLY writer from the pipeline side is the
-- promotion job (a GitHub Actions cron with this project's service key), which
-- moves accepted+resolved leads out of staging. Everything else is BDM edits
-- made through Retool against this database.
--
-- Ownership rules that make the two-database split safe:
--   * lifecycle_status lives ONLY here. Staging has no such column, so the two
--     databases can never disagree about where a lead sits in the funnel.
--   * The promotion job may INSERT new leads and APPEND observations, but on
--     conflict it must only refresh INGESTION fields (project_summary, last_seen,
--     source_url). It must NEVER overwrite lifecycle_status, assigned_bdm, or
--     rejected_reason — those are human-owned. (Enforce this in the job's
--     `on conflict do update set ...` list; see the note on `lead` below.)
--
-- Model:
--   * lead              one row per resolved opportunity  (upsert target = dedup_key)
--   * lead_observation  one row per promoted scrape mention (the append target for
--                       updates/results — this is why a new observation on an
--                       existing lead does not overwrite the lead row)
--   * lead_status_log   audit trail of lifecycle transitions (trigger-populated)
--
-- `create table if not exists` makes this file safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. lead  — resolved opportunity + sales lifecycle. System of record.
-- ----------------------------------------------------------------------------
-- dedup_key is the promotion upsert target and MUST match staging.lead.dedup_key
-- exactly, or the same opportunity will be inserted twice.
--
-- Promotion-job contract for `on conflict (dedup_key) do update`:
--   ALLOWED to set : project_summary, lead_value_estimation, source_url,
--                    last_seen, synced_at
--   FORBIDDEN to set: lifecycle_status, rejected_reason, assigned_bdm, created_at
create table if not exists lead (
    lead_id          text primary key check (char_length(lead_id) >= 8),
    dedup_key        text not null unique,          -- linkage key, = staging.lead.dedup_key

    -- Denormalized opportunity facts (pipeline-owned; safe to refresh on re-promote).
    organization     text not null,
    organization_id  text,
    state            text not null check (state ~ '^[A-Z]{2}$'),
    county           text not null default '',
    project_summary  text not null check (char_length(project_summary) <= 400),
    -- estimated project value: amount/range from the source, or 'uncertain'/'unknown'
    lead_value_estimation text,
    source_url       text not null,
    location_id      text,
    first_seen       timestamptz not null,
    last_seen        timestamptz not null default now(),

    -- ---- Lifecycle state (HUMAN-OWNED; the promotion job never writes these) ----
    lifecycle_status text not null default 'New'
                     check (lifecycle_status in
                        ('New','Reviewing','Qualified','Contacted','Opportunity','Rejected')),
    rejected_reason  text,
    assigned_bdm     text,

    created_at       timestamptz not null default now(),
    synced_at        timestamptz not null default now(),

    -- A rejected lead must carry a reason.
    constraint lead_rejected_needs_reason
        check (lifecycle_status <> 'Rejected' or coalesce(rejected_reason,'') <> '')
);
create index if not exists lead_status_idx  on lead (lifecycle_status);
create index if not exists lead_org_idx      on lead (organization_id);
create index if not exists lead_dedup_idx    on lead (dedup_key);


-- ----------------------------------------------------------------------------
-- 2. lead_observation  — one row per promoted scrape mention of a lead.
-- ----------------------------------------------------------------------------
-- This is the APPEND target that lets "update" and "result" observations attach
-- to an existing lead without overwriting it. `source_entry_id` back-references
-- the staging.lead_entry it came from — the audit trail to the original scrape.
--
-- Upsert target = source_entry_id, so re-running promotion for an
-- already-promoted entry is idempotent (does nothing new).
create table if not exists lead_observation (
    observation_id   bigint generated always as identity primary key,
    lead_id          text not null references lead(lead_id) on delete cascade,
    source_entry_id  text not null unique,           -- = staging.lead_entry.entry_id
    source           text not null check (source in ('web-search','meeting-minutes')),
    observation_type text not null check (observation_type in ('new','update','result')),
    summary          text not null default '',
    evidence_quote   text not null default '',
    source_url       text not null,
    discovered_at    timestamptz not null,
    bid_due_date     date,
    lead_value_estimation text,   -- as reported by this mention
    evidence         jsonb,
    promoted_at      timestamptz not null default now()
);
create index if not exists observation_lead_idx on lead_observation (lead_id);
create index if not exists observation_type_idx on lead_observation (observation_type);


-- ----------------------------------------------------------------------------
-- 3. lead_status_log  — lifecycle audit trail (trigger-populated).
-- ----------------------------------------------------------------------------
-- Makes time-in-stage measurable per pipeline (join back via lead / observation
-- to lead.source). The app (Retool) may also insert richer rows with changed_by.
create table if not exists lead_status_log (
    id           bigint generated always as identity primary key,
    lead_id      text not null references lead(lead_id) on delete cascade,
    from_status  text,
    to_status    text not null,
    changed_by   text,
    reason       text,
    changed_at   timestamptz not null default now()
);
create index if not exists lead_status_log_lead_idx on lead_status_log (lead_id);


-- ----------------------------------------------------------------------------
-- Automatic lifecycle logging. Fires only on lifecycle_status change, so the
-- promotion job's ingestion-field refreshes never generate spurious log rows.
-- ----------------------------------------------------------------------------
create or replace function log_lead_status_change() returns trigger
language plpgsql as $$
begin
    if new.lifecycle_status is distinct from old.lifecycle_status then
        insert into lead_status_log (lead_id, from_status, to_status, changed_by, reason)
        values (new.lead_id, old.lifecycle_status, new.lifecycle_status,
                new.assigned_bdm, new.rejected_reason);
    end if;
    return new;
end;
$$;

drop trigger if exists lead_status_change_log on lead;
create trigger lead_status_change_log
    after update on lead
    for each row execute function log_lead_status_change();
