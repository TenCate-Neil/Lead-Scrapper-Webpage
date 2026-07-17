#!/usr/bin/env python3
"""Push the pipeline's durable stores into Supabase (Postgres via PostgREST).

This is the bridge between the file-based pipeline and the shared Supabase tables
the Retool BDM UI sits on. It reads the local durable stores + run manifests,
transforms each record into a table row, and upserts it. Stages stay decoupled:
nothing here calls a pipeline stage; it only reads what the stages already wrote.

    locations/registry.yaml        -> search_area
    organizations/registry.json    -> organization (+ organization_geography)
    sources/registry.json          -> source
    leads/ledger.json              -> lead
    output/**/run_manifest.json    -> run
    locations/state.json           -> location_state

Idempotent: every table upserts on its stable key, so re-running only refreshes.
The lead lifecycle columns (status, rejected_reason, assigned_bdm) are Supabase-only
and are NEVER sent, so a BDM's edits in Retool survive every re-sync.

Setup: create the tables with sql/schema.sql, then set two environment variables
(or put them in sync/.env — see sync/.env.example):

    SUPABASE_URL=https://<project>.supabase.co
    SUPABASE_SERVICE_ROLE_KEY=<service-role key>   # bypasses RLS; keep secret

Usage:
    python3 sync/push_to_supabase.py --dry-run            # transform + print, no network
    python3 sync/push_to_supabase.py                      # push everything
    python3 sync/push_to_supabase.py --tables lead,source # push a subset

See docs/RUNBOOK.md ("Push to Supabase") for the operator walkthrough.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Repo root = the directory that contains this sync/ folder.
ROOT = Path(__file__).resolve().parent.parent

# Tables in dependency order (parents before children) so foreign keys resolve.
TABLE_ORDER = [
    "search_area",
    "organization",
    "organization_geography",
    "source",
    "lead",
    "run",
    "location_state",
]

# Conflict target per table: the column(s) PostgREST upserts on. Must match a
# primary key or unique constraint in sql/schema.sql.
CONFLICT_KEYS = {
    "search_area": "location_id",
    "organization": "organization_id",
    "organization_geography": "organization_id,kind,value",
    "source": "id",
    "lead": "external_id",
    "run": "location_id,run_timestamp",
    "location_state": "location_id",
}

BATCH_SIZE = 500  # PostgREST accepts row arrays; batch so a request never gets huge.


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #

def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def load_env_file(path: Path) -> None:
    """Load KEY=VALUE lines from sync/.env into os.environ if not already set.

    Deliberately tiny (no python-dotenv dependency). Ignores blanks and # comments.
    """
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


# --------------------------------------------------------------------------- #
# Transforms: durable store record -> table row (only pipeline-owned columns)
# --------------------------------------------------------------------------- #

def rows_search_area() -> list[dict]:
    import yaml  # local import so --dry-run of other tables works without pyyaml

    doc = yaml.safe_load((ROOT / "locations" / "registry.yaml").read_text(encoding="utf-8"))
    rows = []
    for loc in doc.get("locations", []):
        rows.append({
            "location_id": loc["location_id"],
            "name": loc.get("name"),
            "type": loc.get("type"),
            "priority": loc.get("priority"),
            "cadence": loc.get("cadence"),
            "coverage_target": loc.get("coverage_target"),
            "scope": loc.get("scope"),
            "tags": loc.get("tags"),
            "added_date": loc.get("added_date"),
            "schema_version": loc.get("schema_version"),
        })
    return rows


def rows_organization() -> list[dict]:
    doc = load_json(ROOT / "organizations" / "registry.json")
    rows = []
    for org in doc.get("organizations", []):
        rows.append({
            "organization_id": org["organization_id"],
            "name": org.get("name"),
            "type": org.get("type"),
            "website": org.get("website"),
            "state": org.get("state"),
            "primary_county": org.get("primary_county"),
            "location_ids": org.get("location_ids"),
            "first_seen": org.get("first_seen"),
            "notes": org.get("notes"),
        })
    return rows


def rows_organization_geography() -> list[dict]:
    doc = load_json(ROOT / "organizations" / "registry.json")
    rows = []
    for org in doc.get("organizations", []):
        for geo in org.get("geography", []):
            rows.append({
                "organization_id": org["organization_id"],
                "kind": geo["kind"],
                "value": geo["value"],
            })
    return rows


def rows_source() -> list[dict]:
    doc = load_json(ROOT / "sources" / "registry.json")
    fields = [
        "id", "location_id", "location_ids", "entity", "entity_type", "source_type",
        "name", "url", "normalized_url", "contains", "relevant_sports", "lead_stage",
        "searchability", "monitor_frequency", "sport_confirmed", "validation_status",
        "validation_tier", "confidence", "reviewed", "last_validated", "first_seen",
        "last_checked", "last_result",
    ]
    return [{f: src.get(f) for f in fields} for src in doc.get("sources", [])]


def rows_lead() -> list[dict]:
    """Core lead columns + the evidence JSONB. Lifecycle columns are omitted on
    purpose so an upsert never clobbers a BDM's status / assignment in Retool."""
    doc = load_json(ROOT / "leads" / "ledger.json")
    core = [
        "external_id", "source", "organization", "organization_id", "state",
        "county", "summary", "evidence_quote", "source_url", "discovered_at",
        "bid_due_date", "location_id",
    ]
    rows = []
    for lead in doc.get("leads", []):
        row = {f: lead.get(f) for f in core}
        row["evidence"] = lead.get("evidence")  # whole nested block -> jsonb
        rows.append(row)
    return rows


def rows_run() -> list[dict]:
    """One row per run_manifest.json under output/. Most run folders are gitignored,
    so on a fresh clone this typically finds only the tracked example run."""
    fields = [
        "location_id", "run_timestamp", "stage", "agent_versions", "counts",
        "coverage", "run_quality", "budget", "failed_sources", "gaps", "schema_version",
    ]
    rows = []
    for path in sorted(glob.glob(str(ROOT / "output" / "**" / "run_manifest.json"), recursive=True)):
        manifest = load_json(Path(path))
        rows.append({f: manifest.get(f) for f in fields})
    return rows


def rows_location_state() -> list[dict]:
    doc = load_json(ROOT / "locations" / "state.json")
    fields = [
        "location_id", "status", "last_run", "next_due", "coverage", "quality_score",
        "counts", "latest_run", "last_discovered", "last_scraped",
        "latest_discovery_run", "latest_scrape_run", "lease", "notes", "schema_version",
    ]
    return [{f: st.get(f) for f in fields} for st in doc.get("locations", [])]


BUILDERS = {
    "search_area": rows_search_area,
    "organization": rows_organization,
    "organization_geography": rows_organization_geography,
    "source": rows_source,
    "lead": rows_lead,
    "run": rows_run,
    "location_state": rows_location_state,
}


# --------------------------------------------------------------------------- #
# Upsert
# --------------------------------------------------------------------------- #

def upsert(table: str, rows: list[dict], base_url: str, key: str) -> None:
    """POST rows to PostgREST with merge-duplicates so it becomes an upsert."""
    conflict = CONFLICT_KEYS[table]
    url = f"{base_url}/rest/v1/{table}?on_conflict={conflict}"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    for start in range(0, len(rows), BATCH_SIZE):
        batch = rows[start:start + BATCH_SIZE]
        body = json.dumps(batch).encode("utf-8")
        _post_with_retry(url, body, headers, table)


def _post_with_retry(url: str, body: bytes, headers: dict, table: str, attempts: int = 4) -> None:
    delay = 2.0
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                resp.read()
            return
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            # 4xx is a data/schema problem — retrying will not help; fail loudly.
            if exc.code < 500:
                raise SystemExit(f"[{table}] upsert failed ({exc.code}): {detail}")
            last = f"{exc.code}: {detail}"
        except urllib.error.URLError as exc:
            last = str(exc.reason)
        if attempt < attempts:
            time.sleep(delay)
            delay *= 2
    raise SystemExit(f"[{table}] upsert failed after {attempts} attempts: {last}")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main() -> int:
    parser = argparse.ArgumentParser(description="Push durable stores into Supabase.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Transform and print row counts + a sample row; no network calls.")
    parser.add_argument("--tables", default="",
                        help="Comma-separated subset to sync (default: all, in dependency order).")
    args = parser.parse_args()

    load_env_file(ROOT / "sync" / ".env")

    selected = TABLE_ORDER
    if args.tables:
        requested = [t.strip() for t in args.tables.split(",") if t.strip()]
        unknown = [t for t in requested if t not in BUILDERS]
        if unknown:
            raise SystemExit(f"Unknown table(s): {', '.join(unknown)}. Known: {', '.join(TABLE_ORDER)}")
        selected = [t for t in TABLE_ORDER if t in requested]  # keep dependency order

    base_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not args.dry_run and (not base_url or not key):
        raise SystemExit(
            "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (env or sync/.env), "
            "or pass --dry-run. See sync/.env.example."
        )

    for table in selected:
        rows = BUILDERS[table]()
        if args.dry_run:
            print(f"{table}: {len(rows)} row(s)")
            if rows:
                sample = json.dumps(rows[0], default=str)
                print(f"    e.g. {sample[:300]}{'...' if len(sample) > 300 else ''}")
            continue
        if not rows:
            print(f"{table}: 0 rows, skipping")
            continue
        upsert(table, rows, base_url, key)
        print(f"{table}: upserted {len(rows)} row(s)")

    print("dry run complete — nothing was sent." if args.dry_run else "sync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
